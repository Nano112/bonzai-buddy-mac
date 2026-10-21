import AppKit
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = BuddyState()
    private let rig = Rig()
    private let speaker = Speaker()
    private var brain: Brain!
    private var engine: PhysicsEngine!
    private var panel: BuddyPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var chatterTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()

        brain = Brain(state: state, speaker: speaker)
        panel = BuddyPanel(size: BuddyLayout.windowSize)
        engine = PhysicsEngine(panel: panel, rig: rig, state: state, brain: brain)

        let actions = BuddyActions(
            tapped: { [unowned self] in toggleInput() },
            submit: { [unowned self] in submitInput() },
            cancelInput: { [unowned self] in state.showInput = false },
            dismissBubble: { [unowned self] in brain.stop() },
            dragChanged: { [unowned self] in engine.dragChanged() },
            dragEnded: { [unowned self] in engine.dragEnded() },
            joke: { [unowned self] in brain.joke() },
            fact: { [unowned self] in brain.fact() },
            hush: { [unowned self] in brain.stop() },
            settings: { [unowned self] in openSettings() },
            quit: { NSApp.terminate(nil) }
        )
        panel.contentView = NSHostingView(rootView: BuddyView(state: state, rig: rig, actions: actions))
        panel.orderFrontRegardless()
        engine.start()

        setUpStatusItem()
        startChatterTimer()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.greet() }
    }

    private func greet() {
        rig.wavingUntil = Date().timeIntervalSinceReferenceDate + 3
        if !Provider.current.isConfigured {
            brain.say("Hiya! I'm Bonzai, your new desktop buddy! First, right-click me and open Settings to pick my AI brain and add an API key.", force: true)
        } else {
            brain.say("Hiya! I'm Bonzai! Click me to chat, or grab me and toss me around.", force: true)
        }
    }

    // MARK: Input

    private func toggleInput() {
        if state.showInput {
            state.showInput = false
        } else {
            state.showInput = true
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func submitInput() {
        let question = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        state.inputText = ""
        state.showInput = false
        brain.ask(question)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Bonzai Buddy")

        let menu = NSMenu()
        menu.addItem(item("Chat with Bonzai…", #selector(menuChat), "k"))
        menu.addItem(item("Tell Me a Joke", #selector(menuJoke)))
        menu.addItem(item("Fun Fact", #selector(menuFact)))
        menu.addItem(item("Shush", #selector(menuHush)))
        menu.addItem(.separator())
        menu.addItem(item("Summon Bonzai", #selector(menuSummon)))
        menu.addItem(item("Settings…", #selector(menuSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Bonzai Buddy", #selector(menuQuit), "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuChat() {
        engine.summonIfOffscreen()
        state.showInput = true
        panel.makeKeyAndOrderFront(nil)
    }
    @objc private func menuJoke() { brain.joke() }
    @objc private func menuFact() { brain.fact() }
    @objc private func menuHush() { brain.stop() }
    @objc private func menuSummon() { engine.summon() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: Settings

    private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(testVoice: { [weak self] in
                self?.brain.say("Hiya! This is how I sound. Ooh, bananas!", force: true)
            })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Bonzai Buddy Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Idle chatter

    private func startChatterTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maybeChatter() }
        }
        RunLoop.main.add(timer, forMode: .common)
        chatterTimer = timer
    }

    private func maybeChatter() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Prefs.chatter), !brain.isBusy, Provider.current.isConfigured else { return }
        let interval = TimeInterval(max(defaults.integer(forKey: Prefs.chatterMinutes), 1) * 60)
        if Date().timeIntervalSince(brain.lastInteraction) > interval {
            brain.chatter()
        }
    }
}
