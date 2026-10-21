import AVFoundation

/// Text-to-speech. Defaults to macOS's "Fred" voice for that classic robotic desktop-pal sound.
final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private static let allVoices = AVSpeechSynthesisVoice.speechVoices()

    var isSpeaking: Bool { synth.isSpeaking }
    var enabled: Bool { UserDefaults.standard.bool(forKey: Prefs.voiceEnabled) }

    func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !clean.isEmpty else { return }
        let defaults = UserDefaults.standard
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = Self.voice(named: defaults.string(forKey: Prefs.voiceName) ?? "Fred")
        utterance.pitchMultiplier = Float(defaults.double(forKey: Prefs.voicePitch))
        utterance.rate = Float(defaults.double(forKey: Prefs.voiceRate))
        synth.speak(utterance)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    static func voice(named name: String) -> AVSpeechSynthesisVoice? {
        allVoices.first { $0.name == name } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    static var englishVoiceNames: [String] {
        Array(Set(allVoices.filter { $0.language.hasPrefix("en") }.map(\.name))).sorted()
    }
}
