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

/// Pure time-based laser pointer engine supporting glowing fading trails and pointer dots.
/// Produces paths that render identically on the iPad and the external presentation display.
final class LaserPointerEngine {
    static let trailLifetime: TimeInterval = 0.95
    static let dotFadeDuration: TimeInterval = 0.22
    static let trailGlowRadius: CGFloat = 4.2
    static let trailCoreRadius: CGFloat = 1.7
    static let dotGlowRadius: CGFloat = 9.0
    static let dotCoreRadius: CGFloat = 4.0

    private(set) var mode: LaserMode = .trail
    private(set) var color: RGBAColor = ToolSettings.laserPalette[0]
    private(set) var samples: [LaserSample] = []
    private var isTouching = false
    private var endedAt: TimeInterval?

    var isActive: Bool {
        isTouching || !samples.isEmpty
    }

    func begin(at point: CGPoint, mode: LaserMode, color: RGBAColor, now: TimeInterval) {
        self.mode = mode
        self.color = color
        self.isTouching = true
        self.endedAt = nil
        samples = [LaserSample(point: point, time: now)]
    }

    func move(to point: CGPoint, now: TimeInterval) {
        guard isTouching else { return }
        switch mode {
        case .dot:
            samples = [LaserSample(point: point, time: now)]
        case .trail:
            if let last = samples.last, hypot(point.x - last.point.x, point.y - last.point.y) < 1.0 {
                samples[samples.count - 1].time = now
            } else {
                samples.append(LaserSample(point: point, time: now))
            }
            pruneTrail(now: now)
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

    /// Advances decay to `now` and returns paths in view coordinates via `transform`.
    func frame(at now: TimeInterval, transform: CGAffineTransform = .identity) -> LaserRenderFrame {
        guard !samples.isEmpty else { return .empty }

        switch mode {
        case .dot:
            let point = samples.last!.point
            var opacity: Float = 1
            if !isTouching, let endedAt {
                let elapsed = now - endedAt
                if elapsed >= Self.dotFadeDuration {
                    samples.removeAll()
                    return .empty
                }
                opacity = Float(max(0, 1 - elapsed / Self.dotFadeDuration))
            }
            let glow = StrokeOutline.path(for: [StrokeSample(point: point, radius: Self.dotGlowRadius)],
                                          transform: transform)
            let core = StrokeOutline.path(for: [StrokeSample(point: point, radius: Self.dotCoreRadius)],
                                          transform: transform)
            return LaserRenderFrame(glowPath: glow, corePath: core, glowColor: color.cgColor, opacity: opacity)

        case .trail:
            pruneTrail(now: now)
            guard !samples.isEmpty else { return .empty }
            let glowSamples = samples.map { s -> StrokeSample in
                let life = max(0, min(1, 1 - (now - s.time) / Self.trailLifetime))
                return StrokeSample(point: s.point, radius: max(0.35, Self.trailGlowRadius * CGFloat(sqrt(life))))
            }
            let coreSamples = samples.map { s -> StrokeSample in
                let life = max(0, min(1, 1 - (now - s.time) / Self.trailLifetime))
                return StrokeSample(point: s.point, radius: max(0.15, Self.trailCoreRadius * CGFloat(sqrt(life))))
            }
            let newestLife = max(0, min(1, 1 - (now - samples.last!.time) / Self.trailLifetime))
            let opacity = Float(isTouching ? 1.0 : sqrt(newestLife))
            return LaserRenderFrame(
                glowPath: StrokeOutline.path(for: glowSamples, transform: transform),
                corePath: StrokeOutline.path(for: coreSamples, transform: transform),
                glowColor: color.cgColor,
                opacity: opacity
            )
        }
    }

    private func pruneTrail(now: TimeInterval) {
        let cutoff = now - Self.trailLifetime
        if let firstAlive = samples.firstIndex(where: { $0.time >= cutoff }) {
            if firstAlive > 0 {
                samples.removeFirst(firstAlive)
            }
        } else {
            samples.removeAll()
        }
    }
}
