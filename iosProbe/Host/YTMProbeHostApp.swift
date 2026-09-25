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

    private struct PreparedAudio {
        let index: Int
        let data: Data
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
    private var preloadTask: Task<Void, Never>?
    private var preloaded: PreparedAudio?
    private let kit = YTMKit()
    private var configuredAudio = false

    init() {
        configureRemoteCommands()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            Task { @MainActor in self?.handleInterruption(notification) }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        }
        Task { await readEgress() }
    }

    deinit {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
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
        currentTask?.cancel()
        currentIndex = index
        preloaded = preloaded?.index == index ? preloaded : nil
        failureDetail = ""
        state = "准备：\(items[index].title)"
        verdict = "PROBE_PLAY=RUNNING"
        currentTask = Task { [weak self] in
            await self?.prepareAndPlay(index: index)
        }
    }

    private func prepareAndPlay(index: Int) async {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        let prepared: PreparedAudio?
        if let preloaded, preloaded.index == index {
            prepared = preloaded
            self.preloaded = nil
        } else {
            prepared = await fetchAudio(for: item, index: index, updateUI: true)
        }
        guard let prepared else {
            await skipFailedTrack(from: index)
            return
        }
        do {
            try configureAudioSession()
            stopCurrentPlayer()
            let server = try LoopbackRangeServer(data: prepared.data, mimeType: prepared.mimeType)
            rangeServer = server
            try server.start()
            let item = AVPlayerItem(url: server.url)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            installPlayerObservers(item: item, track: self.items[index])
            let deadline = Date().addingTimeInterval(45)
            while item.status == .unknown && Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            playerStatus = "\(item.status.rawValue)"
            guard item.status == .readyToPlay else {
                state = item.error.map { "AVPlayer error domain=\(($0 as NSError).domain) code=\(($0 as NSError).code)" } ?? "AVPlayer 未 readyToPlay"
                verdict = "PROBE_PLAY=FAIL reason=player_not_ready"
                await skipFailedTrack(from: index)
                return
            }
            newPlayer.play()
            isPlaying = true
            state = "播放中：\(self.items[index].title)"
            client = prepared.client
            profile = prepared.profile
            transport = "SABR / \(prepared.mimeType)"
            bytes = "\(prepared.bytes)"
            verdict = "PROBE_PLAY=PASS"
            preloadNextIfNeeded(after: index)
        } catch {
            state = "播放初始化失败"
            failureDetail = (error as NSError).localizedDescription
            verdict = "PROBE_PLAY=FAIL reason=player_setup"
            await skipFailedTrack(from: index)
        }
    }

    private func fetchAudio(for item: ItemDTO, index: Int, updateUI: Bool) async -> PreparedAudio? {
        do {
            let result = try await YTMProbe().run(
                playlistId: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                videoId: item.id,
                cookie: nil,
                tokenGroup: "baseline",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                candidateVideoIds: [item.id],
                sampleCount: 1,
                collectFullAudio: true,
                forceSabr: true,
            )
            if let failureStage = result.failureStage {
                if updateUI {
                    state = "取流失败：\(item.title)"
                    failureDetail = "\(failureStage)\n\(result.failureMessage ?? "无错误消息")"
                    verdict = "PROBE_PLAY=FAIL reason=\(failureStage)"
                }
                return nil
            }
            guard result.streamOk, result.isSabr, result.audioComplete,
                  let path = result.audioCachePath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
                if updateUI {
                    state = "取流失败：\(item.title)"
                    failureDetail = "\(result.streamFailure ?? "NO_PLAYABLE_STREAM")\n\(result.streamDiagnostics)"
                    verdict = "PROBE_PLAY=FAIL reason=stream"
                }
                return nil
            }
            try? FileManager.default.removeItem(atPath: path)
            return PreparedAudio(
                index: index,
                data: data,
                mimeType: result.audioMimeType ?? "audio/mp4",
                client: result.audioClient ?? "unknown",
                profile: result.audioProfile ?? "unknown",
                bytes: Int64(data.count),
            )
        } catch {
            if updateUI {
                state = "取流异常：\(item.title)"
                failureDetail = (error as NSError).localizedDescription
                verdict = "PROBE_PLAY=FAIL reason=stream_exception"
            }
            return nil
        }
    }

    private func preloadNextIfNeeded(after index: Int) {
        guard let next = nextIndex(after: index), preloaded?.index != next else { return }
        preloadTask?.cancel()
        let item = items[next]
        preloadTask = Task { [weak self] in
            guard let self else { return }
            let payload = await self.fetchAudio(for: item, index: next, updateUI: false)
            guard !Task.isCancelled else { return }
            self.preloaded = payload
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

    private func skipFailedTrack(from index: Int) async {
        guard let next = nextIndex(after: index), next != index else { return }
        state = "跳过失败曲目，准备下一首"
        try? await Task.sleep(for: .milliseconds(250))
        play(index: next)
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
        guard !coverageRunning else { return }
        coverageRunning = true
        coverageText = "覆盖率自检进行中..."
        Task { [weak self] in
            guard let self else { return }
            if self.items.isEmpty, !(await self.loadPlaylist()) {
                self.coverageRunning = false
                return
            }
            let sample = Array(self.items.prefix(30))
            var passed = 0
            var profiles: [String: Int] = [:]
            var failures: [String: Int] = [:]
            for (offset, item) in sample.enumerated() {
                let result = try? await YTMProbe().run(
                    playlistId: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                    videoId: item.id,
                    cookie: nil,
                    tokenGroup: "baseline",
                    tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                    candidateVideoIds: [item.id],
                    sampleCount: 1,
                    collectFullAudio: false,
                    forceSabr: true,
                )
                if let result, result.streamOk {
                    passed += 1
                    let profile = result.audioProfile ?? "unknown"
                    profiles[profile, default: 0] += 1
                } else {
                    let reason = result?.streamFailure ?? "request_or_exception"
                    failures[reason, default: 0] += 1
                }
                self.coverageText = "覆盖率自检：\(offset + 1)/\(sample.count)"
            }
            let profileText = profiles.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            let failureText = failures.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            self.coverageText = "覆盖率：\(passed)/\(sample.count)\nprofile：\(profileText.isEmpty ? "无" : profileText)\n失败：\(failureText.isEmpty ? "无" : failureText)"
            self.coverageRunning = false
        }
    }

    private func configureAudioSession() throws {
        guard !configuredAudio else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])
        try session.setActive(true)
        configuredAudio = true
    }

    private func installPlayerObservers(item: AVPlayerItem, track: ItemDTO) {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main,
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = String(format: "%.1f s", time.seconds)
            self.refreshNowPlaying()
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
        player?.pause()
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

    private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .began { player?.pause(); isPlaying = false }
        if type == .ended,
           let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
           AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
            player?.play(); isPlaying = true; refreshNowPlaying()
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
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
