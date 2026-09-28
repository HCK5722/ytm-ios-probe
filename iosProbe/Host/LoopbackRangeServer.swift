import Foundation
import Darwin
import YTMProbe

final class StreamingAudioState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var path = ""
    private(set) var mimeType = "audio/mp4"
    private(set) var expectedBytes: Int64 = 0
    private(set) var availableBytes: Int64 = 0
    private(set) var completed = false
    private(set) var failure: String?
    private(set) var resolveMs: Int64?
    private(set) var firstChunkMs: Int64?
    private(set) var firstChunkInitialization: Bool?
    private(set) var firstResponseMs: Int64?
    private(set) var firstResponseStatus: Int32?
    private(set) var firstResponseSegments: Int32?
    private(set) var firstResponseMediaBytes: Int64?
    private(set) var firstResponseInitialization = false
    private(set) var firstResponseFailureCategory = ""
    private(set) var responseCount = 0
    private(set) var cumulativeSegments = 0
    private(set) var cumulativeMediaBytes: Int64 = 0
    private(set) var lastResponseMs: Int64?
    private(set) var lastResponseStatus: Int32?
    private(set) var lastResponseSegments: Int32?
    private(set) var lastResponseMediaBytes: Int64?
    private(set) var lastResponseFailureCategory = ""
    private(set) var lastAvailableMs: Int64?

    func started(path: String, mimeType: String, expectedBytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        self.path = path
        self.mimeType = mimeType
        self.expectedBytes = expectedBytes
    }

    func resolved(elapsedMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        resolveMs = elapsedMs
    }

    func available(_ bytes: Int64) {
        lock.lock()
        if bytes > availableBytes { lastAvailableMs = Int64(Date().timeIntervalSince1970 * 1000) }
        availableBytes = max(availableBytes, bytes)
        lock.unlock()
    }

    func recordFirstChunk(elapsedMs: Int64, initialization: Bool) {
        lock.lock(); defer { lock.unlock() }
        if firstChunkMs == nil {
            firstChunkMs = elapsedMs
            firstChunkInitialization = initialization
        }
    }

    func recordSabrResponse(elapsedMs: Int64, status: Int32?, segments: Int32, mediaBytes: Int64, initialization: Bool, failureCategory: String) {
        lock.lock(); defer { lock.unlock() }
        responseCount += 1
        cumulativeSegments += Int(segments)
        cumulativeMediaBytes += mediaBytes
        lastResponseMs = elapsedMs
        lastResponseStatus = status
        lastResponseSegments = segments
        lastResponseMediaBytes = mediaBytes
        lastResponseFailureCategory = failureCategory
        if firstResponseMs == nil {
            firstResponseMs = elapsedMs
            firstResponseStatus = status
            firstResponseSegments = segments
            firstResponseMediaBytes = mediaBytes
            firstResponseInitialization = initialization
            firstResponseFailureCategory = failureCategory
        }
    }

    func completedSuccessfully() {
        lock.lock(); completed = true; lock.unlock()
    }

    func failed(_ message: String) {
        lock.lock(); failure = message; completed = true; lock.unlock()
    }

    func snapshot() -> (path: String, mimeType: String, expected: Int64, available: Int64, completed: Bool, failure: String?, resolveMs: Int64?, firstChunkMs: Int64?, firstChunkInitialization: Bool?, firstResponseMs: Int64?, firstResponseStatus: Int32?, firstResponseSegments: Int32?, firstResponseMediaBytes: Int64?, firstResponseInitialization: Bool, firstResponseFailureCategory: String, responseCount: Int, cumulativeSegments: Int, cumulativeMediaBytes: Int64, lastResponseMs: Int64?, lastResponseStatus: Int32?, lastResponseSegments: Int32?, lastResponseMediaBytes: Int64?, lastResponseFailureCategory: String, lastAvailableMs: Int64?) {
        lock.lock(); defer { lock.unlock() }
        return (path, mimeType, expectedBytes, availableBytes, completed, failure, resolveMs, firstChunkMs, firstChunkInitialization, firstResponseMs, firstResponseStatus, firstResponseSegments, firstResponseMediaBytes, firstResponseInitialization, firstResponseFailureCategory, responseCount, cumulativeSegments, cumulativeMediaBytes, lastResponseMs, lastResponseStatus, lastResponseSegments, lastResponseMediaBytes, lastResponseFailureCategory, lastAvailableMs)
    }
}

final class StreamingAudioSink: AudioStreamSink {
    let state: StreamingAudioState
    var onStateChanged: ((StreamingAudioState) -> Void)?

    init(state: StreamingAudioState) { self.state = state }

    func onStreamResolved(elapsedMs: String) {
        state.resolved(elapsedMs: Int64(elapsedMs) ?? -1)
        onStateChanged?(state)
    }

    func onStreamStarted(path: String, mimeType: String, client: String, profile: String, expectedBytes: String) {
        state.started(path: path, mimeType: mimeType, expectedBytes: Int64(expectedBytes) ?? 0)
    }

    func onChunkAvailable(bytesAvailable: String) {
        state.available(Int64(bytesAvailable) ?? 0)
    }

    func onSabrResponse(elapsedMs: String, httpStatus: String, segments: String, mediaBytes: String, initializationReceived: Bool, failureCategory: String) {
        state.recordSabrResponse(
            elapsedMs: Int64(elapsedMs) ?? 0,
            status: Int32(httpStatus),
            segments: Int32(segments) ?? 0,
            mediaBytes: Int64(mediaBytes) ?? 0,
            initialization: initializationReceived,
            failureCategory: failureCategory,
        )
        onStateChanged?(state)
    }

    func onSabrChunk(elapsedMs: String, initialization: Bool) {
        state.recordFirstChunk(elapsedMs: Int64(elapsedMs) ?? 0, initialization: initialization)
        onStateChanged?(state)
    }

    func onStreamCompleted() { state.completedSuccessfully() }

    func onStreamFailed(type: String, message: String) {
        state.failed("\(type): \(message)")
        onStateChanged?(state)
    }
}

final class LoopbackRangeServer: @unchecked Sendable {
    private let data: Data?
    private let streamState: StreamingAudioState?
    private let mimeType: String
    private var socketFD: Int32 = -1
    private(set) var url: URL!

    init(data: Data, mimeType: String) {
        self.data = data
        self.streamState = nil
        self.mimeType = mimeType
    }

    init(streamState: StreamingAudioState, mimeType: String) {
        self.data = nil
        self.streamState = streamState
        self.mimeType = mimeType
    }

    func start() throws {
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ServerError.socket }
        var noSigPipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 8) == 0 else { throw ServerError.bind }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else { throw ServerError.bind }
        let port = UInt16(bigEndian: actual.sin_port)
        // Keep the URL suffix aligned with the MP4/AAC stream selected by
        // innertubex. AVPlayer may use the path extension in addition to the
        // Content-Type header when deciding which demuxer to load.
        url = URL(string: "http://127.0.0.1:\(port)/audio.mp4")!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while socketFD >= 0 {
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let text = readRequest(client) else { return }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let method = requestLine.split(separator: " ", maxSplits: 1).first.map(String.init)?.uppercased() ?? "GET"
        let headOnly = method == "HEAD"
        let rangeLine = lines.first { $0.lowercased().hasPrefix("range:") }
        let requested = rangeLine.flatMap { line -> (Int, Int?)? in
            guard let match = line.range(of: #"bytes=(\d+)-(\d*)"#, options: .regularExpression) else { return nil }
            let parts = line[match].dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            return (start, parts.count > 1 && !parts[1].isEmpty ? Int(parts[1]) : nil)
        } ?? (0, nil)

        if let data {
            let total = data.count
            if rangeLine == nil {
                sendData(client, data: data, range: 0..<total, total: total, partial: false, headOnly: headOnly)
                return
            }
            guard requested.0 < total else { return }
            let end = min(requested.1 ?? (total - 1), total - 1)
            sendData(client, data: data, range: requested.0..<(end + 1), total: total, partial: true, headOnly: headOnly)
            return
        }

        guard let streamState else { return }
        sendStreamingResponse(
            client,
            state: streamState,
            start: requested.0,
            requestedEnd: requested.1,
            ranged: rangeLine != nil,
            headOnly: headOnly,
        )
    }

    private func sendStreamingResponse(
        _ client: Int32,
        state: StreamingAudioState,
        start: Int,
        requestedEnd: Int?,
        ranged: Bool,
        headOnly: Bool,
    ) {
        let deadline = Date().addingTimeInterval(30)
        var responseSent = false
        var cursor = Int64(start)
        var targetEnd: Int64?

        while Date() < deadline {
            let snapshot = state.snapshot()
            if let failure = snapshot.failure, !responseSent {
                _ = failure
                return
            }

            let knownTotal = snapshot.expected > 0 ? snapshot.expected : (snapshot.completed ? snapshot.available : 0)
            if targetEnd == nil {
                if let requestedEnd {
                    targetEnd = Int64(requestedEnd)
                } else if knownTotal > 0 {
                    targetEnd = knownTotal - 1
                } else if snapshot.completed {
                    targetEnd = snapshot.available - 1
                }
            }

            guard let end = targetEnd, end >= Int64(start) else {
                if snapshot.completed { return }
                usleep(50_000)
                continue
            }

            if !responseSent {
                let total = knownTotal > 0 ? knownTotal : end + 1
                let contentLength = max(0, end - Int64(start) + 1)
                let contentRange = ranged ? "bytes \(start)-\(end)/\(total > 0 ? String(total) : "*")" : nil
                let status = ranged ? "206 Partial Content" : "200 OK"
                var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(mimeType)\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nContent-Length: \(contentLength)\r\nConnection: close\r\n"
                if let contentRange { headers += "Content-Range: \(contentRange)\r\n" }
                headers += "\r\n"
                sendAll(client, Array(headers.utf8))
                responseSent = true
                if headOnly { return }
            }

            let availableEnd = snapshot.available - 1
            if cursor <= min(end, availableEnd),
               let bytes = readFile(snapshot.path, range: Int(cursor)..<Int(min(end, availableEnd) + 1)),
               !bytes.isEmpty {
                bytes.withUnsafeBytes { raw in
                    if let base = raw.baseAddress { sendAll(client, base, raw.count) }
                }
                cursor += Int64(bytes.count)
                if cursor > end { return }
                continue
            }

            if snapshot.completed || (snapshot.failure != nil && cursor >= snapshot.available) { return }
            usleep(50_000)
        }
    }

    private func readRequest(_ client: Int32) -> String? {
        var received = Data()
        let terminator = Data([13, 10, 13, 10])
        while received.count < 16 * 1024 {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let size = chunk.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return recv(client, base, raw.count, 0)
            }
            guard size > 0 else { break }
            received.append(contentsOf: chunk[0..<size])
            if received.range(of: terminator) != nil { break }
        }
        return String(data: received, encoding: .utf8)
    }

    private func readFile(_ path: String, range: Range<Int>) -> Data? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        try? file.seek(toOffset: UInt64(range.lowerBound))
        return try? file.read(upToCount: range.count) ?? nil
    }

    private func sendData(_ client: Int32, data: Data, range: Range<Int>, total: Int, partial: Bool, headOnly: Bool = false, contentRange: String? = nil) {
        let status = partial ? "206 Partial Content" : "200 OK"
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(mimeType)\r\nAccept-Ranges: bytes\r\nCache-Control: no-cache\r\nContent-Length: \(range.count)\r\nConnection: close\r\n"
        if let contentRange { headers += "Content-Range: \(contentRange)\r\n" }
        else if partial { headers += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)\r\n" }
        headers += "\r\n"
        sendAll(client, Array(headers.utf8))
        if headOnly { return }
        data.subdata(in: range).withUnsafeBytes { raw in
            if let base = raw.baseAddress { sendAll(client, base, raw.count) }
        }
    }

    private func sendAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in if let base = raw.baseAddress { sendAll(fd, base, raw.count) } }
    }

    private func sendAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) {
        var sent = 0
        while sent < count {
            let result = send(fd, pointer.advanced(by: sent), count - sent, 0)
            if result <= 0 { return }
            sent += result
        }
    }

    deinit { if socketFD >= 0 { close(socketFD) } }

    private enum ServerError: Error { case socket, bind }
}
