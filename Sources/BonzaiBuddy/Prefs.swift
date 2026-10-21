import Foundation
import Security
import SwiftUI

enum Prefs {
    static let provider = "provider"
    static let customBaseURL = "customBaseURL"
    static let voiceEnabled = "voiceEnabled"
    static let voiceName = "voiceName"
    static let voicePitch = "voicePitch"
    static let voiceRate = "voiceRate"
    static let wander = "wander"
    static let chatter = "chatter"
    static let chatterMinutes = "chatterMinutes"

    static func modelKey(for provider: Provider) -> String { "model.\(provider.rawValue)" }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            provider: Provider.anthropic.rawValue,
            voiceEnabled: true,
            voiceName: "Fred",
            voicePitch: 1.2,
            voiceRate: 0.5,
            wander: true,
            chatter: true,
            chatterMinutes: 15,
        ])
    }
}

/// One Keychain item per provider.
enum KeychainStore {
    private static let service = "com.bonzaibuddy.mac"

    private static func baseQuery(_ provider: Provider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(provider.rawValue)-api-key",
        ]
    }

    static func load(for provider: Provider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, for provider: Provider) {
        SecItemDelete(baseQuery(provider) as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var query = baseQuery(provider)
        query[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(query as CFDictionary, nil)
    }
}

struct SettingsView: View {
    let testVoice: () -> Void

    @AppStorage(Prefs.provider) private var providerRaw = Provider.anthropic.rawValue
    @AppStorage(Prefs.customBaseURL) private var customBaseURL = ""
    @AppStorage(Prefs.voiceEnabled) private var voiceEnabled = true
    @AppStorage(Prefs.voiceName) private var voiceName = "Fred"
    @AppStorage(Prefs.voicePitch) private var voicePitch = 1.2
    @AppStorage(Prefs.voiceRate) private var voiceRate = 0.5
    @AppStorage(Prefs.wander) private var wander = true
    @AppStorage(Prefs.chatter) private var chatter = true
    @AppStorage(Prefs.chatterMinutes) private var chatterMinutes = 15

    @State private var apiKey = ""
    @State private var model = ""
    @State private var savedKey = false

    private var provider: Provider { Provider(rawValue: providerRaw) ?? .anthropic }

    var body: some View {
        Form {
            Section("AI Brain") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(Provider.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                if provider == .custom {
                    TextField("Endpoint URL", text: $customBaseURL, prompt: Text("https://…/v1/chat/completions"))
                }
                if provider != .ollama {
                    SecureField(provider.requiresKey ? "API key" : "API key (optional)", text: $apiKey)
                        .onChange(of: apiKey) { savedKey = false }
                    HStack {
                        Button("Save Key") {
                            KeychainStore.save(apiKey, for: provider)
                            savedKey = true
                        }
                        if savedKey { Text("Saved to Keychain").foregroundStyle(.secondary) }
                    }
                }
                TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                    .onChange(of: model) {
                        UserDefaults.standard.set(model, forKey: Prefs.modelKey(for: provider))
                    }
                Text(provider.keyHint)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice") {
                Toggle("Speak out loud", isOn: $voiceEnabled)
                Picker("Voice", selection: $voiceName) {
                    ForEach(Speaker.englishVoiceNames, id: \.self) { Text($0).tag($0) }
                }
                Slider(value: $voicePitch, in: 0.5...2.0) { Text("Pitch") }
                Slider(value: $voiceRate, in: 0.3...0.65) { Text("Speed") }
                Button("Test Voice", action: testVoice)
            }
            Section("Behavior") {
                Toggle("Wander, sit, and climb on windows", isOn: $wander)
                Toggle("Pipe up on my own", isOn: $chatter)
                Stepper("When idle for \(chatterMinutes) minutes", value: $chatterMinutes, in: 2...120)
                    .disabled(!chatter)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: loadProviderFields)
        .onChange(of: providerRaw) { loadProviderFields() }
    }

    private func loadProviderFields() {
        apiKey = KeychainStore.load(for: provider) ?? ""
        model = UserDefaults.standard.string(forKey: Prefs.modelKey(for: provider)) ?? ""
        savedKey = false
    }
}
