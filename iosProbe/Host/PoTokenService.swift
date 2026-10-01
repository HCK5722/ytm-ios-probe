import Foundation
import Network
import WebKit

/// Device-local BotGuard/PoToken service. It deliberately listens only on loopback.
@MainActor
final class PoTokenService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ytm.probe.potoken", qos: .userInitiated)
    private var listener: NWListener?
    private var engine: PoTokenEngine?
    private var requestCount = 0
    private var successCount = 0
    private var failureCount = 0
    private var engineStatus = "starting"
    private var lastResult = "none"

    var diagnosticSummary: String {
        "engine=\(engineStatus) requests=\(requestCount) success=\(successCount) failed=\(failureCount) last=\(lastResult)"
    }

    func start() {
        guard listener == nil else { return }
        Task { @MainActor in
            if self.engine == nil { self.engine = PoTokenEngine() }
            do {
                try await self.engine?.prewarm()
                self.engineStatus = "ready"
            } catch {
                self.engineStatus = "failed_\(String(describing: error))"
            }
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
            let tokenType = object["token_type"] as? String,
            !binding.isEmpty,
            binding.count <= 1024,
            tokenType == "streaming" || tokenType == "player"
        else {
            reply(connection, status: 400, object: ["error": "invalid_request"])
            return
        }
        NSLog("PROBE_POT_SERVICE request type=%@ bindingPresent=1 bindingLength=%d", tokenType, binding.count)
        requestCount += 1
        lastResult = "pending_\(tokenType)"
        Task { @MainActor in
            do {
                if self.engine == nil { self.engine = PoTokenEngine() }
                let token = try await self.engine!.token(for: binding, type: tokenType)
                self.successCount += 1
                self.engineStatus = "ready"
                self.lastResult = "ok_\(tokenType)_len\(token.count)"
                NSLog("PROBE_POT_SERVICE result type=%@ tokenPresent=1 tokenLength=%d", tokenType, token.count)
                self.reply(connection, status: 200, object: [
                    "poToken": token,
                    "contentBinding": binding,
                ])
            } catch {
                self.failureCount += 1
                self.engineStatus = "failed"
                self.lastResult = "failed_\(tokenType)_\(String(describing: error))"
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
private final class PoTokenEngine: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private var loaded = false
    private var ready = false
    private var initialization: Task<Void, Error>?
    private var streamingBinding: String?
    private var streamingToken: String?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var evaluationContinuation: CheckedContinuation<Any, Error>?
    private var evaluationRequestID: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "ytmPoToken")
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"
    }

    func close() {
        initialization?.cancel()
        initialization = nil
        ready = false
        loaded = false
        streamingBinding = nil
        streamingToken = nil
        if let continuation = evaluationContinuation {
            evaluationContinuation = nil
            evaluationRequestID = nil
            continuation.resume(throwing: PoTokenError.javascriptDetail(stage: "webViewClosed", detail: "cancelled"))
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "ytmPoToken")
    }

    func token(for binding: String, type: String) async throws -> String {
        try await prewarm()
        guard ready else { throw PoTokenError.notReady }
        if type == "streaming" {
            if streamingBinding != binding || streamingToken == nil {
                streamingBinding = binding
                streamingToken = try await mint(binding)
            }
            return streamingToken!
        }
        return try await mint(binding)
    }

    func prewarm() async throws {
        if !ready {
            if initialization == nil {
                initialization = Task { try await initialize() }
            }
            do {
                try await initialization?.value
            } catch {
                initialization = nil
                ready = false
                loaded = false
                throw error
            }
        }
    }

    private func initialize() async throws {
        let html = try loadPage()
        try await load(html)
        let create = try await serviceRequest(url: "https://www.youtube.com/api/jnn/v1/Create", body: ["O43z0dpjhgX20SCx4KAo"])
        let challenge = try parseChallenge(create)
        let challengeJSON = try jsonString(challenge)
        let botguard = try await evaluate("""
        try {
          data = \(challengeJSON);
          var result = await runBotGuard(data);
          window.__webPoSignalOutput = result.webPoSignalOutput;
          var response = result.botguardResponse;
          if (response === null || typeof response === "undefined") {
            return {"__probe_js_error": "BotGuardResponse", "__probe_js_message": "missing"};
          }
          if (typeof response !== "string") {
            response = JSON.stringify(response);
          }
          if (typeof response !== "string") {
            return {"__probe_js_error": "BotGuardResponse", "__probe_js_message": "not_serializable"};
          }
          __probePost({"payload": response});
        } catch (e) {
          __probePost({"__probe_js_error": String(e && e.name || "Error"), "__probe_js_message": String(e && e.message || e).slice(0, 180)});
        }
        return true;
        """)
        if let error = javascriptMarker(botguard) {
            throw PoTokenError.javascriptDetail(stage: "runBotGuard", detail: error)
        }
        guard let botguardText = botguard as? String else {
            throw PoTokenError.javascriptDetail(stage: "runBotGuardResult", detail: "bridge_\(bridgeShape(botguard))")
        }
        let integrity = try await serviceRequest(url: "https://www.youtube.com/api/jnn/v1/GenerateIT", body: ["O43z0dpjhgX20SCx4KAo", botguardText])
        guard let integrityArray = integrity as? [Any], let encoded = integrityArray.first as? String else { throw PoTokenError.integrity }
        let bytes = try decodeBase64URL(encoded)
        let byteLiteral = bytes.map(String.init).joined(separator: ",")
        let minter = try await evaluate("""
        try {
          await createPoTokenMinter(window.__webPoSignalOutput, new Uint8Array([\(byteLiteral)]));
          __probePost({"payload": true});
        } catch (e) {
          __probePost({"__probe_js_error": String(e && e.name || "Error"), "__probe_js_message": String(e && e.message || e).slice(0, 180)});
        }
        return true;
        """)
        if let error = javascriptMarker(minter) {
            throw PoTokenError.javascriptDetail(stage: "createMinter", detail: error)
        }
        guard let minterReady = minter as? Bool, minterReady else {
            throw PoTokenError.javascriptDetail(stage: "createMinter", detail: "empty_or_invalid_result")
        }
        ready = true
        NSLog("PROBE_POT_SERVICE ready=1")
    }

    private func mint(_ identifier: String) async throws -> String {
        let idJSON = try jsonString(identifier)
        let value = try await evaluate("""
        try {
          var x = await obtainPoToken(new TextEncoder().encode(\(idJSON)));
          if (!(x instanceof Uint8Array)) {
            throw new Error("token_not_uint8array");
          }
          var binary = String.fromCharCode.apply(null, Array.from(x));
          var token = btoa(binary).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
          __probePost({"payload": token});
        } catch (e) {
          __probePost({"__probe_js_error": String(e && e.name || "Error"), "__probe_js_message": String(e && e.message || e).slice(0, 180)});
        }
        return true;
        """)
        if let error = javascriptMarker(value) {
            throw PoTokenError.javascriptDetail(stage: "mint", detail: error)
        }
        guard let token = value as? String, !token.isEmpty else {
            throw PoTokenError.javascriptDetail(stage: "mintResult", detail: "bridge_\(bridgeShape(value))")
        }
        return token
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

    private func evaluate(_ script: String) async throws -> Any? {
        guard loaded else { throw PoTokenError.navigation }
        guard evaluationContinuation == nil else {
            throw PoTokenError.javascriptDetail(stage: "webViewEvaluation", detail: "busy")
        }
        if #available(iOS 15.0, *) {
            let requestID = UUID().uuidString
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                evaluationContinuation = continuation
                evaluationRequestID = requestID
                let wrappedScript = """
                const __probeRequestId = "\(requestID)";
                const __probePost = function(result) {
                  window.webkit.messageHandlers.ytmPoToken.postMessage(
                    Object.assign({requestId: __probeRequestId}, result)
                  );
                };
                \(script)
                """
                Task { @MainActor in
                    do {
                        _ = try await webView.callAsyncJavaScript(wrappedScript, arguments: [:], in: nil, in: .page)
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        if evaluationRequestID == requestID, let pending = evaluationContinuation {
                            evaluationContinuation = nil
                            evaluationRequestID = nil
                            pending.resume(throwing: PoTokenError.javascriptDetail(stage: "webViewEvaluation", detail: "message_missing"))
                        }
                    } catch {
                        guard evaluationRequestID == requestID, let pending = evaluationContinuation else { return }
                        evaluationContinuation = nil
                        evaluationRequestID = nil
                        pending.resume(throwing: error)
                    }
                }
            }
        }
        throw PoTokenError.unsupported
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "ytmPoToken",
              let requestID = evaluationRequestID,
              let continuation = evaluationContinuation,
              let response = message.body as? [String: Any],
              response["requestId"] as? String == requestID
        else { return }

        evaluationContinuation = nil
        evaluationRequestID = nil
        if let name = response["__probe_js_error"] as? String,
           let detail = response["__probe_js_message"] as? String {
            continuation.resume(returning: [
                "__probe_js_error": name,
                "__probe_js_message": detail,
            ])
        } else if let payload = response["payload"] {
            continuation.resume(returning: payload)
        } else {
            continuation.resume(throwing: PoTokenError.javascriptDetail(stage: "webViewMessage", detail: "payload_missing"))
        }
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
        guard let outer = raw as? [Any], let first = outer.first else { throw PoTokenError.challengeResponse }
        var data: [Any]?
        if outer.count > 1, let encoded = outer[1] as? String, let decoded = decodeBase64URLBytes(encoded) {
            let shifted = Data(decoded.map { UInt8((Int($0) + 97) & 255) })
            // Create returns a scrambled JSON array containing the challenge
            // fields directly. Do not unwrap its first field as another array.
            data = try? JSONSerialization.jsonObject(with: shifted) as? [Any]
        } else {
            data = first as? [Any]
        }
        guard let values = data, values.count > 5 else { throw PoTokenError.challengeShape }
        func firstString(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let string = value as? String { return string }
            if let string = value as? NSString { return String(string) }
            if let array = value as? [Any] {
                for item in array {
                    if let result = firstString(item) { return result }
                }
                return nil
            }
            if let array = value as? NSArray {
                for item in array {
                    if let result = firstString(item) { return result }
                }
                return nil
            }
            if let object = value as? [String: Any] {
                let knownKeys = [
                    "privateDoNotAccessOrElseSafeScriptWrappedValue",
                    "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue",
                ]
                for key in knownKeys {
                    if let result = firstString(object[key]) { return result }
                }
                for key in object.keys.sorted() {
                    if let result = firstString(object[key]) { return result }
                }
                return nil
            }
            if let object = value as? NSDictionary {
                for key in [
                    "privateDoNotAccessOrElseSafeScriptWrappedValue",
                    "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue",
                ] {
                    if let result = firstString(object[key]) { return result }
                }
                for key in object.allKeys.compactMap({ $0 as? String }).sorted() {
                    if let result = firstString(object[key]) { return result }
                }
            }
            return nil
        }
        guard let safe = firstString(values[1]) else {
            throw PoTokenError.challengeFields(
                safe: challengeShape(values[1]),
                trusted: challengeShape(values[2]),
            )
        }
        let trusted = firstString(values[2])
        let interpreterJavascript: [String: Any] = [
            "privateDoNotAccessOrElseSafeScriptWrappedValue": safe,
            "privateDoNotAccessOrElseTrustedResourceUrlWrappedValue": trusted ?? NSNull(),
        ]
        var challenge: [String: Any] = [
            "messageId": values[0],
            "interpreterJavascript": interpreterJavascript,
            "interpreterHash": values[3],
            "program": values[4],
            "globalName": values[5],
        ]
        if values.count > 7 { challenge["clientExperimentsStateBlob"] = values[7] }
        return challenge
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return String(decoding: data, as: UTF8.self)
    }

    private func javascriptMarker(_ value: Any?) -> String? {
        guard let object = value as? [String: Any],
              let name = object["__probe_js_error"] as? String,
              let message = object["__probe_js_message"] as? String
        else { return nil }
        let combined = "\(name):\(message)"
        return combined
            .replacingOccurrences(of: "https?://[^\\s]+", with: "url", options: .regularExpression)
            .replacingOccurrences(of: "[A-Za-z0-9_-]{80,}", with: "long_value", options: .regularExpression)
            .prefix(220)
            .description
    }

    private func bridgeShape(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if value is NSNull { return "null" }
        if let string = value as? String { return "string_len\(string.count)" }
        if let array = value as? [Any] { return "array_\(array.count)" }
        if let object = value as? [String: Any] { return "object_\(object.count)" }
        return String(describing: type(of: value))
            .replacingOccurrences(of: "[^A-Za-z0-9_<>]", with: "", options: .regularExpression)
    }

    private func challengeShape(_ value: Any?, depth: Int = 0) -> String {
        guard let value else { return "missing" }
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if let array = value as? [Any] {
            guard depth < 3 else { return "array[\(array.count)]" }
            let children = array.prefix(3).map { challengeShape($0, depth: depth + 1) }
            return "array[\(array.count)](\(children.joined(separator: ",")))"
        }
        if let object = value as? [String: Any] {
            guard depth < 3 else { return "object[\(object.count)]" }
            let children = object.keys.sorted().prefix(3).compactMap { object[$0] }
                .map { challengeShape($0, depth: depth + 1) }
            return "object[\(object.count)](\(children.joined(separator: ",")))"
        }
        return "scalar"
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

private enum PoTokenError: Error {
    case notReady, javascript, integrity, assets, navigation, http
    case challengeResponse, challengeShape
    case challengeFields(safe: String, trusted: String)
    case javascriptDetail(stage: String, detail: String)
    case unsupported
}

extension PoTokenError: CustomStringConvertible {
    var description: String {
        switch self {
        case .notReady: return "not_ready"
        case .javascript: return "javascript_invalid_result"
        case .integrity: return "integrity_invalid_response"
        case .assets: return "assets_missing"
        case .navigation: return "webview_not_loaded"
        case .http: return "botguard_http_failure"
        case .challengeResponse: return "challenge_invalid_response"
        case .challengeShape: return "challenge_invalid_shape"
        case .challengeFields(let safe, let trusted): return "challenge_fields_safe_\(safe)_trusted_\(trusted)"
        case .javascriptDetail(let stage, let detail): return "javascript_\(stage)_\(detail)"
        case .unsupported: return "unsupported_os"
        }
    }
}
