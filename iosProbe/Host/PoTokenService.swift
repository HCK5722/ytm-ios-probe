import Foundation
import Network
import WebKit

/// Device-local BotGuard/PoToken service. It deliberately listens only on loopback.
@MainActor
final class PoTokenService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ytm.probe.potoken", qos: .userInitiated)
    private var listener: NWListener?
    private var engine: PoTokenEngine?

    func start() {
        guard listener == nil else { return }
        Task { @MainActor in
            if self.engine == nil { self.engine = PoTokenEngine() }
        }
        do {
            let newListener = try NWListener(using: .tcp, on: 4416)
            newListener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("PROBE_POT_SERVICE state=failed type=%@", String(describing: error))
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener = newListener
            newListener.start(queue: queue)
        } catch {
            NSLog("PROBE_POT_SERVICE state=start_failed type=%@", String(describing: error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Task { @MainActor in
            self.engine?.close()
            self.engine = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, data: Data())
    }

    private func receiveRequest(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
            var combined = data
            if let chunk { combined.append(chunk) }
            if let error {
                connection.cancel()
                NSLog("PROBE_POT_SERVICE request_error type=%@", String(describing: error))
                return
            }
            if let range = combined.range(of: Data([13, 10, 13, 10])) {
                let headerData = combined.subdata(in: 0..<range.lowerBound)
                let headerText = String(decoding: headerData, as: UTF8.self)
                let length = headerText.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }).flatMap {
                    Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "")
                } ?? 0
                let bodyStart = range.upperBound
                if combined.count - bodyStart < length && !isComplete {
                    self?.receiveRequest(connection, data: combined)
                    return
                }
                let bodyEnd = min(combined.count, bodyStart + length)
                let body = combined.subdata(in: bodyStart..<bodyEnd)
                self?.handle(body: body, connection: connection)
                return
            }
            if isComplete {
                connection.cancel()
            } else {
                self?.receiveRequest(connection, data: combined)
            }
            }
        }
    }

    private func handle(body: Data, connection: NWConnection) {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let binding = object["content_binding"] as? String,
            !binding.isEmpty,
            binding.count <= 1024
        else {
            reply(connection, status: 400, object: ["error": "invalid_request"])
            return
        }
        Task { @MainActor in
            do {
                if self.engine == nil { self.engine = PoTokenEngine() }
                let token = try await self.engine!.token(for: binding)
                self.reply(connection, status: 200, object: [
                    "poToken": token,
                    "contentBinding": binding,
                ])
            } catch {
                NSLog("PROBE_POT_SERVICE token_failed type=%@", String(describing: error))
                self.reply(connection, status: 503, object: ["error": "token_unavailable"])
            }
        }
    }

    private func reply(_ connection: NWConnection, status: Int, object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

@MainActor
private final class PoTokenEngine: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loaded = false
    private var ready = false
    private var initialization: Task<Void, Error>?
    private var streamingToken: String?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
    }

    func close() {
        initialization?.cancel()
        initialization = nil
        ready = false
        loaded = false
        streamingToken = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    func token(for binding: String) async throws -> String {
        if !ready {
            if initialization == nil {
                initialization = Task { try await initialize() }
            }
            try await initialization?.value
        }
        guard ready else { throw PoTokenError.notReady }
        if binding == streamingBindingPlaceholder { return streamingToken ?? "" }
        return try await mint(binding)
    }

    private func initialize() async throws {
        let html = try loadPage()
        try await load(html)
        let create = try await serviceRequest(url: "https://www.youtube.com/api/jnn/v1/Create", body: ["O43z0dpjhgX20SCx4KAo"])
        let challenge = try parseChallenge(create)
        let challengeJSON = try jsonString(challenge)
        let botguard = try await evaluate("""
        data = (challengeJSON);
        runBotGuard(data).then(function(result) {
          window.__webPoSignalOutput = result.webPoSignalOutput;
          return result.botguardResponse;
        })
        """)
        guard let botguardText = botguard as? String else { throw PoTokenError.javascript }
        let integrity = try await serviceRequest(url: "https://www.youtube.com/api/jnn/v1/GenerateIT", body: ["O43z0dpjhgX20SCx4KAo", botguardText])
        guard let integrityArray = integrity as? [Any], let encoded = integrityArray.first as? String else { throw PoTokenError.integrity }
        let bytes = try decodeBase64URL(encoded)
        let byteLiteral = bytes.map(String.init).joined(separator: ",")
        _ = try await evaluate("createPoTokenMinter(window.__webPoSignalOutput, new Uint8Array([(byteLiteral)])).then(function(){ return true; })")
        ready = true
        NSLog("PROBE_POT_SERVICE ready=1")
    }

    private func mint(_ identifier: String) async throws -> String {
        let idJSON = try jsonString(identifier)
        let value = try await evaluate("obtainPoToken(new TextEncoder().encode((idJSON))).then(function(x){ return Array.from(x); })")
        guard let numbers = value as? [NSNumber], !numbers.isEmpty else { throw PoTokenError.javascript }
        let bytes = numbers.map { UInt8(truncating: $0) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func loadPage() throws -> String {
        guard let htmlURL = Bundle.main.url(forResource: "po_token", withExtension: "html"),
              let solverURL = Bundle.main.url(forResource: "yt.solver.core", withExtension: "js"),
              let html = try? String(contentsOf: htmlURL, encoding: .utf8),
              let solver = try? String(contentsOf: solverURL, encoding: .utf8)
        else { throw PoTokenError.assets }
        return html.replacingOccurrences(of: "</head>", with: "<script>\(solver)</script></head>")
    }

    private func load(_ html: String) async throws {
        guard let baseURL = URL(string: "https://www.youtube.com/") else { throw PoTokenError.navigation }
        try await withCheckedThrowingContinuation { continuation in
            navigationContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
        loaded = true
    }

    private func evaluate(_ script: String) async throws -> Any {
        guard loaded else { throw PoTokenError.navigation }
        if #available(iOS 15.0, *) {
            return try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page)
        }
        throw PoTokenError.unsupported
    }

    private func serviceRequest(url: String, body: [Any]) async throws -> Any {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw", forHTTPHeaderField: "x-goog-api-key")
        request.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "x-user-agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PoTokenError.http }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func parseChallenge(_ raw: Any) throws -> [String: Any] {
        guard let outer = raw as? [Any], let first = outer.first else { throw PoTokenError.challenge }
        var data: [Any]?
        if outer.count > 1, let encoded = outer[1] as? String, let decoded = decodeBase64URLBytes(encoded) {
            let shifted = Data(decoded.map { UInt8((Int($0) + 97) & 255) })
            data = (try? JSONSerialization.jsonObject(with: shifted) as? [Any])?.first as? [Any]
        } else {
            data = first as? [Any]
        }
        guard let values = data, values.count > 5 else { throw PoTokenError.challenge }
        func firstString(_ value: Any?) -> String? { (value as? [Any])?.compactMap { $0 as? String }.first }
        guard let safe = firstString(values[1]), let trusted = firstString(values[2]) else { throw PoTokenError.challenge }
        return [
            "messageId": values[0],
            "interpreterJavascript": [
                "privateDoNotAccessOrElseSafeScriptWrappedValue": safe,
                "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": trusted,
            ],
            "interpreterHash": values[3],
            "program": values[4],
            "globalName": values[5],
        ]
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeBase64URL(_ value: String) throws -> [UInt8] {
        guard let bytes = decodeBase64URLBytes(value) else { throw PoTokenError.integrity }
        return bytes
    }

    private func decodeBase64URLBytes(_ value: String) -> [UInt8]? {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ".", with: "=")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized).map(Array.init)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume()
        navigationContinuation = nil
    }
}

private enum PoTokenError: Error { case notReady, javascript, integrity, assets, navigation, http, challenge, unsupported }
