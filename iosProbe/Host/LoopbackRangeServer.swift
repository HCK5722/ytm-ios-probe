import Foundation
import Darwin

final class LoopbackRangeServer: @unchecked Sendable {
    private let data: Data
    private let mimeType: String
    private var socketFD: Int32 = -1
    private(set) var url: URL!

    init(data: Data, mimeType: String) {
        self.data = data
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
        let range = rangeLine.flatMap { line -> Range<Int>? in
            guard let match = line.range(of: #"bytes=(\d+)-(\d*)"#, options: .regularExpression) else { return nil }
            let parts = line[match].dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard let start = Int(parts[0]), start < data.count else { return nil }
            let end = parts.count > 1 && !parts[1].isEmpty ? min(Int(parts[1]) ?? data.count - 1, data.count - 1) : data.count - 1
            return start..<(max(start, end) + 1)
        }
        let selected = range ?? (0..<data.count)
        let status = range == nil ? "200 OK" : "206 Partial Content"
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(mimeType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(selected.count)\r\nConnection: close\r\n"
        if range != nil { headers += "Content-Range: bytes \(selected.lowerBound)-\(selected.upperBound - 1)/\(data.count)\r\n" }
        headers += "\r\n"
        sendAll(client, Array(headers.utf8))
        data.subdata(in: selected).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
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
