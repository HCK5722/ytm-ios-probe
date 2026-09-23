import AVFoundation
import XCTest
import YTMProbe

final class PhaseZeroProbeTests: XCTestCase {
    private let playlistID = "PLd9orNjDFThOxxBaWd36m-6a87SO34Y62"
    private let videoID = "DcDbKDAb7go"

    func testPhaseZeroChain() async throws {
        let cookie = ProcessInfo.processInfo.environment["YT_COOKIE"]
        let result = try await YTMProbe().run(
            playlistId: playlistID,
            videoId: videoID,
            cookie: cookie
        )

        print("PROBE_1_LINK=PASS framework=YTMProbe target=iosSimulatorArm64")
        print("PROBE_2_DARWIN=\(result.darwinHttpOk ? "PASS" : "FAIL") status=\(result.darwinStatus)")
        print("PROBE_3_BROWSE=\(result.browseOk ? "PASS" : "FAIL") status=\(result.browseStatus) bytes=\(result.browseBytes)")
        print("PROBE_3_SEARCH=\(result.searchOk ? "PASS" : "FAIL") status=\(result.searchStatus) bytes=\(result.searchBytes)")
        print("PROBE_4_STREAM=\(result.streamOk ? "PASS" : "FAIL") attempts=\(result.streamAttempts) failure=\(result.streamFailure ?? "nil") itag=\(result.audioItag) mime=\(result.audioMimeType ?? "nil") client=\(result.audioClient ?? "nil") profile=\(result.audioProfile ?? "nil") sabr=\(result.isSabr)")
        print("PROBE_6_LOGIN=\(result.loginState) status=\(result.loginStatus) bytes=\(result.loginBytes)")
        print("PROBE_DIAGNOSTIC_BEGIN\n\(result.diagnostic)\nPROBE_DIAGNOSTIC_END")

        XCTAssertTrue(result.darwinHttpOk, "Ktor Darwin request did not succeed")
        XCTAssertTrue(result.browseOk, "Anonymous playlist browse did not return the target playlist")
        XCTAssertTrue(result.searchOk, "Anonymous YT Music search did not return a substantial response")
        XCTAssertTrue(result.streamOk, "innertubex did not resolve an audio stream")
        if cookie?.isEmpty == false {
            XCTAssertEqual(result.loginState, "PASS", "Provided cookie did not validate account browse")
        } else {
            XCTAssertEqual(result.loginState, "SKIP_NO_CREDENTIAL")
        }

        guard let audioURLString = result.audioUrl,
              let audioURL = URL(string: audioURLString) else {
            XCTFail("Resolved stream did not contain a valid audio URL")
            return
        }
        guard !result.isSabr, audioURL.scheme == "https" else {
            print("PROBE_5_AVPLAYER=FAIL reason=SABR_REQUIRES_ADAPTER urlScheme=\(audioURL.scheme ?? "nil")")
            XCTFail("Stream is SABR-only; AVPlayer needs loopback or resource-loader adaptation")
            return
        }

        var options: [String: Any] = [:]
        if !result.audioHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = result.audioHeaders
        }
        let asset = AVURLAsset(url: audioURL, options: options)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)

        try await waitUntilReady(item, timeoutSeconds: 45)
        XCTAssertEqual(item.status, .readyToPlay, "AVPlayerItem never became readyToPlay: \(item.error?.localizedDescription ?? "no error")")

        player.play()
        try await Task.sleep(for: .seconds(3))
        let seconds = player.currentTime().seconds
        print("PROBE_5_AVPLAYER=\(seconds > 0 ? "PASS" : "FAIL") status=\(item.status.rawValue) currentTime=\(seconds)")
        XCTAssertGreaterThan(seconds, 0, "AVPlayer currentTime did not advance")
        player.pause()
    }

    private func waitUntilReady(_ item: AVPlayerItem, timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while item.status == .unknown && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        if item.status == .failed {
            throw item.error ?? ProbeFailure.playerFailed
        }
        if item.status != .readyToPlay {
            throw ProbeFailure.readyTimeout
        }
    }
}

private enum ProbeFailure: Error {
    case playerFailed
    case readyTimeout
}
