import Foundation
import AVFoundation

/// Feeds an AVPlayer loading request from the SABR file while it grows.
/// This avoids making AVPlayer consume a synthetic HTTP connection whose
/// lifetime is independent from the producer.
final class SabrResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let url = URL(string: "sabr-stream://audio.mp4")!
    let queue = DispatchQueue(label: "ytm-probe.sabr-resource-loader")

    private let state: StreamingAudioState
    private var cancelled = Set<ObjectIdentifier>()
    private var invalidated = false

    init(state: StreamingAudioState) {
        self.state = state
    }

    func invalidate() {
        queue.sync { invalidated = true }
    }

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest,
    ) -> Bool {
        queue.async { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            self.pump(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest,
    ) {
        queue.async { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            self.cancelled.insert(ObjectIdentifier(loadingRequest))
        }
    }

    private func pump(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let identifier = ObjectIdentifier(loadingRequest)
        guard !invalidated, !cancelled.contains(identifier) else { return }

        let snapshot = state.snapshot()
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = AVFileType.mp4.rawValue
            information.isByteRangeAccessSupported = true
            information.contentLength = snapshot.expected > 0 ? snapshot.expected : snapshot.available
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let requestedOffset = max(Int64(0), dataRequest.requestedOffset)
        let requestedLength = max(1, Int64(dataRequest.requestedLength))
        let requestedEnd = requestedOffset + requestedLength
        let currentOffset = max(requestedOffset, dataRequest.currentOffset)
        let availableEnd = snapshot.available

        if currentOffset < availableEnd {
            let end = min(requestedEnd, availableEnd)
            if let bytes = readFile(snapshot.path, start: currentOffset, end: end), !bytes.isEmpty {
                dataRequest.respond(with: bytes)
            }
        }

        let updatedOffset = max(requestedOffset, dataRequest.currentOffset)
        if updatedOffset >= requestedEnd {
            loadingRequest.finishLoading()
            cancelled.insert(identifier)
            return
        }

        if snapshot.completed {
            let error = NSError(
                domain: "YTMProbe.SabrResourceLoader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: snapshot.failure ?? "SABR stream ended before requested bytes arrived"],
            )
            loadingRequest.finishLoading(with: error)
            cancelled.insert(identifier)
            return
        }

        queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            self.pump(loadingRequest)
        }
    }

    private func readFile(_ path: String, start: Int64, end: Int64) -> Data? {
        guard end > start, !path.isEmpty,
              let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: UInt64(start))
            return try file.read(upToCount: Int(end - start))
        } catch {
            return nil
        }
    }
}
