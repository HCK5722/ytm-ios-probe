import SwiftUI
import AVFoundation
import MediaPlayer
import YTMProbe
import YTMKit

@main
struct YTMProbeHostApp: App {
    var body: some Scene {
        WindowGroup { ProbeScreen() }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var state = "等待操作"
    @Published var egress = "检查中"
    @Published var client = "-"
    @Published var profile = "-"
    @Published var transport = "-"
    @Published var bytes = "-"
    @Published var playerStatus = "-"
    @Published var currentTime = "0"
    @Published var verdict = "PROBE_PLAY=IDLE"
    @Published var failureDetail = ""
    @Published var items: [ItemDTO] = []
    @Published var playlistTitle = ""
    @Published var loadingPlaylist = false
    @Published var currentIndex = -1
    @Published var isPlaying = false
    @Published var shuffleEnabled = false
    @Published var repeatEnabled = false
    @Published var coverageRunning = false
    @Published var coverageText = ""
    @Published var preparing = false
    @Published var lastResolveMs = "-"
    @Published var tapToReadyMs = "-"
    @Published var tapToAudioMs = "-"
    @Published var sabrDiagnostics = "-"
    @Published var poTokenDiagnostics = "-"
    @Published var strategyDiagnostics = "-"

    private struct PreparedAudio {
        let data: Data?
        let directURL: URL?
        let headers: [String: String]
        let streamState: StreamingAudioState?
        let streamingHandle: StreamingAudioHandle?
        let mimeType: String
        let client: String
        let profile: String
        let bytes: Int64
        let expiresAt: Date?
    }

    private var player: AVPlayer?
    private var rangeServer: LoopbackRangeServer?
    private var sabrResourceLoader: SabrResourceLoader?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var currentTask: Task<Void, Never>?
    private var sabrDiagnosticsTask: Task<Void, Never>?
    private var streamingHandle: StreamingAudioHandle?
    private var playbackGeneration = 0
    private let kit = YTMKit()
    private let playbackProbe = YTMProbe()
    private let poTokenService = PoTokenService()
    private var playbackPrewarmTask: Task<Void, Never>?
    private var configuredAudio = false
    private var preparedDirectCache: [String: PreparedAudio] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchingTrackId: String?
    private var backgroundPrefetchTask: Task<Void, Never>?
    private var playbackTapStartedAt: Date?
    private var didRecordAudioStart = false

    init() {
        poTokenService.start()
        Task { @MainActor in
            while !Task.isCancelled {
                self.poTokenDiagnostics = poTokenService.diagnosticSummary
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        configureRemoteCommands()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reasonRaw: reasonRaw) }
        }
        Task { await readEgress() }
        // Configure the session while the app is idle so the first tap does
        // not pay the audio-route setup cost.
        try? configureAudioSession()
        playbackPrewarmTask = Task {
            do {
                // Warm the complete shared extractor bundle while the app is
                // idle.  Visitor-data-only preparation does not populate the
                // player config/cipher caches used by SABR extraction.
                _ = try await playbackProbe.prewarmPlayback(
                    cookie: nil,
                    tokenGroup: "ios-external",
                    tokenServiceUrl: "http://127.0.0.1:4416/get_pot"
                )
                // Direct-player extraction needs visitor data as well as the
                // player config/cipher cache. Populate both while the queue is
                // idle so the first cold tap starts with a ready session.
                _ = try? await playbackProbe.prepareFastPlayback(
                    cookie: nil,
                    tokenGroup: "ios-external",
                    tokenServiceUrl: "http://127.0.0.1:4416/get_pot"
                )
            } catch {
                // The first track can still resolve lazily if startup prewarm fails.
            }
        }
    }

    func start(videoId: String? = nil) {
        if let videoId, let index = items.firstIndex(where: { $0.id == videoId }) {
            play(index: index)
            return
        }
        currentTask?.cancel()
        sabrDiagnosticsTask?.cancel()
        sabrDiagnosticsTask = nil
        currentTask = Task { [weak self] in
            guard let self else { return }
            if self.items.isEmpty, !(await self.loadPlaylist()) { return }
            self.play(index: self.currentIndex >= 0 ? self.currentIndex : 0)
        }
    }

    func loadPlaylist() async -> Bool {
        if loadingPlaylist { return !items.isEmpty }
        loadingPlaylist = true
        state = "加载歌单中..."
        failureDetail = ""
        defer { loadingPlaylist = false }
        do {
            let playlist = try await kit.playlist(id: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62")
            guard playlist.error.isEmpty else {
                state = "歌单加载失败"
                failureDetail = "YTMKit.playlist: \(playlist.error)"
                verdict = "PROBE_QUEUE=FAIL reason=playlist"
                return false
            }
            guard !playlist.items.isEmpty else {
                state = "歌单为空"
                failureDetail = "browse 成功但没有解析出 videoId + title 条目"
                verdict = "PROBE_QUEUE=FAIL reason=empty_playlist"
                return false
            }
            playlistTitle = playlist.title
            items = Array(playlist.items.prefix(100))
            currentIndex = -1
            _ = await playbackPrewarmTask?.value
            state = "歌单已加载：\(items.count) 首"
            verdict = "PROBE_QUEUE=PASS items=\(items.count)"
            return true
        } catch {
            state = "歌单加载失败"
            failureDetail = "YTMKit.playlist bridge: \((error as NSError).localizedDescription)"
            verdict = "PROBE_QUEUE=FAIL reason=playlist_bridge"
            return false
        }
    }

    private func play(index: Int) {
        guard items.indices.contains(index) else { return }
        guard !coverageRunning else {
            state = "覆盖率自检进行中，请等待完成后再播放"
            return
        }
        currentTask?.cancel()
        backgroundPrefetchTask?.cancel()
        backgroundPrefetchTask = nil
        if prefetchingTrackId != items[index].id {
            prefetchTask?.cancel()
        }
        stopCurrentPlayer()
        playbackGeneration &+= 1
        let generation = playbackGeneration
        currentIndex = index
        playbackTapStartedAt = Date()
        didRecordAudioStart = false
        tapToReadyMs = "-"
        tapToAudioMs = "-"
        sabrDiagnostics = "-"
        strategyDiagnostics = "-"
        failureDetail = ""
        state = "准备：\(items[index].title)"
        verdict = "PROBE_PLAY=RUNNING"
        preparing = true
        currentTask = Task { [weak self] in
            await self?.prepareAndPlay(index: index, generation: generation)
        }
    }

    private func prepareAndPlay(index: Int, generation: Int) async {
        defer { preparing = false }
        guard items.indices.contains(index) else { return }
        let item = items[index]
        let resolveStartedAt = Date()
        let prepared = await fetchAudio(for: item, updateUI: true)
        lastResolveMs = "\(Int(Date().timeIntervalSince(resolveStartedAt) * 1000)) ms"
        guard generation == playbackGeneration, !Task.isCancelled else {
            prepared?.streamingHandle?.close()
            return
        }
        guard let prepared else {
            // Do not hide the first real failure by cascading through the
            // entire queue. A failed SABR request needs to remain visible so
            // we can fix the transport/client choice from its diagnostics.
            stopAfterFailure(index: index)
            return
        }
        if let streamState = prepared.streamState {
            streamingHandle = prepared.streamingHandle
            sabrDiagnostics = sabrDiagnosticsText(snapshot: streamState.snapshot())
            startSabrDiagnosticsPolling(streamState)
        } else {
            streamingHandle = nil
        }
        failureDetail = ""
        do {
            do {
                try configureAudioSession()
            } catch {
                state = "音频会话初始化失败"
                failureDetail = "stage=audio_session\n\((error as NSError).domain) code=\((error as NSError).code)\n\((error as NSError).localizedDescription)"
                verdict = "PROBE_PLAY=FAIL reason=audio_session"
                stopAfterFailure(index: index)
                return
            }
            guard generation == playbackGeneration, !Task.isCancelled else { return }
            let item: AVPlayerItem
            if let directURL = prepared.directURL {
                let assetOptions: [String: Any]? = prepared.headers.isEmpty
                    ? nil
                    : ["AVURLAssetHTTPHeaderFieldsKey": prepared.headers]
                let asset = AVURLAsset(url: directURL, options: assetOptions)
                item = AVPlayerItem(asset: asset)
                transport = "DIRECT / \(prepared.mimeType)"
            } else if let streamState = prepared.streamState {
                let loader = SabrResourceLoader(state: streamState)
                sabrResourceLoader = loader
                let asset = AVURLAsset(url: loader.url)
                asset.resourceLoader.setDelegate(loader, queue: loader.queue)
                item = AVPlayerItem(asset: asset)
                transport = "SABR resource-loader / \(prepared.mimeType)"
            } else if let data = prepared.data {
                let server = LoopbackRangeServer(data: data, mimeType: prepared.mimeType)
                rangeServer = server
                do {
                    try server.start()
                } catch {
                    state = "本地音频服务启动失败"
                    failureDetail = "stage=loopback\n\((error as NSError).localizedDescription)"
                    verdict = "PROBE_PLAY=FAIL reason=loopback"
                    stopAfterFailure(index: index)
                    return
                }
                item = AVPlayerItem(url: server.url)
                transport = "SABR / \(prepared.mimeType)"
            } else {
                state = "播放数据为空"
                failureDetail = "stage=media_source"
                verdict = "PROBE_PLAY=FAIL reason=media_source"
                stopAfterFailure(index: index)
                return
            }
            let newPlayer = AVPlayer(playerItem: item)
            // Keep a small forward buffer so playback does not stop exactly
            // at the first SABR segment boundary. The first init/media bytes
            // are still supplied immediately; this only changes readahead.
            newPlayer.automaticallyWaitsToMinimizeStalling = true
            item.preferredForwardBufferDuration = 5
            player = newPlayer
            installPlayerObservers(item: item, track: self.items[index])
            newPlayer.play()
            isPlaying = true
            playerStatus = "\(item.status.rawValue)"
            state = "已发起播放：\(self.items[index].title)（等待音频缓冲）"
            client = prepared.client
            profile = prepared.profile
            bytes = "\(prepared.bytes)"
            verdict = "PROBE_PLAY=RUNNING resolveMs=\(lastResolveMs)"
        // Do not start speculative per-track extraction here.  iOS playback
        // currently uses SABR directly, so an eager queue scan only competes
        // with the track the user just tapped.
        } catch is CancellationError {
            // Cancelling the previous track during a deliberate track change
            // is normal and must never be shown as a playback failure.
            return
        } catch {
            state = "播放初始化失败"
            let nsError = error as NSError
            failureDetail = "stage=player\n\(nsError.domain) code=\(nsError.code)\n\(nsError.localizedDescription)"
            verdict = "PROBE_PLAY=FAIL reason=player_setup"
            stopAfterFailure(index: index)
        }
    }

    private func fetchAudio(for item: ItemDTO, updateUI: Bool) async -> PreparedAudio? {
        if let cached = preparedDirectCache[item.id], isUsable(cached) {
            return cached
        }
        preparedDirectCache.removeValue(forKey: item.id)
        if prefetchingTrackId == item.id {
            await prefetchTask?.value
            prefetchingTrackId = nil
            if let cached = preparedDirectCache[item.id], isUsable(cached) {
                return cached
            }
            preparedDirectCache.removeValue(forKey: item.id)
        }
        let prepared = await fetchAudio(for: item, updateUI: updateUI, allowFallback: true)
        if let prepared, prepared.directURL != nil {
            cachePreparedAudio(prepared, for: item.id)
        }
        return prepared
    }

    private func isUsable(_ prepared: PreparedAudio) -> Bool {
        guard let expiresAt = prepared.expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow > 15
    }

    private func cachePreparedAudio(_ prepared: PreparedAudio, for mediaId: String) {
        guard prepared.directURL != nil else { return }
        preparedDirectCache[mediaId] = prepared
        if preparedDirectCache.count > 100 {
            preparedDirectCache.removeValue(forKey: preparedDirectCache.keys.first ?? mediaId)
        }
    }

    private func fetchAudio(for item: ItemDTO, updateUI: Bool, allowFallback: Bool, isPrefetch: Bool = false) async -> PreparedAudio? {
        do {
            if !isPrefetch, prefetchingTrackId == item.id {
                await prefetchTask?.value
                prefetchingTrackId = nil
                if let cached = preparedDirectCache[item.id], isUsable(cached) {
                    return cached
                }
                preparedDirectCache.removeValue(forKey: item.id)
            }
            if !allowFallback { return nil }

            // Run the fast, token-backed IOS_SABR route first. Every fallback
            // appends its own result to the on-screen strategy matrix.
            strategyDiagnostics = "TOKEN_ROLES:playerRequest=visitorData streamingData(video/GVS)=videoId\nIOS_SABR_PO:starting"
            let streamState = StreamingAudioState()
            let sink = StreamingAudioSink(state: streamState)
            sink.onStateChanged = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sabrDiagnostics = self.sabrDiagnosticsText(snapshot: state.snapshot())
                }
            }
            let handle = try await playbackProbe.startStreaming(
                videoId: item.id,
                cookie: nil,
                tokenGroup: "ios-external",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                // Use the formal probe streaming strategy. It selects the
                // observed IOS_SABR response without issuing a raw player
                // request or entering the rejected VISIONOS path.
                playbackClientOverrideId: nil,
                streamSink: sink,
            )
            if handle == nil {
                let primaryFailure = playbackProbe.lastStreamingFailure
                if updateUI {
                    strategyDiagnostics = "IOS_SABR_PO:FAIL \(primaryFailure.isEmpty ? "no_handle" : primaryFailure)"
                }
                if updateUI {
                    let streamFailure = playbackProbe.lastStreamingFailure
                        .replacingOccurrences(of: "\\n", with: "_")
                        .replacingOccurrences(of: "\\r", with: "_")
                        .prefix(240)
                    sabrDiagnostics = "streamFailure=\(streamFailure.isEmpty ? "unknown" : String(streamFailure)) fallback=starting"
                }
                let visionosStreamingFallback = await fetchVisionosStreamingFallback(for: item, updateUI: updateUI)
                if let visionosStreamingFallback {
                    return visionosStreamingFallback
                }
                let noTokenResult = await diagnoseNoTokenSabr(for: item)
                if updateUI { strategyDiagnostics += "\n\(noTokenResult)" }
                let directFallback = await fetchDirectFallback(for: item, updateUI: updateUI)
                if let directFallback {
                    if updateUI { strategyDiagnostics += "\nDIRECT:PASS" }
                    return directFallback
                }
                if updateUI { strategyDiagnostics += "\nDIRECT:FAIL" }
                let completedFallback = await fetchCompleteSabrFallback(for: item, updateUI: updateUI)
                if updateUI {
                    let streamFailure = playbackProbe.lastStreamingFailure
                        .replacingOccurrences(of: "\\n", with: "_")
                        .replacingOccurrences(of: "\\r", with: "_")
                        .prefix(240)
                    let fallbackState = completedFallback == nil ? "failed" : "complete_sabr"
                    sabrDiagnostics = "streamFailure=\(streamFailure.isEmpty ? "unknown" : String(streamFailure)) fallback=\(fallbackState)"
                    strategyDiagnostics += "\nVISIONOS_COMPLETE:\(completedFallback == nil ? "FAIL" : "PASS")"
                }
                if completedFallback == nil, updateUI {
                    state = "取流失败：\(item.title)"
                    failureDetail = "SABR streaming 初始化失败；direct fallback 也没有可用 URL"
                    verdict = "PROBE_PLAY=FAIL reason=direct_and_sabr_unavailable"
                }
                return completedFallback
            }
            guard let handle else { return nil }
            if updateUI {
                failureDetail = ""
                sabrDiagnostics = "playerResolveMs=\(playbackProbe.sabrFirstPlayerElapsedMs) firstResponseMs=pending httpStatus=pending segments=0 mediaBytes=0 initReceived=pending firstChunkMs=pending firstChunkIsInit=pending failureCategory=none"
                startSabrDiagnosticsPolling(streamState)
            }
            let deadline = Date().addingTimeInterval(12)
            var firstBytesAt: Date?
            while Date() < deadline {
                let snapshot = streamState.snapshot()
                // The first SABR response can contain a valid init atom while
                // the next response later rejects the stream. Do not hand that
                // partial file to AVPlayer as a false "ready" stream.
                if snapshot.failure != nil || snapshot.completed { break }
                if snapshot.available >= 8 * 1024 {
                    firstBytesAt = firstBytesAt ?? Date()
                    // A healthy stream normally receives its next response
                    // quickly. Keep the gate bounded so cold start remains
                    // well below the 2-second target.
                    if snapshot.responseCount >= 2 ||
                        Date().timeIntervalSince(firstBytesAt!) >= 0.35 {
                        break
                    }
                }
                if Task.isCancelled { handle.close(); return nil }
                try await Task.sleep(for: .milliseconds(50))
            }
            let snapshot = streamState.snapshot()
            if updateUI {
                let resolveMs = playbackProbe.sabrFirstPlayerElapsedMs
                let responseMs = snapshot.firstResponseMs.map { String($0) } ?? "pending"
                let responseStatus = snapshot.firstResponseStatus.map { String($0) } ?? "pending"
                let segments = snapshot.firstResponseSegments.map { String($0) } ?? "0"
                let mediaBytes = snapshot.firstResponseMediaBytes.map { String($0) } ?? "0"
                let firstChunkMs = snapshot.firstChunkMs.map { String($0) } ?? "pending"
                let firstChunkIsInit = snapshot.firstChunkInitialization.map { String($0) } ?? "pending"
                let failureCategory = snapshot.firstResponseFailureCategory.isEmpty ? "none" : snapshot.firstResponseFailureCategory
                let streamFailure = snapshot.failure ?? "none"
                sabrDiagnostics = "playerResolveMs=\(resolveMs) firstResponseMs=\(responseMs) httpStatus=\(responseStatus) segments=\(segments) mediaBytes=\(mediaBytes) initReceived=\(snapshot.firstResponseInitialization) firstChunkMs=\(firstChunkMs) firstChunkIsInit=\(firstChunkIsInit) failureCategory=\(failureCategory) streamFailure=\(streamFailure)"
            }
            if let streamFailure = snapshot.failure {
                let primaryFailure = playbackProbe.lastStreamingFailure
                if updateUI {
                    state = "SABR 认证失败：\(item.title)"
                    failureDetail = streamFailure
                    verdict = "PROBE_PLAY=FAIL reason=sabr_attestation"
                    strategyDiagnostics = "IOS_SABR_PO:FAIL \(primaryFailure.isEmpty ? streamFailure : primaryFailure)"
                }
                handle.close()
                let visionosStreamingFallback = await fetchVisionosStreamingFallback(for: item, updateUI: updateUI)
                if let visionosStreamingFallback {
                    return visionosStreamingFallback
                }
                let noTokenResult = await diagnoseNoTokenSabr(for: item)
                if updateUI { strategyDiagnostics += "\n\(noTokenResult)" }
                let directFallback = await fetchDirectFallback(for: item, updateUI: updateUI)
                if let directFallback {
                    if updateUI { strategyDiagnostics += "\nDIRECT:PASS" }
                    return directFallback
                }
                if updateUI { strategyDiagnostics += "\nDIRECT:FAIL" }
                let completedFallback = await fetchCompleteSabrFallback(for: item, updateUI: updateUI)
                if updateUI { strategyDiagnostics += "\nVISIONOS_COMPLETE:\(completedFallback == nil ? "FAIL" : "PASS")" }
                return completedFallback
            }
            guard snapshot.available > 0, !snapshot.path.isEmpty else {
                handle.close()
                if updateUI {
                    state = "SABR 首段不可用：\(item.title)"
                    failureDetail = [snapshot.failure ?? "no_initial_media_bytes"]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                    verdict = "PROBE_PLAY=FAIL reason=sabr_initial_segment"
                }
                return await fetchCompleteSabrFallback(for: item, updateUI: updateUI)
            }
            return PreparedAudio(
                data: nil,
                directURL: nil,
                headers: [:],
                streamState: streamState,
                streamingHandle: handle,
                mimeType: snapshot.mimeType,
                client: handle.client,
                profile: handle.profile,
                bytes: handle.expectedBytes,
                expiresAt: nil,
            )
        } catch {
            if error is CancellationError || Task.isCancelled { return nil }
            if updateUI {
                state = "取流异常：\(item.title)"
                failureDetail = (error as NSError).localizedDescription
                verdict = "PROBE_PLAY=FAIL reason=stream_exception"
            }
            return nil
        }
    }

    private func diagnoseNoTokenSabr(for item: ItemDTO) async -> String {
        let state = StreamingAudioState()
        let sink = StreamingAudioSink(state: state)
        do {
            let handle = try await playbackProbe.startStreaming(
                videoId: item.id,
                cookie: nil,
                tokenGroup: "baseline",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                playbackClientOverrideId: nil,
                streamSink: sink,
            )
            guard let handle else {
                let failure = playbackProbe.lastStreamingFailure
                return "IOS_SABR_NOPO:FAIL \(failure.isEmpty ? "no_handle" : failure)"
            }
            try? await Task.sleep(for: .milliseconds(650))
            let snapshot = state.snapshot()
            handle.close()
            if let failure = snapshot.failure {
                return "IOS_SABR_NOPO:FAIL \(failure)"
            }
            return "IOS_SABR_NOPO:PREFIX bytes=\(snapshot.available) client=\(handle.client) profile=\(handle.profile)"
        } catch {
            return "IOS_SABR_NOPO:EXCEPTION \((error as NSError).domain):\((error as NSError).code)"
        }
    }

    private func fetchVisionosStreamingFallback(for item: ItemDTO, updateUI: Bool) async -> PreparedAudio? {
        // Keep all raw identities in one build. The first candidate with a real
        // audio prefix wins; failed candidates remain visible for server-side
        // attestation/playability diagnosis instead of being silently discarded.
        let candidates = [
            "VISIONOS_0_1_SABR_RAW",
            "VISIONOS_SABR_RAW",
            "IOS_SABR_RAW",
            "IPADOS_SABR_RAW",
        ]
        for candidate in candidates {
            let state = StreamingAudioState()
            let sink = StreamingAudioSink(state: state)
            sink.onStateChanged = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sabrDiagnostics = self.sabrDiagnosticsText(snapshot: state.snapshot())
                }
            }
            do {
                let handle = try await playbackProbe.startStreaming(
                    videoId: item.id,
                    cookie: nil,
                    tokenGroup: "baseline",
                    tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                    playbackClientOverrideId: candidate,
                    streamSink: sink,
                )
                guard let handle else {
                    if updateUI {
                        let failure = playbackProbe.lastStreamingFailure
                            .replacingOccurrences(of: "\\n", with: "_")
                            .replacingOccurrences(of: "\\r", with: "_")
                            .prefix(240)
                        strategyDiagnostics += "\nRAW_MATRIX:\(candidate)=FAIL \(failure.isEmpty ? "no_handle" : String(failure))"
                    }
                    continue
                }

                let deadline = Date().addingTimeInterval(2.2)
                while Date() < deadline {
                    let snapshot = state.snapshot()
                    if snapshot.failure != nil || snapshot.completed { break }
                    if snapshot.available >= 8 * 1024 { break }
                    if Task.isCancelled { handle.close(); return nil }
                    try await Task.sleep(for: .milliseconds(40))
                }
                let snapshot = state.snapshot()
                guard snapshot.failure == nil, snapshot.available >= 8 * 1024 else {
                    let failure = (snapshot.failure ?? playbackProbe.lastStreamingFailure)
                        .replacingOccurrences(of: "\\n", with: "_")
                        .replacingOccurrences(of: "\\r", with: "_")
                        .prefix(240)
                    handle.close()
                    if updateUI {
                        strategyDiagnostics += "\nRAW_MATRIX:\(candidate)=FAIL \(failure.isEmpty ? "bytes_\(snapshot.available)" : String(failure))"
                    }
                    continue
                }
                if updateUI {
                    strategyDiagnostics += "\nRAW_MATRIX:\(candidate)=PASS bytes=\(snapshot.available)"
                    sabrDiagnostics = sabrDiagnosticsText(snapshot: snapshot)
                }
                return PreparedAudio(
                    data: nil,
                    directURL: nil,
                    headers: [:],
                    streamState: state,
                    streamingHandle: handle,
                    mimeType: snapshot.mimeType,
                    client: handle.client,
                    profile: handle.profile,
                    bytes: handle.expectedBytes,
                    expiresAt: nil,
                )
            } catch is CancellationError {
                return nil
            } catch {
                if updateUI {
                    let failure = playbackProbe.lastStreamingFailure
                        .replacingOccurrences(of: "\\n", with: "_")
                        .replacingOccurrences(of: "\\r", with: "_")
                        .prefix(240)
                    strategyDiagnostics += "\nRAW_MATRIX:\(candidate)=EXCEPTION \((error as NSError).domain):\((error as NSError).code) failure=\(failure)"
                }
            }
        }
        return nil
    }

    private func fetchDirectFallback(for item: ItemDTO, updateUI: Bool) async -> PreparedAudio? {
        do {
            let directStartedAt = Date()
            let direct = try await playbackProbe.run(
                playlistId: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                videoId: item.id,
                cookie: nil,
                tokenGroup: "baseline",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                candidateVideoIds: [item.id],
                sampleCount: 1,
                collectFullAudio: false,
                forceSabr: false,
                fastPlayback: true,
                directPlayerFastPath: true,
                verifyAudioPrefix: false,
                playbackClientOverrideId: nil,
                streamSink: nil,
            )
            let directElapsedMs = Int(Date().timeIntervalSince(directStartedAt) * 1000)
            if let prepared = directPreparedAudio(from: direct) {
                if updateUI {
                    state = "普通直链已解析：\(item.title)"
                    client = prepared.client
                    profile = prepared.profile
                    transport = "DIRECT / \(prepared.mimeType)"
                    bytes = "\(prepared.bytes)"
                }
                return prepared
            }
            if updateUI {
                let diagnostic = direct.streamDiagnostics
                    .replacingOccurrences(of: "cookie", with: "credential", options: .caseInsensitive)
                    .prefix(6000)
                failureDetail = "directFallbackMs=\(directElapsedMs)\nclient=\(direct.audioClient ?? "none") profile=\(direct.audioProfile ?? "none")\nreason=\(direct.failureStage ?? "no_direct_url") type=\(direct.failureType ?? "DirectAudioUnavailable")\n\(diagnostic)"
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            if updateUI {
                failureDetail = "directFallbackError=\((error as NSError).localizedDescription)"
            }
            return nil
        }
    }

    private func startSabrDiagnosticsPolling(_ streamState: StreamingAudioState) {
        sabrDiagnosticsTask?.cancel()
        sabrDiagnosticsTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(20)
            while !Task.isCancelled, Date() < deadline {
                let snapshot = streamState.snapshot()
                self.sabrDiagnostics = self.sabrDiagnosticsText(snapshot: snapshot)
                // Keep polling after the first chunk. The first chunk only
                // proves that the init atom reached AVPlayer; it says
                // nothing about later SABR responses or a stalled writer.
                if snapshot.failure != nil || snapshot.completed { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let snapshot = streamState.snapshot()
            self.sabrDiagnostics = self.sabrDiagnosticsText(snapshot: snapshot)
        }
    }

    private func sabrDiagnosticsText(snapshot: (path: String, mimeType: String, expected: Int64, available: Int64, completed: Bool, failure: String?, resolveMs: Int64?, firstChunkMs: Int64?, firstChunkInitialization: Bool?, firstResponseMs: Int64?, firstResponseStatus: Int32?, firstResponseSegments: Int32?, firstResponseMediaBytes: Int64?, firstResponseInitialization: Bool, firstResponseFailureCategory: String, responseCount: Int, cumulativeSegments: Int, cumulativeMediaBytes: Int64, lastResponseMs: Int64?, lastResponseStatus: Int32?, lastResponseSegments: Int32?, lastResponseMediaBytes: Int64?, lastResponseFailureCategory: String, lastAvailableMs: Int64?)) -> String {
        let resolveMs = snapshot.resolveMs.map(String.init) ?? "pending"
        let responseMs = snapshot.firstResponseMs.map(String.init) ?? "pending"
        let responseStatus = snapshot.firstResponseStatus.map(String.init) ?? "pending"
        let segments = snapshot.firstResponseSegments.map(String.init) ?? "0"
        let mediaBytes = snapshot.firstResponseMediaBytes.map(String.init) ?? "0"
        let firstChunkMs = snapshot.firstChunkMs.map(String.init) ?? "pending"
        let firstChunkIsInit = snapshot.firstChunkInitialization.map(String.init) ?? "pending"
        let failureCategory = snapshot.firstResponseFailureCategory.isEmpty ? "none" : snapshot.firstResponseFailureCategory
        let lastResponseMs = snapshot.lastResponseMs.map(String.init) ?? "pending"
        let lastResponseStatus = snapshot.lastResponseStatus.map(String.init) ?? "pending"
        let lastResponseSegments = snapshot.lastResponseSegments.map(String.init) ?? "0"
        let lastResponseBytes = snapshot.lastResponseMediaBytes.map(String.init) ?? "0"
        let lastFailure = snapshot.lastResponseFailureCategory.isEmpty ? "none" : snapshot.lastResponseFailureCategory
        return "playerResolveMs=\(resolveMs) firstResponseMs=\(responseMs) httpStatus=\(responseStatus) segments=\(segments) mediaBytes=\(mediaBytes) responseCount=\(snapshot.responseCount) cumulativeSegments=\(snapshot.cumulativeSegments) cumulativeMediaBytes=\(snapshot.cumulativeMediaBytes) lastResponseMs=\(lastResponseMs) lastHttpStatus=\(lastResponseStatus) lastSegments=\(lastResponseSegments) lastMediaBytes=\(lastResponseBytes) lastFailure=\(lastFailure) availableBytes=\(snapshot.available)/\(snapshot.expected) completed=\(snapshot.completed) initReceived=\(snapshot.firstResponseInitialization) firstChunkMs=\(firstChunkMs) firstChunkIsInit=\(firstChunkIsInit) failureCategory=\(failureCategory)"
    }

    private func fetchCompleteSabrFallback(for item: ItemDTO, updateUI: Bool) async -> PreparedAudio? {
        do {
            let fallback = try await playbackProbe.run(
                playlistId: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                videoId: item.id,
                cookie: nil,
                tokenGroup: "baseline",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                candidateVideoIds: [item.id],
                sampleCount: 1,
                collectFullAudio: true,
                forceSabr: true,
                fastPlayback: true,
                directPlayerFastPath: false,
                verifyAudioPrefix: false,
                playbackClientOverrideId: "VISIONOS_SABR_RAW",
                streamSink: nil,
            )
            guard fallback.streamOk, fallback.isSabr, fallback.audioComplete,
                  let path = fallback.audioCachePath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
                if updateUI {
                    state = "取流失败：\(item.title)"
                    failureDetail = "streaming_init_failed\n\(fallback.streamFailure ?? "NO_PLAYABLE_STREAM")\n\(fallback.streamDiagnostics)"
                    verdict = "PROBE_PLAY=FAIL reason=stream"
                }
                return nil
            }
            try? FileManager.default.removeItem(atPath: path)
            if updateUI {
                failureDetail = ""
                verdict = "PROBE_PLAY=RUNNING fallback=complete_sabr"
                client = fallback.audioClient ?? "unknown"
                profile = fallback.audioProfile ?? "unknown"
                transport = "SABR complete / \(fallback.audioMimeType ?? "audio/mp4")"
                bytes = "\(data.count)"
            }
            return PreparedAudio(
                data: data,
                directURL: nil,
                headers: [:],
                streamState: nil,
                streamingHandle: nil,
                mimeType: fallback.audioMimeType ?? "audio/mp4",
                client: fallback.audioClient ?? "unknown",
                profile: fallback.audioProfile ?? "unknown",
                bytes: Int64(data.count),
                expiresAt: fallback.audioExpiresAtMs.map { Date(timeIntervalSince1970: $0.doubleValue / 1000.0) },
            )
        } catch {
            if updateUI {
                state = "取流异常：\(item.title)"
                failureDetail = "streaming_init_failed\n\((error as NSError).localizedDescription)"
                verdict = "PROBE_PLAY=FAIL reason=stream_exception"
            }
            return nil
        }
    }

    private func directPreparedAudio(from result: ProbeResult) -> PreparedAudio? {
        guard result.streamOk, !result.isSabr,
              let rawURL = result.audioUrl,
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"),
              let url = components.url,
              result.audioMimeType?.lowercased().hasPrefix("audio/") == true else {
            return nil
        }
        let expiresAt = result.audioExpiresAtMs.map {
            Date(timeIntervalSince1970: $0.doubleValue / 1000.0)
        }
        if let expiresAt, expiresAt.timeIntervalSinceNow <= 15 { return nil }
        return PreparedAudio(
            data: nil,
            directURL: url,
            headers: result.audioHeaders,
            streamState: nil,
            streamingHandle: nil,
            mimeType: result.audioMimeType ?? "audio/mp4",
            client: result.audioClient ?? "unknown",
            profile: result.audioProfile ?? "unknown",
            bytes: result.audioExpectedBytes?.int64Value ?? 0,
            expiresAt: expiresAt,
        )
    }

    private func schedulePrefetch(after _: Int, generation _: Int) {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchingTrackId = nil
        backgroundPrefetchTask?.cancel()
        backgroundPrefetchTask = nil
    }

    private func nextIndex(after index: Int) -> Int? {
        if shuffleEnabled {
            let candidates = items.indices.filter { $0 != index }
            return candidates.randomElement()
        }
        let next = index + 1
        return items.indices.contains(next) ? next : (repeatEnabled ? index : nil)
    }

    private func stopAfterFailure(index: Int) {
        stopCurrentPlayer()
        isPlaying = false
        state = "播放失败，已停在第 \(index + 1) 首"
    }

    func next() { if let next = nextIndex(after: currentIndex) { play(index: next) } }

    func previous() {
        if let player, player.currentTime().seconds > 3 { player.seek(to: .zero); return }
        let previous = currentIndex - 1
        if items.indices.contains(previous) { play(index: previous) }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
        refreshNowPlaying()
    }

    func runCoverage() {
        guard !coverageRunning, !isPlaying, !preparing else {
            coverageText = "请先停止当前播放，再运行覆盖率自检"
            return
        }
        coverageRunning = true
        coverageText = "覆盖率自检进行中..."
        Task { [weak self] in
            guard let self else { return }
            defer { self.coverageRunning = false }
            if self.items.isEmpty, !(await self.loadPlaylist()) {
                return
            }
            let sample = Array(self.items.prefix(30))
            var resolved = 0
            var prefixReadable = 0
            var profiles: [String: Int] = [:]
            var failures: [String: Int] = [:]
            var prefixFailures: [String: Int] = [:]
            var failureTracks: [String] = []
            for (offset, item) in sample.enumerated() {
                var result: ProbeResult?
                for attempt in 1...3 {
                    if Task.isCancelled { break }
                    result = try? await YTMProbe().run(
                        playlistId: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                        videoId: item.id,
                        cookie: nil,
                        tokenGroup: "baseline",
                        tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                        candidateVideoIds: [item.id],
                        sampleCount: 1,
                        collectFullAudio: false,
                        forceSabr: true,
                        fastPlayback: false,
                        directPlayerFastPath: false,
                        verifyAudioPrefix: false,
                        playbackClientOverrideId: nil,
                        streamSink: nil,
                    )
                    if result?.streamOk == true, result?.prefixReadable == true { break }
                    if attempt < 3 { try? await Task.sleep(for: .milliseconds(350)) }
                }
                if let result, result.streamOk {
                    resolved += 1
                    let profile = result.audioProfile ?? "unknown"
                    profiles[profile, default: 0] += 1
                    if result.prefixReadable {
                        prefixReadable += 1
                    } else {
                        let reason = result.prefixFailure ?? "prefix_unreadable"
                        prefixFailures[reason, default: 0] += 1
                    }
                } else {
                    let reason = result?.streamFailure ?? "request_or_exception"
                    failures[reason, default: 0] += 1
                    let detail = result?.failureMessage ?? result?.streamDiagnostics ?? "no_diagnostics"
                    failureTracks.append("\(offset + 1):\(item.title) [\(item.id)] \(reason) \(detail)")
                }
                self.coverageText = "覆盖率自检：\(offset + 1)/\(sample.count)"
            }
            let profileText = profiles.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            let failureText = failures.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            let prefixFailureText = prefixFailures.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            let trackText = failureTracks.isEmpty ? "无" : failureTracks.joined(separator: "\n")
            self.coverageText = "取流解析：\(resolved)/\(sample.count)\n前缀可读：\(prefixReadable)/\(sample.count)\nprofile：\(profileText.isEmpty ? "无" : profileText)\n解析失败：\(failureText.isEmpty ? "无" : failureText)\n前缀失败：\(prefixFailureText.isEmpty ? "无" : prefixFailureText)\n失败曲目：\n\(trackText)"
        }
    }

    private func configureAudioSession() throws {
        guard !configuredAudio else { return }
        let session = AVAudioSession.sharedInstance()
        // iOS 27 rejects the previous Bluetooth/AirPlay option combination
        // on some routes with OSStatus -50 (paramErr). Start with the
        // minimal playback category; route support can be added after the
        // core local playback path is stable.
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        configuredAudio = true
    }

    private func installPlayerObservers(item: AVPlayerItem, track: ItemDTO) {
        let trackTitle = track.title
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        statusObserver?.invalidate()
        statusObserver = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                guard let self else { return }
                self.playerStatus = "\(status.rawValue)"
                if status == .readyToPlay {
                    if let startedAt = self.playbackTapStartedAt {
                        self.tapToReadyMs = "\(Int(Date().timeIntervalSince(startedAt) * 1000)) ms"
                    }
                    self.state = "播放中：\(trackTitle)"
                } else if status == .failed {
                    self.state = item.error.map { "AVPlayer error domain=\(($0 as NSError).domain) code=\(($0 as NSError).code)" } ?? "AVPlayer 播放失败"
                    self.verdict = "PROBE_PLAY=FAIL reason=player_not_ready"
                }
            }
        }
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main,
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                self?.currentTime = String(format: "%.1f s", seconds)
                if let self, seconds > 0.05, !self.didRecordAudioStart {
                    self.didRecordAudioStart = true
                    if let startedAt = self.playbackTapStartedAt {
                        self.tapToAudioMs = "\(Int(Date().timeIntervalSince(startedAt) * 1000)) ms"
                    }
                    self.verdict = "PROBE_PLAY=PASS resolveMs=\(self.lastResolveMs) tapToAudioMs=\(self.tapToAudioMs)"
                }
                self?.refreshNowPlaying()
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in self?.finishCurrentTrack() }
        }
        updateNowPlaying(for: track, item: item)
    }

    private func finishCurrentTrack() {
        isPlaying = false
        if let next = nextIndex(after: currentIndex) { play(index: next) }
        else { state = "队列播放完成"; verdict = "PROBE_QUEUE=PASS finished=true"; refreshNowPlaying() }
    }

    private func stopCurrentPlayer() {
        sabrDiagnosticsTask?.cancel()
        sabrDiagnosticsTask = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        sabrResourceLoader?.invalidate()
        sabrResourceLoader = nil
        streamingHandle?.close()
        streamingHandle = nil
        player = nil
        isPlaying = false
        rangeServer = nil
    }

    private func updateNowPlaying(for track: ItemDTO? = nil, item: AVPlayerItem? = nil) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let track { info[MPMediaItemPropertyTitle] = track.title; info[MPMediaItemPropertyArtist] = track.subtitle }
        if let item, item.duration.isNumeric { info[MPMediaItemPropertyPlaybackDuration] = item.duration.seconds }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime().seconds ?? 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func refreshNowPlaying() { updateNowPlaying() }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.play(); self?.isPlaying = true; self?.refreshNowPlaying() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.player?.pause(); self?.isPlaying = false; self?.refreshNowPlaying() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.player?.seek(to: CMTime(seconds: event.positionTime, preferredTimescale: 600)); self?.refreshNowPlaying() }
            return .success
        }
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeValue = typeRaw,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began { player?.pause(); isPlaying = false }
        if type == .ended,
           let optionsValue = optionsRaw,
           AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
            player?.play(); isPlaying = true; refreshNowPlaying()
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonValue = reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        if reason == .oldDeviceUnavailable { player?.pause(); isPlaying = false; refreshNowPlaying() }
    }

    private func readEgress() async {
        do {
            async let ipRequest = URLSession.shared.data(from: URL(string: "https://api.ipify.org")!)
            async let infoRequest = URLSession.shared.data(from: URL(string: "https://ipinfo.io/json")!)
            let (ipData, _) = try await ipRequest
            let (infoData, _) = try await infoRequest
            let info = (try? JSONSerialization.jsonObject(with: infoData)) as? [String: String] ?? [:]
            egress = "\(String(decoding: ipData, as: UTF8.self)) | \(info["org"] ?? "unknown")"
        } catch { egress = "查询失败：\(type(of: error))" }
    }
}

struct ProbeScreen: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("YT Music 正式播放器探针").font(.title2.bold())
                if model.loadingPlaylist { ProgressView("加载歌单中...") }
                if !model.playlistTitle.isEmpty { Text("\(model.playlistTitle) · \(model.items.count) 首").font(.headline) }
                if !model.items.isEmpty {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        Button { model.start(videoId: item.id) } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)").font(.caption.monospaced()).frame(width: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                                    if !item.subtitle.isEmpty { Text(item.subtitle).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                                if model.currentIndex == index { Image(systemName: model.isPlaying ? "speaker.wave.2.fill" : "pause.fill") }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                HStack {
                    Button { model.previous() } label: { Image(systemName: "backward.fill") }.accessibilityLabel("上一首")
                    Button { model.togglePlayPause() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }.accessibilityLabel("播放或暂停")
                    Button { model.next() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("下一首")
                    Button { model.shuffleEnabled.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(model.shuffleEnabled ? .blue : .primary) }.accessibilityLabel("随机播放")
                    Button { model.repeatEnabled.toggle() } label: { Image(systemName: "repeat").foregroundStyle(model.repeatEnabled ? .blue : .primary) }.accessibilityLabel("循环播放")
                }
                HStack {
                    Button("加载歌单并播放第一首") { model.start() }.buttonStyle(.borderedProminent)
                    Button("覆盖率自检") { model.runCoverage() }.buttonStyle(.bordered).disabled(model.coverageRunning)
                }
                row("公网 IP / ISP", model.egress)
                row("client / profile", "\(model.client) / \(model.profile)")
                row("传输 / 实收字节", "\(model.transport) / \(model.bytes)")
                row("AVPlayer status", model.playerStatus)
                row("解析耗时", model.lastResolveMs)
                row("点击到 ready", model.tapToReadyMs)
                row("点击到出声", model.tapToAudioMs)
                row("本地 PoToken", model.poTokenDiagnostics)
                row("播放方案诊断", model.strategyDiagnostics)
                row("SABR 首响诊断", model.sabrDiagnostics)
                row("currentTime", model.currentTime)
                row("状态", model.state)
                if !model.failureDetail.isEmpty { Text(model.failureDetail).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if !model.coverageText.isEmpty { Text(model.coverageText).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                Text(model.verdict).font(.system(.headline, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
