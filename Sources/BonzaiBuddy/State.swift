import AppKit
import SwiftUI

enum BuddyLayout {
    static let windowSize = CGSize(width: 360, height: 440)
    static let gorillaSize = CGSize(width: 150, height: 170)
    /// Distance from the bottom of the window to Bonzai's feet.
    static let footInset: CGFloat = 2
}

/// UI state the SwiftUI views observe.
@MainActor
final class BuddyState: ObservableObject {
    @Published var bubbleText: String?
    @Published var thinking = false
    @Published var showInput = false
    @Published var inputText = ""
    /// Interactive regions in window coordinates (top-left origin); everything else is click-through.
    var hitRects: [String: CGRect] = [:]
}

enum Pose {
    case idle, walking, scurrying, sitting, falling, flailing, dangling, balancing, thinking

    var canWave: Bool { self == .idle || self == .sitting || self == .walking }
}

/// Animation parameters written by the physics engine at 60 Hz and read by the painter every frame.
/// Deliberately not observable so per-frame updates don't churn SwiftUI.
final class Rig {
    var pose: Pose = .falling
    var facingRight = false
    /// Where the cursor is relative to Bonzai's head, each axis in -1...1 (y up).
    var look = CGPoint.zero
    var tilt: CGFloat = 0
    var talking = false
    var grounded = false
    /// In `Date.timeIntervalSinceReferenceDate` seconds.
    var wavingUntil: Double = 0
    let blinkSeed = Double.random(in: 0..<4)
}

struct BuddyActions {
    let tapped: () -> Void
    let submit: () -> Void
    let cancelInput: () -> Void
    let dismissBubble: () -> Void
    let dragChanged: () -> Void
    let dragEnded: () -> Void
    let joke: () -> Void
    let fact: () -> Void
    let hush: () -> Void
    let settings: () -> Void
    let quit: () -> Void
}

final class BuddyPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // Follow the user across Spaces, including full-screen apps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.orderFrontRegardless()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
