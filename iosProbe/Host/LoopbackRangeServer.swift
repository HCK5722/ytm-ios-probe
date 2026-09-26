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

    func started(path: String, mimeType: String, expectedBytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        self.path = path
        self.mimeType = mimeType
        self.expectedBytes = expectedBytes
    }

    func available(_ bytes: Int64) {
        lock.lock(); availableBytes = max(availableBytes, bytes); lock.unlock()
    }

    func completedSuccessfully() {
        lock.lock(); completed = true; lock.unlock()
    }

    func failed(_ message: String) {
        lock.lock(); failure = message; completed = true; lock.unlock()
    }

    func snapshot() -> (path: String, mimeType: String, expected: Int64, available: Int64, completed: Bool, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (path, mimeType, expectedBytes, availableBytes, completed, failure)
    }
}

final class StreamingAudioSink: AudioStreamSink {
    let state: StreamingAudioState

    init(state: StreamingAudioState) { self.state = state }

    func onStreamStarted(path: String, mimeType: String, client: String, profile: String, expectedBytes: String) {
        state.started(path: path, mimeType: mimeType, expectedBytes: Int64(expectedBytes) ?? 0)
    }

    func onChunkAvailable(bytesAvailable: String) {
        state.available(Int64(bytesAvailable) ?? 0)
    }

    func onStreamCompleted() { state.completedSuccessfully() }

    func onStreamFailed(type: String, message: String) {
        state.failed("\(type): \(message)")
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
        var request = [UInt8](repeating: 0, count: 8192)
        let size = request.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            return recv(client, base, raw.count, 0)
        }
        guard size > 0, let text = String(bytes: request[..<size], encoding: .utf8) else { return }
        let rangeLine = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
        let requested = rangeLine.flatMap { line -> (Int, Int?)? in
            guard let match = line.range(of: #"bytes=(\d+)-(\d*)"#, options: .regularExpression) else { return nil }
            let parts = line[match].dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            return (start, parts.count > 1 && !parts[1].isEmpty ? Int(parts[1]) : nil)
        } ?? (0, nil)

        if let data {
            let total = data.count
            guard requested.0 < total else { return }
            let end = min(requested.1 ?? (total - 1), total - 1)
            sendData(client, data: data, range: requested.0..<(end + 1), total: total, partial: rangeLine != nil)
            return
        }

        guard let streamState else { return }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let snapshot = streamState.snapshot()
            if let failure = snapshot.failure {
                _ = failure
                return
            }
            let total = snapshot.expected > 0 ? snapshot.expected : snapshot.available
            if requested.0 < snapshot.available {
                let requestedEnd = requested.1.map(Int64.init)
                let end = min(requestedEnd ?? (snapshot.completed ? total - 1 : snapshot.available - 1), snapshot.available - 1)
                if end >= Int64(requested.0), let bytes = readFile(snapshot.path, range: requested.0..<Int(end + 1)) {
                    sendData(client, data: bytes, range: 0..<bytes.count, total: Int(total), partial: true, contentRange: "bytes \(requested.0)-\(end)/\(total > 0 ? String(total) : "*")")
                    return
                }
            }
            if snapshot.completed { return }
            usleep(50_000)
        }
    }

    private func readFile(_ path: String, range: Range<Int>) -> Data? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        try? file.seek(toOffset: UInt64(range.lowerBound))
        return try? file.read(upToCount: range.count) ?? nil
    }

    private func sendData(_ client: Int32, data: Data, range: Range<Int>, total: Int, partial: Bool, contentRange: String? = nil) {
        let status = partial ? "206 Partial Content" : "200 OK"
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(mimeType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nConnection: close\r\n"
        if let contentRange { headers += "Content-Range: \(contentRange)\r\n" }
        else if partial { headers += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)\r\n" }
        headers += "\r\n"
        sendAll(client, Array(headers.utf8))
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
