import Foundation

/// Minimal streaming client for the Claude Messages API. Swift has no official
/// Anthropic SDK, so this talks to the REST endpoint directly.
struct ClaudeClient: ChatClient {
    let apiKey: String
    let model: String

    func stream(system: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatEvent, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(system: system, messages: messages)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await ChatHTTP.open(request)
                    var stopReason: String?
                    for try await line in bytes.lines {
                        guard let payload = ChatHTTP.dataPayload(line),
                              let data = payload.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }

                        switch type {
                        case "content_block_start":
                            let block = event["content_block"] as? [String: Any]
                            if block?["type"] as? String == "fallback" { continuation.yield(.reset) }
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(.text(text))
                            }
                        case "message_delta":
                            if let delta = event["delta"] as? [String: Any],
                               let reason = delta["stop_reason"] as? String {
                                stopReason = reason
                            }
                        case "error":
                            let error = event["error"] as? [String: Any]
                            throw ChatAPIError(status: 0, message: error?["message"] as? String ?? "Stream error")
                        default:
                            break
                        }
                    }
                    continuation.yield(.stop(reason: stopReason))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(system: String, messages: [[String: String]]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            "system": system,
            "messages": messages,
            // Chat banter doesn't need deep reasoning; low effort keeps replies snappy.
            "output_config": ["effort": "low"],
        ]
        // Server-side refusal fallback: a declined request is re-run on another model in the same call.
        if Self.supportsDefaultFallback(model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func supportsDefaultFallback(_ model: String) -> Bool {
        ["claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains { model.hasPrefix($0) }
    }
}
