import CoreGraphics
import Foundation

/// Converts a `CGPath` into SVG path data (`d` attribute).
enum SVGPath {
    static func string(from path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let p = element.points
            switch element.type {
            case .moveToPoint:
                d += "M\(format(p[0].x)) \(format(p[0].y))"
            case .addLineToPoint:
                d += "L\(format(p[0].x)) \(format(p[0].y))"
            case .addQuadCurveToPoint:
                d += "Q\(format(p[0].x)) \(format(p[0].y)) \(format(p[1].x)) \(format(p[1].y))"
            case .addCurveToPoint:
                d += "C\(format(p[0].x)) \(format(p[0].y)) \(format(p[1].x)) \(format(p[1].y)) \(format(p[2].x)) \(format(p[2].y))"
            case .closeSubpath:
                d += "Z"
            @unknown default:
                break
            }
        }
        return d
    }

    static func format(_ value: CGFloat) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", Double(rounded))
    }
}

extension RGBAColor {
    var cssString: String {
        "rgba(\(Int((r * 255).rounded())),\(Int((g * 255).rounded())),\(Int((b * 255).rounded())),\(a))"
    }
}
