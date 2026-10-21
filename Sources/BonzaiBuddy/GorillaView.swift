import SwiftUI

/// Bonzai himself, drawn procedurally every frame from the current `Rig` pose.
struct GorillaView: View {
    let rig: Rig

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                GorillaPainter.draw(&ctx, size: size, t: timeline.date.timeIntervalSinceReferenceDate, rig: rig)
            }
        }
    }
}

private struct PoseParams {
    var legL: CGFloat = 0, legR: CGFloat = 0
    /// Limb angles in radians; 0 hangs straight down, positive swings toward -x.
    var armL: CGFloat = 0.2, armR: CGFloat = -0.2
    var armLength: CGFloat = 42
    /// Upper-body offset: `drop` for sitting, `bob` for breathing/stepping.
    var drop: CGFloat = 0, bob: CGFloat = 0
    var tilt: CGFloat = 0
    var eyesWide = false, mouthO = false, handToChin = false
    var look: CGPoint?

    static func make(_ pose: Pose, t: Double) -> PoseParams {
        func wave(_ freq: Double, _ phase: Double = 0) -> CGFloat { CGFloat(sin(t * freq + phase)) }
        var p = PoseParams()
        switch pose {
        case .idle:
            p.bob = wave(2) * 1.2
            p.armL = 0.2 + wave(2) * 0.03
            p.armR = -p.armL
        case .walking:
            let w = wave(10)
            p.legL = w * 0.45; p.legR = -w * 0.45
            p.armL = 0.25 + w * 0.25; p.armR = -0.25 + w * 0.25
            p.bob = -abs(w) * 3
        case .scurrying:
            let w = wave(24)
            p.legL = w * 0.75; p.legR = -w * 0.75
            p.armL = 1.1 + w * 0.3; p.armR = -1.1 + w * 0.3
            p.bob = -abs(w) * 4
            p.tilt = 0.16
            p.eyesWide = true; p.mouthO = true
        case .sitting:
            p.drop = 22
            p.legL = 1.25; p.legR = -1.25
            p.armL = 0.55; p.armR = -0.55
            p.bob = wave(1.6)
        case .falling:
            p.armL = 2.7; p.armR = -2.7
            p.legL = 0.25; p.legR = -0.25
            p.eyesWide = true; p.mouthO = true
        case .flailing:
            p.armL = 2.3 + wave(18) * 0.6; p.armR = -2.3 + wave(18, 1.3) * 0.6
            p.legL = 0.3 + wave(16) * 0.5; p.legR = -0.3 + wave(16, 2) * 0.5
            p.eyesWide = true; p.mouthO = true
        case .dangling:
            p.armL = 2.9; p.armR = -2.9
            p.legL = wave(3) * 0.25; p.legR = p.legL
            p.eyesWide = true; p.mouthO = true
        case .balancing:
            let w = wave(7)
            p.armL = 1.5 + w * 0.3; p.armR = -1.5 + w * 0.3
            p.tilt = wave(5, 0.5) * 0.08
            p.eyesWide = true
        case .thinking:
            p.armR = 1.9; p.armLength = 36; p.handToChin = true
            p.look = CGPoint(x: 0.6, y: 1)
            p.bob = wave(2)
        }
        return p
    }
}

private enum GorillaPainter {
    static let fur = Color(red: 0.50, green: 0.27, blue: 0.70)
    static let furDark = Color(red: 0.33, green: 0.15, blue: 0.49)
    static let belly = Color(red: 0.71, green: 0.54, blue: 0.85)
    static let skin = Color(red: 0.94, green: 0.83, blue: 0.95)
    static let mouthColor = Color(red: 0.38, green: 0.05, blue: 0.12)
    static let tongue = Color(red: 0.95, green: 0.45, blue: 0.55)

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, rig: Rig) {
        var p = PoseParams.make(rig.pose, t: t)
        if t < rig.wavingUntil && rig.pose.canWave {
            p.armR = -2.5 + CGFloat(sin(t * 12)) * 0.4
        }
        let talk: CGFloat = rig.talking && !p.handToChin ? 0.25 + 0.75 * CGFloat(abs(sin(t * 13))) : 0

        if rig.grounded {
            ctx.fill(ellipse(P(75, 167), p.drop > 0 ? 96 : 66, 7), with: .color(.black.opacity(0.18)))
        }

        // Mirror for facing direction, then lean around the hips.
        if !rig.facingRight {
            ctx.translateBy(x: size.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.translateBy(x: 75, y: 125)
        ctx.rotate(by: .radians(Double(rig.tilt + p.tilt)))
        ctx.translateBy(x: -75, y: -125)

        let d = p.drop + p.bob

        // Legs and feet.
        for (hip, angle) in [(P(62, 136 + p.drop), p.legL), (P(88, 136 + p.drop), p.legR)] {
            ctx.fill(limb(hip, length: 26, width: 20, angle: angle), with: .color(fur))
            let foot = end(hip, 26, angle)
            ctx.fill(ellipse(foot, 24, 12), with: .color(furDark))
        }

        // Torso.
        ctx.fill(ellipse(P(75, 108 + d), 92, 78), with: .color(fur))
        ctx.fill(ellipse(P(75, 115 + d), 56, 50), with: .color(belly))

        // Arms (the thinking arm is drawn after the face so the hand sits on the chin).
        let leftShoulder = P(40, 92 + d)
        let rightShoulder = P(110, 92 + d)
        drawArm(&ctx, from: leftShoulder, length: 42, angle: p.armL)
        if !p.handToChin { drawArm(&ctx, from: rightShoulder, length: p.armLength, angle: p.armR) }

        // Head.
        let hy = 52 + d
        for x in [CGFloat(38), 112] {
            ctx.fill(ellipse(P(x, hy + 2), 22, 22), with: .color(fur))
            ctx.fill(ellipse(P(x, hy + 2), 11, 11), with: .color(skin))
        }
        ctx.fill(ellipse(P(75, hy), 76, 74), with: .color(fur))
        ctx.fill(ellipse(P(71, hy - 36), 13, 10), with: .color(fur))
        ctx.fill(ellipse(P(80, hy - 38), 9, 8), with: .color(fur))

        // Face mask.
        ctx.fill(ellipse(P(75, hy + 12), 56, 44), with: .color(skin))
        ctx.fill(ellipse(P(63, hy - 2), 26, 24), with: .color(skin))
        ctx.fill(ellipse(P(87, hy - 2), 26, 24), with: .color(skin))

        // Brow.
        let browY = hy - 19 - (p.eyesWide ? 3 : 0)
        ctx.fill(Path(roundedRect: CGRect(x: 51, y: browY, width: 48, height: 9), cornerRadius: 4.5), with: .color(furDark))

        // Eyes.
        let lookSource = p.look ?? CGPoint(x: rig.facingRight ? rig.look.x : -rig.look.x, y: rig.look.y)
        let blinking = (t + rig.blinkSeed).truncatingRemainder(dividingBy: 4.2) < 0.12 && !p.eyesWide
        for cx in [CGFloat(64), 86] {
            let center = P(cx, hy - 2)
            if blinking {
                var lid = Path()
                lid.move(to: P(cx - 6, hy - 2))
                lid.addLine(to: P(cx + 6, hy - 2))
                ctx.stroke(lid, with: .color(furDark), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                let eye = ellipse(center, 13, p.eyesWide ? 17 : 15)
                ctx.fill(eye, with: .color(.white))
                ctx.stroke(eye, with: .color(furDark), lineWidth: 1)
                let pupil = P(cx + lookSource.x * 3, hy - 2 - lookSource.y * 3)
                ctx.fill(ellipse(pupil, p.eyesWide ? 6 : 7.2, p.eyesWide ? 6 : 7.2), with: .color(.black))
                ctx.fill(ellipse(P(pupil.x + 1.2, pupil.y - 1.2), 2, 2), with: .color(.white))
            }
        }

        // Nose.
        ctx.fill(ellipse(P(75, hy + 13), 20, 11), with: .color(furDark))
        ctx.fill(ellipse(P(71, hy + 14), 4, 3), with: .color(.black))
        ctx.fill(ellipse(P(79, hy + 14), 4, 3), with: .color(.black))

        // Mouth.
        let my = hy + 25
        if talk > 0 {
            let height = 3 + 11 * talk
            ctx.fill(ellipse(P(75, my + 1), 16 + 3 * talk, height), with: .color(mouthColor))
            if talk > 0.5 { ctx.fill(ellipse(P(75, my + height / 2 - 2), 9, 5), with: .color(tongue)) }
        } else if p.mouthO {
            ctx.fill(ellipse(P(75, my + 1), 9, 11), with: .color(mouthColor))
        } else {
            var smile = Path()
            smile.move(to: P(64, my - 2))
            smile.addQuadCurve(to: P(86, my - 2), control: P(75, my + 7))
            ctx.stroke(smile, with: .color(furDark), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }

        if p.handToChin { drawArm(&ctx, from: rightShoulder, length: p.armLength, angle: p.armR) }
    }

    private static func drawArm(_ ctx: inout GraphicsContext, from shoulder: CGPoint, length: CGFloat, angle: CGFloat) {
        ctx.fill(limb(shoulder, length: length, width: 18, angle: angle), with: .color(fur))
        let hand = end(shoulder, length, angle)
        ctx.fill(ellipse(hand, 17, 17), with: .color(furDark))
        ctx.fill(ellipse(hand, 10, 10), with: .color(skin))
    }

    private static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static func ellipse(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
    }

    /// A rounded limb hanging from `pivot`, rotated by `angle`.
    private static func limb(_ pivot: CGPoint, length: CGFloat, width: CGFloat, angle: CGFloat) -> Path {
        let rect = CGRect(x: -width / 2, y: -width / 2, width: width, height: length + width / 2)
        return Path(roundedRect: rect, cornerRadius: width / 2)
            .applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y)))
    }

    private static func end(_ pivot: CGPoint, _ length: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: pivot.x - sin(angle) * length, y: pivot.y + cos(angle) * length)
    }
}
