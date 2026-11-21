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

enum ToolKind: String, Codable, CaseIterable {
    case pen
    case highlighter
    case tape
    case laser
    case eraser
}

enum StrokeLineStyle: String, Codable, CaseIterable, Identifiable {
    case solid
    case dashed
    case dotted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .solid: return "实线"
        case .dashed: return "虚线"
        case .dotted: return "点线"
        }
    }
}

enum LaserMode: String, Codable, CaseIterable, Identifiable {
    case trail
    case dot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trail: return "拖尾"
        case .dot: return "光点"
        }
    }
}

enum EraserMode: String, Codable, CaseIterable, Identifiable {
    /// Removes only the touched part of a stroke (splits it).
    case pixel
    /// Removes every stroke the eraser touches.
    case stroke

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pixel: return "精确擦除"
        case .stroke: return "整笔擦除"
        }
    }
}

/// What kind of mark a stroke is. Missing in older files, which means `.pen`.
enum InkTool: String, Codable {
    case pen
    case highlighter
    case tape
}

/// Where a stroke written on a live web page is attached. Points of an anchored stroke are
/// relative to the top-left corner of the anchor element, in CSS pixels.
struct WebAnchor: Codable, Equatable, Hashable {
    /// CSS path from the nearest unique `id` (or `body`), e.g. `#main > p:nth-of-type(3)`.
    var selector: String
    /// First characters of the element's text, used to find it again if the path changed.
    var fingerprint: String
    var tag: String

    static let body = WebAnchor(selector: "body", fingerprint: "", tag: "BODY")
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
    /// `nil` for pen strokes written before highlighters existed.
    var tool: InkTool?
    /// Already-processed centerline. Set for pieces left over by the precise eraser or snapped
    /// shapes, which must keep their exact geometry instead of being re-smoothed from raw points.
    var baked: [StrokeSample]?
    /// Set for strokes on live web documents.
    var anchor: WebAnchor?
    /// Solid, dashed or dotted. `nil` means `.solid`.
    var lineStyle: StrokeLineStyle?
    /// For `.tape` strokes: whether the tape is currently peeled/revealed to show content underneath.
    var revealed: Bool?

    var isHighlighter: Bool { tool == .highlighter }
    var isTape: Bool { tool == .tape }
    var isRevealed: Bool { revealed == true }
    var resolvedLineStyle: StrokeLineStyle { lineStyle ?? .solid }

    /// The same stroke moved by `offset` (used to switch between page and anchor coordinates).
    func translated(by offset: CGPoint) -> InkStroke {
        var copy = self
        let dx = Float(offset.x)
        let dy = Float(offset.y)
        copy.points = points.map { p in
            var q = p
            q.x += dx
            q.y += dy
            return q
        }
        copy.baked = baked?.map { s in
            StrokeSample(point: CGPoint(x: s.point.x + offset.x, y: s.point.y + offset.y), radius: s.radius)
        }
        return copy
    }
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
    var kind: ToolKind = .pen
    /// Tool to return to on Apple Pencil double-tap ("switch to previous").
    var previousKind: ToolKind = .eraser

    // Pen
    var pen: PenKind = .fountain
    var color: RGBAColor = .ink
    var width: Float = 1.8
    var lineStyle: StrokeLineStyle = .solid
    var drawAndHold: Bool = true
    var smoothing: Float = 0.45
    var prediction: Bool = true

    // Highlighter
    var highlighterColor: RGBAColor = ToolSettings.highlighterPalette[0]
    var highlighterWidth: Float = 14
    var highlighterStraight: Bool = false

    // Cover Tape
    var tapeColor: RGBAColor = ToolSettings.tapePalette[0]
    var tapeWidth: Float = 26
    var tapeStraight: Bool = true

    // Laser Pointer
    var laserMode: LaserMode = .trail
    var laserColor: RGBAColor = ToolSettings.laserPalette[0]

    // Eraser
    var eraserMode: EraserMode = .pixel
    var eraserRadius: Float = 8
    var eraseHighlighterOnly: Bool = false

    var fingerDrawing: Bool = false

    static let widthPresets: [Float] = [1.0, 1.8, 3.0]
    static let highlighterWidthPresets: [Float] = [8, 14, 22]
    static let tapeWidthPresets: [Float] = [18, 26, 42]
    static let eraserRadiusPresets: [Float] = [4, 8, 16]

    static let palette: [RGBAColor] = [
        .ink,
        RGBAColor(0.10, 0.27, 0.66),
        RGBAColor(0.80, 0.16, 0.16),
        RGBAColor(0.11, 0.55, 0.32),
        RGBAColor(0.48, 0.25, 0.70),
        RGBAColor(0.93, 0.50, 0.10),
    ]

    static let highlighterPalette: [RGBAColor] = [
        RGBAColor(1.00, 0.88, 0.20),
        RGBAColor(0.55, 0.92, 0.45),
        RGBAColor(1.00, 0.55, 0.75),
        RGBAColor(0.45, 0.80, 1.00),
        RGBAColor(1.00, 0.70, 0.30),
    ]

    static let tapePalette: [RGBAColor] = [
        RGBAColor(0.95, 0.89, 0.68), // masking tape beige
        RGBAColor(0.76, 0.86, 0.96), // soft sky
        RGBAColor(0.76, 0.91, 0.81), // soft mint
        RGBAColor(0.96, 0.80, 0.84), // soft rose
        RGBAColor(0.84, 0.85, 0.88), // neutral gray
    ]

    static let laserPalette: [RGBAColor] = [
        RGBAColor(0.98, 0.16, 0.18), // classic red
        RGBAColor(0.15, 0.55, 1.00), // electric blue
        RGBAColor(0.10, 0.82, 0.42), // emerald
        RGBAColor(1.00, 0.58, 0.08), // amber
    ]

    /// Selects a tool and remembers the one being left for double-tap "switch to previous".
    mutating func select(_ newKind: ToolKind) {
        guard newKind != kind else { return }
        previousKind = kind
        kind = newKind
    }

    /// Apple Pencil double-tap with the "switch to eraser" preference.
    mutating func toggleEraser() {
        if kind == .eraser {
            let target = previousKind == .eraser ? ToolKind.pen : previousKind
            previousKind = .eraser
            kind = target
        } else {
            select(.eraser)
        }
    }

    /// Apple Pencil double-tap with the "switch to previous tool" preference.
    mutating func switchToPrevious() {
        let target = previousKind
        previousKind = kind
        kind = target == kind ? .pen : target
    }

    private static let defaultsKey = "toolSettings.v3"

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
