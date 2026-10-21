import AppKit
import QuartzCore

/// Moves Bonzai around the desktop: gravity, standing on window title bars, riding along when a
/// window moves, getting flung or shoved by windows, wandering, and skedaddling from the cursor.
///
/// `pos` is the point between Bonzai's feet, in Cocoa global coordinates (bottom-left origin).
@MainActor
final class PhysicsEngine {
    private enum Support: Equatable { case none, floor, window(CGWindowID) }
    private enum Behavior { case idle, walk, scurry, sit }

    private let gravity: CGFloat = 2400
    private let bodyHalfWidth: CGFloat = 30
    private let bodyHeight: CGFloat = 120
    private let walkSpeed: CGFloat = 75
    private let scurrySpeed: CGFloat = 420
    /// A window moving faster than this (points/sec) launches Bonzai off it.
    private let flingSpeed: CGFloat = 1700

    private let panel: NSPanel
    private let rig: Rig
    private let state: BuddyState
    private let brain: Brain
    private var tracker = WindowTracker()

    private var pos: CGPoint
    private var vel = CGVector.zero
    private var support: Support = .none
    private var supportRect: CGRect = .zero
    private var windows: [TrackedWindow] = []
    private var prevRects: [CGWindowID: CGRect] = [:]

    private var behavior: Behavior = .idle
    private var behaviorUntil: CFTimeInterval = 0
    private var walkDir: CGFloat = -1
    private var dragging = false
    private var grabOffset = CGVector.zero
    private var lastMouse = NSEvent.mouseLocation
    private var mouseVel = CGVector.zero
    private var scurryCooldown: CFTimeInterval = 0

    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var lastPoll: CFTimeInterval = CACurrentMediaTime()
    private var lastCarry: CFTimeInterval = 0
    private var tickCount = 0
    private var timer: Timer?

    init(panel: NSPanel, rig: Rig, state: BuddyState, brain: Brain) {
        self.panel = panel
        self.rig = rig
        self.state = state
        self.brain = brain
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        pos = CGPoint(x: screen.maxX - 260, y: screen.maxY - 60)
    }

    func start() {
        tracker.excludedWindowNumber = panel.windowNumber
        windows = tracker.snapshot()
        prevRects = Dictionary(windows.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: External controls

    func dragChanged() {
        guard !dragging else { return }
        dragging = true
        let mouse = NSEvent.mouseLocation
        grabOffset = CGVector(dx: pos.x - mouse.x, dy: pos.y - mouse.y)
        support = .none
        behavior = .idle
        vel = .zero
        brain.quip(.grabbed)
    }

    func dragEnded() {
        guard dragging else { return }
        dragging = false
        let speed = hypot(vel.dx, vel.dy)
        if speed > 3500 { vel = CGVector(dx: vel.dx / speed * 3500, dy: vel.dy / speed * 3500) }
        if speed > 1400 { brain.quip(.thrown) }
        behaviorUntil = CACurrentMediaTime() + 1
    }

    /// Drop Bonzai in from the top of the screen under the cursor.
    func summon() {
        let mouse = NSEvent.mouseLocation
        pos = CGPoint(x: mouse.x, y: screenTop(at: mouse.x, y: mouse.y) - 40)
        vel = .zero
        support = .none
        dragging = false
    }

    func summonIfOffscreen() {
        if !NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: pos.x, y: pos.y + 60)) }) {
            summon()
        }
    }

    // MARK: Loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - lastTick, 1.0 / 240.0), 1.0 / 20.0))
        lastTick = now
        tickCount += 1

        trackMouse(dt: dt, now: now)
        if tickCount % 2 == 0 { pollWindows(now: now) }

        if dragging {
            followDrag(dt: dt)
        } else if support == .none {
            airStep(dt: dt, now: now)
        } else {
            groundStep(dt: dt, now: now)
        }
        keepOnScreen()

        let origin = CGPoint(x: (pos.x - panel.frame.width / 2).rounded(), y: (pos.y - BuddyLayout.footInset).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        updateRig(now: now)
        updateClickThrough()
    }

    // MARK: Windows

    private func pollWindows(now: CFTimeInterval) {
        let pollDt = CGFloat(max(now - lastPoll, 1.0 / 120.0))
        lastPoll = now
        windows = tracker.snapshot()
        let current = Dictionary(windows.map { ($0.id, $0.rect) }, uniquingKeysWith: { a, _ in a })
        defer { prevRects = current }
        guard !dragging else { return }

        if case .window(let id) = support {
            if let rect = current[id] {
                let dx = rect.minX - supportRect.minX
                let dy = rect.maxY - supportRect.maxY
                supportRect = rect
                if dx != 0 || dy != 0 {
                    // Ride along with the window.
                    pos.x += dx
                    pos.y = rect.maxY
                    lastCarry = now
                    let windowVel = CGVector(dx: dx / pollDt, dy: dy / pollDt)
                    if hypot(windowVel.dx, windowVel.dy) > flingSpeed {
                        launch(with: windowVel)
                        brain.quip(.flung)
                    }
                }
                if support != .none && !isTopVisible(id, at: pos.x) { reactToBeingCovered() }
            } else {
                // Window closed or minimized out from under him.
                support = .none
                vel = .zero
                brain.quip(.dropped)
            }
        }
        shoveIfHit(current: current, pollDt: pollDt)
    }

    private func launch(with windowVel: CGVector) {
        support = .none
        behavior = .idle
        // Thrown up and along with the window; if it yanked downward, it just drops out from under him.
        vel = CGVector(dx: windowVel.dx * 0.8, dy: windowVel.dy > 0 ? windowVel.dy * 0.8 + 450 : 300)
    }

    /// Another window was brought in front of the one he's standing on. Hop up onto it if it's
    /// close above, otherwise fall.
    private func reactToBeingCovered() {
        let probe = CGPoint(x: pos.x, y: pos.y - 3)
        if let cover = windows.first(where: { $0.rect.contains(probe) }) {
            let climb = cover.rect.maxY - pos.y
            if climb > 0 && climb < 400 {
                vel = CGVector(dx: 0, dy: sqrt(2 * gravity * (climb + 40)))
            }
        }
        support = .none
    }

    /// A window edge moved into Bonzai since the last poll: push him out of its way.
    private func shoveIfHit(current: [CGWindowID: CGRect], pollDt: CGFloat) {
        let body = bodyRect()
        for window in windows {
            if case .window(let id) = support, id == window.id { continue }
            guard let old = prevRects[window.id], old != window.rect,
                  !old.intersects(body), window.rect.intersects(body) else { continue }

            let dx = window.rect.minX - old.minX
            let dy = window.rect.minY - old.minY
            if abs(dx) >= abs(dy) {
                pos.x = dx > 0 ? window.rect.maxX + bodyHalfWidth + 1 : window.rect.minX - bodyHalfWidth - 1
                vel = CGVector(dx: dx / pollDt, dy: max(vel.dy, 260))
            } else if dy > 0 {
                // Window rose up from beneath him: scoop him up.
                pos.y = window.rect.maxY
                support = .window(window.id)
                supportRect = window.rect
                vel = .zero
                return
            } else {
                // Window came down on top of him: squeeze out the nearer side.
                pos.x = pos.x < window.rect.midX ? window.rect.minX - bodyHalfWidth - 1 : window.rect.maxX + bodyHalfWidth + 1
                vel = CGVector(dx: 0, dy: 0)
            }
            support = .none
            behavior = .idle
            brain.quip(.shoved)
            return
        }
    }

    /// Whether the title bar of `id` at `x` is the frontmost thing there (not covered by another window).
    private func isTopVisible(_ id: CGWindowID, at x: CGFloat) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return false }
        let probe = CGPoint(x: x, y: windows[index].rect.maxY - 3)
        return !windows[..<index].contains { $0.rect.contains(probe) }
    }

    private func bodyRect() -> CGRect {
        CGRect(x: pos.x - bodyHalfWidth, y: pos.y + 4, width: bodyHalfWidth * 2, height: bodyHeight)
    }

    // MARK: Airborne

    private func airStep(dt: CGFloat, now: CFTimeInterval) {
        let prevY = pos.y
        vel.dy -= gravity * dt
        pos.x += vel.dx * dt
        pos.y += vel.dy * dt
        guard vel.dy <= 0 else { return }

        // Land on the highest surface crossed this step.
        var best: (support: Support, top: CGFloat, rect: CGRect)?
        for window in windows {
            let top = window.rect.maxY
            guard prevY >= top - 1, pos.y <= top,
                  pos.x > window.rect.minX + 8, pos.x < window.rect.maxX - 8,
                  top > (best?.top ?? -.infinity),
                  isTopVisible(window.id, at: pos.x) else { continue }
            best = (.window(window.id), top, window.rect)
        }
        let floor = floorY(at: pos.x)
        if best == nil && pos.y <= floor { best = (.floor, floor, .zero) }
        if let best { land(on: best.support, top: best.top, rect: best.rect, now: now) }
    }

    private func land(on target: Support, top: CGFloat, rect: CGRect, now: CFTimeInterval) {
        pos.y = top
        let impact = -vel.dy
        if impact > 1300 {
            vel = CGVector(dx: vel.dx * 0.6, dy: impact * 0.3)
            brain.quip(.thud)
            return
        }
        let wasFlying = abs(vel.dx) > 700
        vel.dy = 0
        support = target
        supportRect = rect
        if wasFlying && Bool.random() {
            // Dust himself off and skedaddle.
            behavior = .scurry
            walkDir = vel.dx > 0 ? 1 : -1
            behaviorUntil = now + 0.8
            vel.dx = 0
        } else {
            behavior = .idle
            behaviorUntil = now + .random(in: 0.6...1.6)
        }
    }

    // MARK: Grounded

    private func groundStep(dt: CGFloat, now: CFTimeInterval) {
        if brain.isBusy && (behavior == .walk || behavior == .sit) { behavior = .idle }

        switch behavior {
        case .walk:
            vel.dx = 0
            pos.x += walkDir * walkSpeed * dt
        case .scurry:
            vel.dx = 0
            pos.x += walkDir * scurrySpeed * dt
        case .idle, .sit:
            vel.dx *= pow(0.004, dt)  // slide to a stop after a hard landing
            pos.x += vel.dx * dt
        }

        switch support {
        case .floor:
            pos.y = floorY(at: pos.x)
        case .window:
            pos.y = supportRect.maxY
            let lo = supportRect.minX + 8
            let hi = supportRect.maxX - 8
            if pos.x < lo || pos.x > hi {
                if behavior == .walk && Double.random(in: 0..<1) < 0.6 {
                    walkDir = pos.x < lo ? 1 : -1
                    pos.x = min(max(pos.x, lo), hi)
                } else {
                    // Walk, run, or slide right off the edge.
                    let speed: CGFloat = behavior == .scurry ? scurrySpeed * 0.7 : (behavior == .walk ? walkSpeed : vel.dx)
                    vel = CGVector(dx: behavior == .idle || behavior == .sit ? speed : walkDir * speed, dy: 0)
                    support = .none
                    behavior = .idle
                }
            }
        case .none:
            break
        }

        if now >= behaviorUntil { pickBehavior(now: now) }
    }

    private func pickBehavior(now: CFTimeInterval) {
        guard UserDefaults.standard.bool(forKey: Prefs.wander), !brain.isBusy else {
            behavior = .idle
            behaviorUntil = now + 1
            return
        }
        let roll = Double.random(in: 0..<1)
        if roll < 0.36 {
            behavior = .walk
            walkDir = Bool.random() ? 1 : -1
            behaviorUntil = now + .random(in: 1.5...4)
        } else if roll < 0.54 {
            behavior = .sit
            behaviorUntil = now + .random(in: 4...10)
        } else if roll < 0.72, jumpToNearbyWindow() {
            behavior = .idle
            behaviorUntil = now + 2
        } else {
            behavior = .idle
            behaviorUntil = now + .random(in: 2...5)
        }
    }

    /// Ballistic hop onto another window's title bar.
    private func jumpToNearbyWindow() -> Bool {
        var options: [(rect: CGRect, x: CGFloat)] = []
        for window in windows {
            if case .window(let id) = support, id == window.id { continue }
            let rect = window.rect
            let rise = rect.maxY - pos.y
            guard rise > -350, rise < 300, rect.width > 100 else { continue }
            let x = CGFloat.random(in: (rect.minX + 40)...(rect.maxX - 40))
            guard abs(x - pos.x) > 60, abs(x - pos.x) < 600,
                  rect.maxY < screenTop(at: x, y: rect.maxY) - 150,  // leave room for the speech bubble
                  isTopVisible(window.id, at: x) else { continue }
            options.append((rect, x))
        }
        guard let target = options.randomElement() else { return false }

        let rise = target.rect.maxY - pos.y
        let apex = max(rise, 0) + 90
        let vy = sqrt(2 * gravity * apex)
        let flightTime = vy / gravity + sqrt(2 * (apex - rise) / gravity)
        vel = CGVector(dx: (target.x - pos.x) / flightTime, dy: vy)
        walkDir = vel.dx > 0 ? 1 : -1
        support = .none
        return true
    }

    // MARK: Mouse

    private func trackMouse(dt: CGFloat, now: CFTimeInterval) {
        let mouse = NSEvent.mouseLocation
        let instant = CGVector(dx: (mouse.x - lastMouse.x) / dt, dy: (mouse.y - lastMouse.y) / dt)
        mouseVel = CGVector(dx: mouseVel.dx * 0.7 + instant.dx * 0.3, dy: mouseVel.dy * 0.7 + instant.dy * 0.3)
        lastMouse = mouse

        let head = CGPoint(x: pos.x, y: pos.y + 120)
        rig.look = CGPoint(x: min(max((mouse.x - head.x) / 250, -1), 1),
                           y: min(max((mouse.y - head.y) / 250, -1), 1))

        // Skedaddle when the cursor comes zooming at him.
        guard !dragging, support != .none, !state.showInput, now > scurryCooldown else { return }
        let distance = hypot(mouse.x - pos.x, mouse.y - (pos.y + 70))
        if distance < 130 && hypot(mouseVel.dx, mouseVel.dy) > 1200 {
            behavior = .scurry
            walkDir = mouse.x > pos.x ? -1 : 1
            behaviorUntil = now + 1.1
            scurryCooldown = now + 3
            brain.quip(.skedaddle)
        }
    }

    private func followDrag(dt: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let target = CGPoint(x: mouse.x + grabOffset.dx, y: mouse.y + grabOffset.dy)
        let instant = CGVector(dx: (target.x - pos.x) / dt, dy: (target.y - pos.y) / dt)
        vel = CGVector(dx: vel.dx * 0.6 + instant.dx * 0.4, dy: vel.dy * 0.6 + instant.dy * 0.4)
        pos = target
    }

    // MARK: Screen bounds

    /// Screens spanning `x`, so with stacked displays Bonzai can fall from one onto the one below.
    private func screens(at x: CGFloat) -> [NSScreen] {
        let matching = NSScreen.screens.filter { x >= $0.frame.minX && x < $0.frame.maxX }
        return matching.isEmpty ? Array(NSScreen.main.map { [$0] } ?? []) : matching
    }

    /// The highest floor at or below Bonzai's current height.
    private func floorY(at x: CGFloat) -> CGFloat {
        let floors = screens(at: x).map(\.visibleFrame.minY)
        return floors.filter { $0 <= pos.y + 1 }.max() ?? floors.min() ?? 0
    }

    /// Top of the screen Bonzai is on (or the lowest one spanning `x` if he's between screens).
    private func screenTop(at x: CGFloat, y: CGFloat? = nil) -> CGFloat {
        let candidates = screens(at: x)
        let height = y ?? pos.y + 60
        let screen = candidates.first { $0.frame.minY <= height && height < $0.frame.maxY }
            ?? candidates.min { $0.frame.minY < $1.frame.minY }
        return screen?.visibleFrame.maxY ?? 900
    }

    private func keepOnScreen() {
        let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !bounds.isNull, !dragging else { return }
        let minX = bounds.minX + 40
        let maxX = bounds.maxX - 40
        if pos.x < minX || pos.x > maxX {
            pos.x = min(max(pos.x, minX), maxX)
            if support == .none {
                vel.dx = -vel.dx * 0.5  // bounce off the screen edge
            } else {
                walkDir = pos.x <= minX ? 1 : -1
                vel.dx = 0
            }
        }
        if pos.y > bounds.maxY + 150 {
            pos.y = bounds.maxY + 150
            vel.dy = min(vel.dy, 0)
        }
        let floor = floorY(at: pos.x)
        if pos.y < floor {
            pos.y = floor
            if support == .none { land(on: .floor, top: floor, rect: .zero, now: CACurrentMediaTime()) }
        }
    }

    // MARK: Presentation

    private func updateRig(now: CFTimeInterval) {
        rig.talking = brain.isTalking
        rig.grounded = support != .none && !dragging

        let speed = hypot(vel.dx, vel.dy)
        if dragging {
            rig.pose = .dangling
        } else if support == .none {
            rig.pose = speed > 1000 ? .flailing : .falling
        } else {
            switch behavior {
            case .walk: rig.pose = .walking
            case .scurry: rig.pose = .scurrying
            case .sit: rig.pose = .sitting
            case .idle:
                if now - lastCarry < 0.3 { rig.pose = .balancing }
                else if state.thinking { rig.pose = .thinking }
                else { rig.pose = .idle }
            }
        }

        if support != .none && (behavior == .walk || behavior == .scurry) {
            rig.facingRight = walkDir > 0
        } else if support == .none && abs(vel.dx) > 60 {
            rig.facingRight = vel.dx > 0
        }
        rig.tilt = support == .none && !dragging ? min(max(vel.dx / 4000, -0.35), 0.35) : 0
    }

    /// Clicks only land on Bonzai and his bubble; the rest of the panel passes through to whatever's below.
    private func updateClickThrough() {
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let interactive = dragging || state.hitRects.values.contains { $0.insetBy(dx: -2, dy: -2).contains(flipped) }
        if panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
    }
}
