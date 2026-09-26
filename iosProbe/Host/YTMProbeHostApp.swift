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

    private struct PreparedAudio {
        let data: Data?
        let directURL: URL?
        let headers: [String: String]
        let streamState: StreamingAudioState?
        let mimeType: String
        let client: String
        let profile: String
        let bytes: Int64
    }

    private var player: AVPlayer?
    private var rangeServer: LoopbackRangeServer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var currentTask: Task<Void, Never>?
    private var streamingHandle: StreamingAudioHandle?
    private var playbackGeneration = 0
    private let kit = YTMKit()
    private var configuredAudio = false

    init() {
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
    }

    func start(videoId: String? = nil) {
        if let videoId, let index = items.firstIndex(where: { $0.id == videoId }) {
            play(index: index)
            return
        }
        currentTask?.cancel()
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
        stopCurrentPlayer()
        playbackGeneration &+= 1
        let generation = playbackGeneration
        currentIndex = index
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
        let prepared = await fetchAudio(for: item, updateUI: true)
        guard generation == playbackGeneration, !Task.isCancelled else { return }
        guard let prepared else {
            // Do not hide the first real failure by cascading through the
            // entire queue. A failed SABR request needs to remain visible so
            // we can fix the transport/client choice from its diagnostics.
            stopAfterFailure(index: index)
            return
        }
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
                let server = LoopbackRangeServer(streamState: streamState, mimeType: prepared.mimeType)
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
                transport = "SABR streaming / \(prepared.mimeType)"
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
            player = newPlayer
            installPlayerObservers(item: item, track: self.items[index])
            let deadline = Date().addingTimeInterval(45)
            while item.status == .unknown && Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
                guard generation == playbackGeneration, !Task.isCancelled else { return }
            }
            guard generation == playbackGeneration, !Task.isCancelled else { return }
            playerStatus = "\(item.status.rawValue)"
            guard item.status == .readyToPlay else {
                state = item.error.map { "AVPlayer error domain=\(($0 as NSError).domain) code=\(($0 as NSError).code)" } ?? "AVPlayer 未 readyToPlay"
                verdict = "PROBE_PLAY=FAIL reason=player_not_ready"
                stopAfterFailure(index: index)
                return
            }
            newPlayer.play()
            isPlaying = true
            state = "播放中：\(self.items[index].title)"
            client = prepared.client
            profile = prepared.profile
            bytes = "\(prepared.bytes)"
            verdict = "PROBE_PLAY=PASS"
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
        do {
            let result = try await YTMProbe().run(
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
                streamSink: nil,
            )
            if let failureStage = result.failureStage {
                if updateUI {
                    state = "取流失败：\(item.title)"
                    failureDetail = "\(failureStage)\n\(result.failureMessage ?? "无错误消息")"
                    verdict = "PROBE_PLAY=FAIL reason=\(failureStage)"
                }
                return nil
            }
            if result.streamOk, !result.isSabr,
               let urlString = result.audioUrl,
               let directURL = URL(string: urlString),
               directURL.scheme == "https" {
                return PreparedAudio(
                    data: nil,
                    directURL: directURL,
                    headers: result.audioHeaders,
                    streamState: nil,
                    mimeType: result.audioMimeType ?? "audio/mp4",
                    client: result.audioClient ?? "unknown",
                    profile: result.audioProfile ?? "unknown",
                    bytes: result.audioExpectedBytes?.int64Value ?? 0,
                )
            }

            let streamState = StreamingAudioState()
            let sink = StreamingAudioSink(state: streamState)
            let handle = try await YTMProbe().startStreaming(
                videoId: item.id,
                cookie: nil,
                tokenGroup: "baseline",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                streamSink: sink,
            )
            if handle == nil {
                // Keep the previously verified playback path as a hard
                // fallback. A streaming session must never make all playback
                // unavailable when extractor setup changes upstream.
                return await fetchCompleteSabrFallback(for: item, updateUI: updateUI)
            }
            guard let handle else { return nil }
            streamingHandle = handle
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                let snapshot = streamState.snapshot()
                if snapshot.available >= 256 * 1024 || snapshot.completed { break }
                if Task.isCancelled { handle.close(); return nil }
                try await Task.sleep(for: .milliseconds(50))
            }
            let snapshot = streamState.snapshot()
            guard snapshot.available > 0, !snapshot.path.isEmpty else {
                handle.close()
                if updateUI {
                    state = "SABR 首段不可用：\(item.title)"
                    failureDetail = snapshot.failure ?? "no_initial_media_bytes"
                    verdict = "PROBE_PLAY=FAIL reason=sabr_initial_segment"
                }
                return nil
            }
            return PreparedAudio(
                data: nil,
                directURL: nil,
                headers: [:],
                streamState: streamState,
                mimeType: snapshot.mimeType,
                client: handle.client,
                profile: handle.profile,
                bytes: handle.expectedBytes,
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

    private func fetchCompleteSabrFallback(for item: ItemDTO, updateUI: Bool) async -> PreparedAudio? {
        do {
            let fallback = try await YTMProbe().run(
                playlistId: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                videoId: item.id,
                cookie: nil,
                tokenGroup: "baseline",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                candidateVideoIds: [item.id],
                sampleCount: 1,
                collectFullAudio: true,
                forceSabr: true,
                fastPlayback: false,
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
            return PreparedAudio(
                data: data,
                directURL: nil,
                headers: [:],
                streamState: nil,
                mimeType: fallback.audioMimeType ?? "audio/mp4",
                client: fallback.audioClient ?? "unknown",
                profile: fallback.audioProfile ?? "unknown",
                bytes: Int64(data.count),
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
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main,
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                self?.currentTime = String(format: "%.1f s", seconds)
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
