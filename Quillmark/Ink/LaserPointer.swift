import CoreGraphics
import Foundation

struct LaserSample: Equatable {
    var point: CGPoint
    var time: TimeInterval
}

struct LaserRenderFrame {
    var glowPath: CGPath?
    var corePath: CGPath?
    var glowColor: CGColor?
    var opacity: Float = 1

    var isActive: Bool { glowPath != nil || corePath != nil }
    static let empty = LaserRenderFrame()
}

/// Multi-stroke classroom laser pointer engine:
/// - Supports circling or underlining multiple separate places in sequence even when the pen tip
///   lifts between strokes (accumulates disconnected strokes while the previous laser marks remain
///   visible).
/// - After lifting the pen, keeps all marks at full 100% brightness for `liftHoldDuration` (0.9s),
///   then smoothly fades out over `liftFadeDuration` (0.6s).
/// - Touching & holding the pen tip down anywhere on the screen revives and locks all visible laser
///   marks at 100% brightness indefinitely until the teacher lifts the pen again.
/// - Renders identically on iPad and the 60fps external presentation display.
final class LaserPointerEngine {
    /// Full-brightness dwell window after lifting the pen so the teacher can circle multiple areas.
    static let liftHoldDuration: TimeInterval = 0.9
    /// Smooth fade-out duration following `liftHoldDuration`.
    static let liftFadeDuration: TimeInterval = 0.6
    /// Total time from pen lift until marks fully clear.
    static var totalLiftDuration: TimeInterval { liftHoldDuration + liftFadeDuration }
    static let trailGlowRadius: CGFloat = 4.2
    static let trailCoreRadius: CGFloat = 1.7

    private(set) var color: RGBAColor = ToolSettings.laserPalette[0]
    /// Disconnected laser strokes currently visible on screen.
    private(set) var strokes: [[LaserSample]] = []
    private(set) var isTouching = false
    private var endedAt: TimeInterval?

    /// Flattened samples across all active strokes (kept for compatibility and inspection).
    var samples: [LaserSample] {
        strokes.flatMap { $0 }
    }

    var isActive: Bool {
        isTouching || !strokes.isEmpty
    }

    func begin(at point: CGPoint, color: RGBAColor, now: TimeInterval) {
        let shouldChain: Bool
        if strokes.isEmpty {
            shouldChain = false
        } else if isTouching {
            shouldChain = true
        } else if let endedAt {
            shouldChain = (now - endedAt) < Self.totalLiftDuration
        } else {
            shouldChain = true
        }

        self.color = color
        self.isTouching = true
        self.endedAt = nil

        let newStroke = [LaserSample(point: point, time: now)]
        if shouldChain {
            strokes.append(newStroke)
        } else {
            strokes = [newStroke]
        }
    }

    func move(to point: CGPoint, now: TimeInterval) {
        guard isTouching, !strokes.isEmpty else { return }
        let idx = strokes.count - 1
        if let last = strokes[idx].last, hypot(point.x - last.point.x, point.y - last.point.y) < 1.0 {
            strokes[idx][strokes[idx].count - 1].time = now
        } else {
            strokes[idx].append(LaserSample(point: point, time: now))
        }
    }

    func end(now: TimeInterval) {
        isTouching = false
        endedAt = now
    }

    func cancel() {
        isTouching = false
        endedAt = nil
        strokes.removeAll()
    }

    /// Computes combined glow & core paths for all active laser strokes in view coordinates.
    /// While `isTouching`, every accumulated stroke remains at 100% opacity indefinitely.
    /// After lifting, marks stay at 100% opacity for `liftHoldDuration`, then fade smoothly over
    /// `liftFadeDuration` before clearing.
    func frame(at now: TimeInterval, transform: CGAffineTransform = .identity) -> LaserRenderFrame {
        guard !strokes.isEmpty else { return .empty }

        var opacity: Float = 1
        var scale: CGFloat = 1
        if !isTouching, let endedAt {
            let elapsed = max(0, now - endedAt)
            if elapsed >= Self.totalLiftDuration {
                strokes.removeAll()
                self.endedAt = nil
                return .empty
            }
            if elapsed > Self.liftHoldDuration {
                let fadeElapsed = elapsed - Self.liftHoldDuration
                let remaining = max(0, 1 - fadeElapsed / Self.liftFadeDuration)
                opacity = Float(remaining)
                scale = CGFloat(0.60 + 0.40 * remaining)
            }
        }

        let glowRadius = Self.trailGlowRadius * scale
        let coreRadius = Self.trailCoreRadius * scale
        var glowSamples: [StrokeSample] = []
        var coreSamples: [StrokeSample] = []
        for (idx, stroke) in strokes.enumerated() where !stroke.isEmpty {
            if idx > 0 && !glowSamples.isEmpty {
                glowSamples.append(StrokeOutline.breakSample)
                coreSamples.append(StrokeOutline.breakSample)
            }
            for sample in stroke {
                glowSamples.append(StrokeSample(point: sample.point, radius: glowRadius))
                coreSamples.append(StrokeSample(point: sample.point, radius: coreRadius))
            }
        }
        guard !glowSamples.isEmpty else { return .empty }

        return LaserRenderFrame(
            glowPath: StrokeOutline.path(for: glowSamples, transform: transform),
            corePath: StrokeOutline.path(for: coreSamples, transform: transform),
            glowColor: color.cgColor,
            opacity: opacity
        )
    }
}
