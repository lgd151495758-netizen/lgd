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

/// Time-based laser trail engine: keeps the full glowing trail visible while the pen touches the
/// screen, then smoothly fades it away once the pen lifts. Renders identically on iPad and the
/// external presentation display.
final class LaserPointerEngine {
    /// Duration of the smooth fade-out after the pen leaves the screen.
    static let liftFadeDuration: TimeInterval = 0.45
    static let trailGlowRadius: CGFloat = 4.2
    static let trailCoreRadius: CGFloat = 1.7

    private(set) var color: RGBAColor = ToolSettings.laserPalette[0]
    private(set) var samples: [LaserSample] = []
    private(set) var isTouching = false
    private var endedAt: TimeInterval?

    var isActive: Bool {
        isTouching || !samples.isEmpty
    }

    func begin(at point: CGPoint, color: RGBAColor, now: TimeInterval) {
        self.color = color
        self.isTouching = true
        self.endedAt = nil
        samples = [LaserSample(point: point, time: now)]
    }

    func move(to point: CGPoint, now: TimeInterval) {
        guard isTouching else { return }
        if let last = samples.last, hypot(point.x - last.point.x, point.y - last.point.y) < 1.0 {
            samples[samples.count - 1].time = now
        } else {
            samples.append(LaserSample(point: point, time: now))
        }
    }

    func end(now: TimeInterval) {
        isTouching = false
        endedAt = now
    }

    func cancel() {
        isTouching = false
        endedAt = nil
        samples.removeAll()
    }

    /// Computes laser glow & core paths in view coordinates via `transform`.
    /// While `isTouching`, the full trail remains visible at full opacity; once lifted, it fades
    /// smoothly over `liftFadeDuration` and clears.
    func frame(at now: TimeInterval, transform: CGAffineTransform = .identity) -> LaserRenderFrame {
        guard !samples.isEmpty else { return .empty }

        var opacity: Float = 1
        var scale: CGFloat = 1
        if !isTouching, let endedAt {
            let elapsed = max(0, now - endedAt)
            if elapsed >= Self.liftFadeDuration {
                samples.removeAll()
                self.endedAt = nil
                return .empty
            }
            let remaining = 1 - elapsed / Self.liftFadeDuration
            opacity = Float(remaining)
            scale = CGFloat(0.55 + 0.45 * remaining)
        }

        let glowRadius = Self.trailGlowRadius * scale
        let coreRadius = Self.trailCoreRadius * scale
        let glowSamples = samples.map { StrokeSample(point: $0.point, radius: glowRadius) }
        let coreSamples = samples.map { StrokeSample(point: $0.point, radius: coreRadius) }
        return LaserRenderFrame(
            glowPath: StrokeOutline.path(for: glowSamples, transform: transform),
            corePath: StrokeOutline.path(for: coreSamples, transform: transform),
            glowColor: color.cgColor,
            opacity: opacity
        )
    }
}
