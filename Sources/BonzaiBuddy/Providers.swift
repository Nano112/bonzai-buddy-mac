import Foundation

/// The AI services Bonzai can talk through. Everything except Claude speaks the
/// OpenAI-compatible Chat Completions protocol.
enum Provider: String, CaseIterable, Identifiable {
    case anthropic, openai, gemini, openrouter, ollama, custom

    var id: String { rawValue }

    static var current: Provider {
        Provider(rawValue: UserDefaults.standard.string(forKey: Prefs.provider) ?? "") ?? .anthropic
    }

    var displayName: String {
        switch self {
        case .anthropic: "Claude (Anthropic)"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama (local)"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "chat-latest"
        case .gemini: "gemini-flash-latest"
        case .openrouter: "openrouter/auto"
        case .ollama: "llama3.2"
        case .custom: ""
        }
    }

    /// Chat Completions endpoint for OpenAI-compatible providers.
    var chatCompletionsURL: String? {
        switch self {
        case .anthropic: return nil
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .ollama: return "http://localhost:11434/v1/chat/completions"
        case .custom: return UserDefaults.standard.string(forKey: Prefs.customBaseURL)
        }
    }

    var requiresKey: Bool { self != .ollama && self != .custom }

    var keyHint: String {
        switch self {
        case .anthropic: "Get a key at console.anthropic.com."
        case .openai: "Get a key at platform.openai.com."
        case .gemini: "Get a key at aistudio.google.com."
        case .openrouter: "Get a key at openrouter.ai/keys."
        case .ollama: "No key needed. Install Ollama and run `ollama pull \(defaultModel)`."
        case .custom: "Full chat-completions URL, e.g. https://api.groq.com/openai/v1/chat/completions. Key is optional."
        }
    }

    var environmentKey: String? {
        switch self {
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openai: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        case .openrouter: "OPENROUTER_API_KEY"
        case .ollama, .custom: nil
        }
    }

    var model: String {
        let stored = UserDefaults.standard.string(forKey: Prefs.modelKey(for: self))?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? defaultModel : stored
    }

    /// Keychain first, then the provider's environment variable (handy for `swift run`).
    var apiKey: String? {
        if let key = KeychainStore.load(for: self), !key.isEmpty { return key }
        if let name = environmentKey, let key = ProcessInfo.processInfo.environment[name], !key.isEmpty { return key }
        return nil
    }

    var isConfigured: Bool {
        if requiresKey && apiKey == nil { return false }
        if self == .custom && (chatCompletionsURL ?? "").isEmpty { return false }
        return !model.isEmpty
    }

    func makeClient() -> ChatClient? {
        guard isConfigured else { return nil }
        if self == .anthropic, let key = apiKey {
            return ClaudeClient(apiKey: key, model: model)
        }
        guard let urlString = chatCompletionsURL, let url = URL(string: urlString) else { return nil }
        return OpenAICompatibleClient(endpoint: url, apiKey: apiKey, model: model, provider: self)
    }
}

// MARK: Shared streaming types

enum ChatEvent {
    case text(String)
    /// A server-side fallback took over mid-stream; discard partial text.
    case reset
    case stop(reason: String?)
}

struct ChatAPIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

protocol ChatClient {
    func stream(system: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatEvent, Error>
}

enum ChatHTTP {
    /// Sends a streaming request and returns the body, throwing `ChatAPIError` for non-200 responses.
    static func open(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw ChatAPIError(status: status, message: errorMessage(raw) ?? "HTTP \(status)")
        }
        return bytes
    }

    /// Payload of an SSE `data:` line, or nil for other lines.
    static func dataPayload(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    }

    /// Pulls a human-readable message out of the various error body shapes providers use.
    static func errorMessage(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object = (json as? [[String: Any]])?.first ?? json as? [String: Any]
        if let error = object?["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object?["error"] as? String { return message }
        return object?["message"] as? String
    }
}

// MARK: OpenAI-compatible client

/// Streams from any OpenAI-compatible Chat Completions endpoint (OpenAI, Gemini, OpenRouter, Ollama, ...).
struct OpenAICompatibleClient: ChatClient {
    let endpoint: URL
    let apiKey: String?
    let model: String
    let provider: Provider

    func stream(system: String, messages: [[String: String]]) -> AsyncThrowingStream<ChatEvent, Error> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization") }
        if provider == .openrouter {
            request.setValue("https://github.com/Nano112/bonzai-buddy-mac", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Bonzai Buddy", forHTTPHeaderField: "X-Title")
        }
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [["role": "system", "content": system]] + messages,
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await ChatHTTP.open(request)
                    var stopReason: String?
                    for try await line in bytes.lines {
                        guard let payload = ChatHTTP.dataPayload(line) else { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let message = ChatHTTP.errorMessage(payload), chunk["choices"] == nil {
                            throw ChatAPIError(status: 0, message: message)
                        }
                        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { continue }
                        if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                        if let reason = choice["finish_reason"] as? String {
                            stopReason = reason == "content_filter" ? "refusal" : reason
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
}
