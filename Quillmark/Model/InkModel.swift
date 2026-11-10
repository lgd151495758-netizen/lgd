import CoreGraphics
import Foundation

/// One sampled input point in page space (PDF points, origin at the top-left corner of the page).
struct InkPoint: Codable, Equatable {
    var x: Float
    var y: Float
    /// Normalized pressure in 0...1. Input without pressure (a finger) uses 0.5.
    var force: Float
    var azimuth: Float
    var altitude: Float
    /// Seconds since the stroke began.
    var t: Float

    init(x: Float, y: Float, force: Float = 0.5, azimuth: Float = 0, altitude: Float = .pi / 2, t: Float = 0) {
        self.x = x
        self.y = y
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.t = t
    }

    var location: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

enum PenKind: String, Codable, CaseIterable, Identifiable {
    case ballpoint
    case fountain
    case brush

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ballpoint: return "圆珠笔"
        case .fountain: return "钢笔"
        case .brush: return "毛笔"
        }
    }

    var symbolName: String {
        switch self {
        case .ballpoint: return "pencil"
        case .fountain: return "pencil.tip"
        case .brush: return "paintbrush.pointed"
        }
    }
}

struct RGBAColor: Codable, Equatable, Hashable {
    var r: Float
    var g: Float
    var b: Float
    var a: Float

    init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    static let ink = RGBAColor(0.11, 0.11, 0.13)
}

struct InkStroke: Codable, Equatable, Identifiable {
    var id: UUID
    var pen: PenKind
    var color: RGBAColor
    /// Nominal stroke width in page points.
    var width: Float
    /// Stabilization strength used when the stroke was drawn (0 = raw, 1 = heavy).
    var smoothing: Float
    var points: [InkPoint]
}

struct PageAnnotations: Codable, Equatable {
    var strokes: [InkStroke] = []
}

struct DocumentAnnotations: Codable, Equatable {
    var version: Int = 1
    /// Keyed by zero-based page index as a string, so the JSON stays a plain object.
    var pages: [String: PageAnnotations] = [:]

    func page(_ index: Int) -> PageAnnotations {
        pages[String(index)] ?? PageAnnotations()
    }

    mutating func updatePage(_ index: Int, _ body: (inout PageAnnotations) -> Void) {
        var page = page(index)
        body(&page)
        pages[String(index)] = page.strokes.isEmpty ? nil : page
    }
}

/// Current tool configuration, persisted between launches.
struct ToolSettings: Codable, Equatable {
    var pen: PenKind = .fountain
    var color: RGBAColor = .ink
    var width: Float = 1.8
    var fingerDrawing: Bool = false
    var smoothing: Float = 0.45
    var prediction: Bool = true

    static let widthPresets: [Float] = [1.0, 1.8, 3.0]

    static let palette: [RGBAColor] = [
        .ink,
        RGBAColor(0.10, 0.27, 0.66),
        RGBAColor(0.80, 0.16, 0.16),
        RGBAColor(0.11, 0.55, 0.32),
        RGBAColor(0.48, 0.25, 0.70),
        RGBAColor(0.93, 0.50, 0.10),
    ]

    private static let defaultsKey = "toolSettings.v1"

    static func load(from defaults: UserDefaults = .standard) -> ToolSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(ToolSettings.self, from: data) else {
            return ToolSettings()
        }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum PageMapping {
    /// View points per page point for a page drawn at `viewSize`.
    static func scale(viewSize: CGSize, pageSize: CGSize) -> CGFloat {
        guard pageSize.width > 0, viewSize.width > 0 else { return 1 }
        return viewSize.width / pageSize.width
    }
}
