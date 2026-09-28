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
    private var servedOffsets: [ObjectIdentifier: Int64] = [:]
    private var activeRequests: [ObjectIdentifier: AVAssetResourceLoadingRequest] = [:]
    private var invalidated = false

    init(state: StreamingAudioState) {
        self.state = state
    }

    func invalidate() {
        queue.sync {
            invalidated = true
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "SABR resource loader invalidated"],
            )
            activeRequests.values.forEach { $0.finishLoading(with: error) }
            activeRequests.removeAll()
            servedOffsets.removeAll()
            cancelled.removeAll()
        }
    }

    func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest,
    ) -> Bool {
        queue.async { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            let identifier = ObjectIdentifier(loadingRequest)
            self.activeRequests[identifier] = loadingRequest
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
            let identifier = ObjectIdentifier(loadingRequest)
            self.cancelled.insert(identifier)
            self.servedOffsets.removeValue(forKey: identifier)
            self.activeRequests.removeValue(forKey: identifier)
        }
    }

    private func pump(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let identifier = ObjectIdentifier(loadingRequest)
        guard !invalidated, !cancelled.contains(identifier) else {
            activeRequests.removeValue(forKey: identifier)
            return
        }

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
        // Most requests carry the explicit EOF flag, but iOS 27 can also
        // deliver an open-ended request with requestedLength == 0. Treat both
        // forms as open-ended so the first SABR fragment does not terminate
        // the loader before later media fragments arrive.
        let requestedLength = Int64(dataRequest.requestedLength)
        let openEnded = dataRequest.requestsAllDataToEndOfResource || requestedLength <= 0
        let requestedEnd = openEnded
            ? (snapshot.expected > requestedOffset ? snapshot.expected : Int64.max)
            : requestedOffset + max(0, requestedLength)
        let currentOffset = max(requestedOffset, dataRequest.currentOffset, servedOffsets[identifier] ?? requestedOffset)
        let availableEnd = snapshot.available

        if currentOffset < availableEnd {
            let end = min(requestedEnd, availableEnd)
            if let bytes = readFile(snapshot.path, start: currentOffset, end: end), !bytes.isEmpty {
                dataRequest.respond(with: bytes)
                servedOffsets[identifier] = currentOffset + Int64(bytes.count)
            }
        }

        let updatedOffset = max(requestedOffset, dataRequest.currentOffset, servedOffsets[identifier] ?? requestedOffset)
        let requestFinished = openEnded
            ? (snapshot.completed && updatedOffset >= min(requestedEnd, snapshot.available))
            : (requestedLength > 0 && updatedOffset >= requestedEnd)
        if requestFinished {
            loadingRequest.finishLoading()
            cancelled.insert(identifier)
            servedOffsets.removeValue(forKey: identifier)
            activeRequests.removeValue(forKey: identifier)
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
            servedOffsets.removeValue(forKey: identifier)
            activeRequests.removeValue(forKey: identifier)
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
