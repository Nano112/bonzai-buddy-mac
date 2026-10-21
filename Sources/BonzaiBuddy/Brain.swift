import Foundation
import QuartzCore

/// Conversation with Claude, plus Bonzai's canned reactions to getting knocked around.
@MainActor
final class Brain {
    enum Quip { case flung, dropped, shoved, thud, skedaddle, grabbed, thrown }

    private static let quips: [Quip: [String]] = [
        .flung: ["Whoaaa!", "Wheeeee!", "Not so fast!", "Hold onto your bananas!"],
        .dropped: ["Hey, where'd my window go?", "Uh oh!", "Gravity, my old nemesis!"],
        .shoved: ["Hey, quit shoving!", "Excuse you!", "Rude!", "Watch where you're dragging that thing!"],
        .thud: ["Oof!", "Ouch!", "I'm okay!", "Nailed the landing. Sort of."],
        .skedaddle: ["Yikes!", "Skedaddle!", "Can't catch me!", "Eek!"],
        .grabbed: ["Whoa, put me down!", "Hey, I'm not a toy!", "Up we go!"],
        .thrown: ["Wheeeeee!", "I can fly!", "Aaaaah!"],
    ]

    private let state: BuddyState
    private let speaker: Speaker
    private var history: [[String: String]] = []
    private var task: Task<Void, Never>?
    /// Bumped whenever a reply is superseded, so a stale stream stops touching the UI.
    private var replyGen = 0
    private var hideGen = 0
    private var replyActive = false
    private var lastQuip: CFTimeInterval = 0

    private(set) var isStreaming = false
    private(set) var lastInteraction = Date()

    init(state: BuddyState, speaker: Speaker) {
        self.state = state
        self.speaker = speaker
    }

    /// True while Bonzai is mid-conversation and shouldn't wander off.
    var isBusy: Bool { isStreaming || (replyActive && speaker.isSpeaking) || state.showInput }
    var isTalking: Bool { speaker.isSpeaking || (isStreaming && !state.thinking) }

    // MARK: Conversation

    func ask(_ text: String) {
        lastInteraction = Date()
        history.append(["role": "user", "content": text])
        if history.count > 40 {
            history.removeFirst(history.count - 40)
            while history.first?["role"] != "user" { history.removeFirst() }
        }
        send(history, record: true)
    }

    func joke() { ask("Tell me a joke!") }
    func fact() { ask("Tell me a fun fact!") }

    /// Unprompted remark when the user has been quiet for a while. Not added to history.
    func chatter() {
        guard !isBusy else { return }
        lastInteraction = Date()
        let time = Date().formatted(date: .omitted, time: .shortened)
        let nudge = """
        (Nobody said anything. You're piping up on your own; it's \(time). Say ONE short unprompted thing: \
        a fun fact, a silly joke, a banana thought, or a friendly nudge to stretch or drink water. \
        Don't mention this note.)
        """
        send([["role": "user", "content": nudge]], record: false)
    }

    private func send(_ messages: [[String: String]], record: Bool) {
        let provider = Provider.current
        guard let client = provider.makeClient() else {
            if record { history.removeLast() }
            say("I need my \(provider.displayName) settings before I can chat! Right-click me and choose Settings.", force: true)
            return
        }

        task?.cancel()
        speaker.stop()
        replyGen += 1
        hideGen += 1
        let gen = replyGen
        state.bubbleText = ""
        state.thinking = true
        isStreaming = true
        replyActive = true

        let system = Self.systemPrompt()

        task = Task { [weak self] in
            var full = ""
            var pending = ""
            do {
                for try await event in client.stream(system: system, messages: messages) {
                    guard let self, gen == self.replyGen else { return }
                    switch event {
                    case .text(let text):
                        state.thinking = false
                        full += text
                        pending += text
                        state.bubbleText = full
                        speakCompleteSentences(&pending)
                    case .reset:
                        full = ""
                        pending = ""
                        speaker.stop()
                        state.bubbleText = ""
                    case .stop(let reason):
                        if reason == "refusal" {
                            full = "Hmm, I'd better not answer that one. Ask me something else!"
                            pending = full
                            speaker.stop()
                            state.bubbleText = full
                        }
                    }
                }
                guard let self, gen == self.replyGen else { return }
                speaker.speak(pending)
                if record { history.append(["role": "assistant", "content": full.isEmpty ? "..." : full]) }
            } catch {
                guard let self, gen == self.replyGen, !Task.isCancelled else { return }
                if record, history.last?["role"] == "user" { history.removeLast() }
                let message = Self.friendly(error, provider: provider)
                state.bubbleText = message
                speaker.speak(message)
            }
            guard let self, gen == self.replyGen else { return }
            isStreaming = false
            state.thinking = false
            scheduleHide()
        }
    }

    private func speakCompleteSentences(_ pending: inout String) {
        let boundary = #"[.!?…]+["'”’)\]]*\s+|\n+"#
        while let range = pending.range(of: boundary, options: .regularExpression) {
            speaker.speak(String(pending[..<range.upperBound]))
            pending.removeSubrange(..<range.upperBound)
        }
    }

    // MARK: Speech bubble

    /// Show and speak a local line. Won't talk over a Claude reply unless forced.
    func say(_ line: String, force: Bool = false) {
        if !force && (isStreaming || (replyActive && speaker.isSpeaking)) { return }
        if force {
            task?.cancel()
            replyGen += 1
            isStreaming = false
        }
        replyActive = false
        state.thinking = false
        state.bubbleText = line
        speaker.stop()
        speaker.speak(line)
        scheduleHide(base: 2.5)
    }

    func quip(_ kind: Quip) {
        let now = CACurrentMediaTime()
        guard now - lastQuip > 2.5, !state.showInput, Double.random(in: 0..<1) < 0.75,
              let line = Self.quips[kind]?.randomElement() else { return }
        lastQuip = now
        say(line)
    }

    /// Stop talking and hide the bubble.
    func stop() {
        task?.cancel()
        replyGen += 1
        hideGen += 1
        isStreaming = false
        replyActive = false
        state.thinking = false
        state.bubbleText = nil
        speaker.stop()
    }

    private func scheduleHide(base: Double = 6) {
        hideGen += 1
        let gen = hideGen
        Task { [weak self] in
            while let self, self.isStreaming || self.speaker.isSpeaking {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if gen != self.hideGen { return }
            }
            let linger = base + Double(self?.state.bubbleText?.count ?? 0) / 60
            try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
            guard let self, gen == self.hideGen else { return }
            state.bubbleText = nil
            replyActive = false
        }
    }

    // MARK: Prompt

    private static func systemPrompt() -> String {
        let today = Date().formatted(date: .complete, time: .omitted)
        return """
        You are Bonzai, a cheerful purple gorilla who lives on the user's Mac desktop: a loving homage to the \
        1999 desktop pal BonziBuddy, minus the spyware (feel free to joke about that). You physically hang out \
        on their screen. You sit on top of their windows, get shoved around and flung when they drag those \
        windows, and skedaddle when the mouse cursor zooms at you.

        Personality: goofy, warm, enthusiastic, a little corny. You love bananas, puns, and late-90s internet \
        nostalgia. You're also genuinely smart, so when the user asks a real question, give them the real answer.

        Your replies are read aloud by a text-to-speech voice and shown in a small cartoon speech bubble, so:
        - Keep it short: one to three sentences unless the user asks for more detail.
        - Use plain conversational text only. No markdown, lists, headings, code blocks, URLs, or emoji.
        - Write numbers and symbols the way they should be spoken when it matters.

        Today is \(today).
        """
    }

    private static func friendly(_ error: Error, provider: Provider) -> String {
        if let api = error as? ChatAPIError {
            switch api.status {
            case 401, 403: return "My \(provider.displayName) API key isn't working. Can you check it in Settings?"
            case 404: return "\(provider.displayName) doesn't know the model \"\(provider.model)\". Check it in Settings!"
            case 429: return "Whoa, too many questions at once! Give me a second."
            case 500...: return "\(provider.displayName) is swamped right now. Try me again in a bit!"
            default: return "Uh oh: \(api.message)"
            }
        }
        if error is URLError {
            if provider == .ollama { return "I can't reach Ollama. Is it running on this Mac?" }
            return "I can't reach the internet right now. Is the Wi-Fi on?"
        }
        return "Uh oh, something went wrong: \(error.localizedDescription)"
    }
}
