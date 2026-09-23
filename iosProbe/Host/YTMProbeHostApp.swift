import SwiftUI
import AVFoundation
import YTMProbe

@main
struct YTMProbeHostApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeScreen()
        }
    }
}

@MainActor
final class ProbeModel: ObservableObject {
    @Published var state = "启动中"
    @Published var egress = "检查中"
    @Published var client = "-"
    @Published var profile = "-"
    @Published var transport = "-"
    @Published var bytes = "-"
    @Published var playerStatus = "-"
    @Published var currentTime = "0"
    @Published var verdict = "PROBE_PLAY=RUNNING"
    @Published var failureDetail = ""

    private var player: AVPlayer?
    private var rangeServer: LoopbackRangeServer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { await run() }
    }

    private func run() async {
        await readEgress()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let result = try await YTMProbe().run(
                playlistId: "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62",
                videoId: "DcDbKDAb7go",
                cookie: nil,
                tokenGroup: "baseline",
                tokenServiceUrl: "http://127.0.0.1:4416/get_pot",
                candidateVideoIds: ["DcDbKDAb7go", "XgAgFCO-ufI", "MpevbZazUf8", "nqMYG2Riq54"],
                sampleCount: 1,
                collectFullAudio: true,
                forceSabr: true
            )
            if let failureStage = result.failureStage {
                client = result.audioClient ?? "-"
                profile = result.audioProfile ?? "-"
                transport = "-"
                bytes = "-"
                state = "Kotlin 失败阶段：\(failureStage)"
                let diagnostic = result.diagnostic.isEmpty ? "" : "\n\n诊断：\n\(result.diagnostic)"
                failureDetail = "\(result.failureType ?? "KotlinException")\n\(result.failureMessage ?? "无错误消息")\(diagnostic)"
                verdict = "PROBE_PLAY=FAIL reason=kotlin_\(failureStage)"
                return
            }
            client = result.audioClient ?? "unknown"
            profile = result.audioProfile ?? "unknown"
            transport = result.isSabr ? "SABR" : "HTTP"
            bytes = "\(result.streamBytesPulled) / \(String(describing: result.audioExpectedBytes))"
            guard result.streamOk, result.isSabr, result.audioComplete,
                  let path = result.audioCachePath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)), !data.isEmpty else {
                state = "取流失败 / 非 SABR / 下载未完成"
                let reason = !result.streamOk ? "stream" : (!result.isSabr ? "not_sabr" : "download")
                verdict = "PROBE_PLAY=FAIL reason=\(reason)"
                return
            }
            try? FileManager.default.removeItem(atPath: path)
            let server = try LoopbackRangeServer(data: data, mimeType: result.audioMimeType ?? "audio/mp4")
            rangeServer = server
            try server.start()
            let item = AVPlayerItem(url: server.url)
            player = AVPlayer(playerItem: item)
            let deadline = Date().addingTimeInterval(45)
            while item.status == .unknown && Date() < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            playerStatus = "\(item.status.rawValue)"
            guard item.status == .readyToPlay else {
                state = item.error.map { "AVPlayer error domain=\(($0 as NSError).domain) code=\(($0 as NSError).code)" } ?? "AVPlayer 未 readyToPlay"
                verdict = "PROBE_PLAY=FAIL reason=player_not_ready"
                return
            }
            player?.play()
            try await Task.sleep(for: .seconds(3))
            let time = player?.currentTime().seconds ?? 0
            currentTime = String(format: "%.2f s", time)
            playerStatus = "\(item.status.rawValue)"
            let passed = time > 0
            state = passed ? "播放时间前进" : (item.error.map { "AVPlayer error domain=\(($0 as NSError).domain) code=\(($0 as NSError).code)" } ?? "播放时间未前进")
            verdict = passed ? "PROBE_PLAY=PASS" : "PROBE_PLAY=FAIL reason=time_not_advancing"
        } catch {
            let nsError = error as NSError
            let detail = nsError.localizedDescription == "The operation couldn’t be completed. (KotlinException error 0.)"
                ? "KotlinException 未提供消息"
                : nsError.localizedDescription
            state = "运行错误：\(detail)\n\(nsError.domain) / \(nsError.code)"
            failureDetail = detail
            verdict = "PROBE_PLAY=FAIL reason=runtime_error"
        }
    }

    private func readEgress() async {
        do {
            async let ipRequest = URLSession.shared.data(from: URL(string: "https://api.ipify.org")!)
            async let infoRequest = URLSession.shared.data(from: URL(string: "https://ipinfo.io/json")!)
            let (ipData, _) = try await ipRequest
            let (infoData, _) = try await infoRequest
            let info = (try? JSONSerialization.jsonObject(with: infoData)) as? [String: String] ?? [:]
            egress = "\(String(decoding: ipData, as: UTF8.self)) | \(info["org"] ?? "unknown")"
        } catch {
            egress = "查询失败：\(type(of: error))"
        }
    }
}

struct ProbeScreen: View {
    @StateObject private var model = ProbeModel()

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("YT Music 真机播放探针")
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                            .id("probe-top")
                        row("公网 IP / ISP", model.egress)
                        row("client / profile", "\(model.client) / \(model.profile)")
                        row("传输 / 实收字节", "\(model.transport) / \(model.bytes)")
                        row("AVPlayer status", model.playerStatus)
                        row("currentTime", model.currentTime)
                        row("状态", model.state)
                        if !model.failureDetail.isEmpty {
                            Text(model.failureDetail)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(model.verdict)
                            .font(.system(.headline, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("开始探测") {
                            model.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .onChange(of: model.failureDetail) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("probe-top", anchor: .top)
                    }
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
