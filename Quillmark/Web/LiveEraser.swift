import CoreGraphics
import Foundation

/// Erasing on a live page. Strokes are stored relative to their anchor element; `origins`
/// gives the current document position of each visible stroke's anchor. Strokes without an
/// origin (anchor hidden or not laid out yet) are never touched.
enum LiveEraser {
    struct Result {
        var strokes: [InkStroke]
        /// Origins for pieces created by the precise eraser (same anchor as their parent).
        var newOrigins: [UUID: CGPoint]
        var changed: Bool
    }

    static func erase(_ strokes: [InkStroke], origins: [UUID: CGPoint], from a: CGPoint, to b: CGPoint,
                      radius: CGFloat, mode: EraserMode, highlighterOnly: Bool,
                      cache: StrokeGeometryCache) -> Result {
        var output: [InkStroke] = []
        output.reserveCapacity(strokes.count)
        var newOrigins: [UUID: CGPoint] = [:]
        var changed = false

        for stroke in strokes {
            guard let origin = origins[stroke.id] else {
                output.append(stroke)
                continue
            }
            // Move the eraser into the stroke's anchor coordinates instead of moving the stroke.
            let localA = CGPoint(x: a.x - origin.x, y: a.y - origin.y)
            let localB = CGPoint(x: b.x - origin.x, y: b.y - origin.y)
            let result = EraserEngine.erase([stroke], from: localA, to: localB, radius: radius, mode: mode,
                                            highlighterOnly: highlighterOnly, cache: cache)
            output.append(contentsOf: result.strokes)
            if result.changed {
                changed = true
                for piece in result.strokes where piece.id != stroke.id {
                    newOrigins[piece.id] = origin
                }
            }
        }
        return Result(strokes: output, newOrigins: newOrigins, changed: changed)
    }
}
