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
    case lasso
    case tape
    case shape
    case laser
    case eraser
}

enum ShapePreset: String, Codable, CaseIterable, Identifiable {
    case segment
    case arrow
    case rightTriangle
    case isoscelesTriangle
    case equilateralTriangle
    case rectangle
    case parallelogram
    case rhombus
    case trapezoid
    case pentagon
    case hexagon
    case circle
    case parabola
    case axes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .segment: return "线段"
        case .arrow: return "箭头"
        case .rightTriangle: return "直角△"
        case .isoscelesTriangle: return "等腰△"
        case .equilateralTriangle: return "等边△"
        case .rectangle: return "矩形"
        case .parallelogram: return "平行四边"
        case .rhombus: return "菱形"
        case .trapezoid: return "梯形"
        case .pentagon: return "正五边"
        case .hexagon: return "正六边"
        case .circle: return "圆"
        case .parabola: return "抛物线"
        case .axes: return "坐标系"
        }
    }

    var supportsFill: Bool {
        switch self {
        case .segment, .arrow, .parabola, .axes: return false
        default: return true
        }
    }
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
    /// Parametric geometric representation for standard shapes, compass arcs/circles, and snapped shapes.
    var geometry: GeometricPrimitive?
    /// Optional translucent shading fill color for closed geometric shapes (e.g. shaded area problems).
    var fillColor: RGBAColor?

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
        copy.geometry = geometry?.translated(by: offset)
        return copy
    }
}

enum ScratchpadPaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank
    case grid
    case dot
    case graph

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blank: return "空白"
        case .grid: return "方格"
        case .dot: return "点阵"
        case .graph: return "坐标纸"
        }
    }
}

enum ScratchpadSplitMode: String, Codable, Equatable {
    /// Freely movable & resizable floating sticky-note window over the live HTML page.
    case floating
    /// Full-screen math whiteboard.
    case full
}

/// Pure layout clamping for the floating math sticky note (`便签`).
enum StickyNoteLayout {
    static let minSize = CGSize(width: 260, height: 200)
    static let edgeMargin: CGFloat = 10

    /// Comfortable initial floating sticky-note frame in the lower-right area of `bounds`.
    static func defaultFrame(in bounds: CGRect) -> CGRect {
        let w = min(max(minSize.width, round(bounds.width * 0.48)), max(minSize.width, bounds.width - edgeMargin * 2))
        let h = min(max(minSize.height, round(bounds.height * 0.46)), max(minSize.height, bounds.height - edgeMargin * 2))
        let x = max(edgeMargin, bounds.width - w - 18)
        let y = max(edgeMargin, bounds.height - h - 22)
        return clamped(CGRect(x: x, y: y, width: w, height: h), in: bounds)
    }

    /// Clamps any dragged/resized sticky-note rect to stay reachable inside `bounds`.
    static func clamped(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return rect }
        let maxW = max(1, bounds.width - edgeMargin * 2)
        let maxH = max(1, bounds.height - edgeMargin * 2)
        let w = min(max(min(minSize.width, maxW), rect.width), maxW)
        let h = min(max(min(minSize.height, maxH), rect.height), maxH)
        let minX = edgeMargin
        let maxX = max(minX, bounds.width - w - edgeMargin)
        let minY = edgeMargin
        let maxY = max(minY, bounds.height - h - edgeMargin)
        let x = min(max(minX, rect.origin.x), maxX)
        let y = min(max(minY, rect.origin.y), maxY)
        return CGRect(x: round(x), y: round(y), width: round(w), height: round(h))
    }

    /// Resizes from the bottom-right corner by `(dx, dy)` while pinning the top-left corner.
    static func resizingBottomRight(from rect: CGRect, delta: CGPoint, in bounds: CGRect) -> CGRect {
        let maxW = max(minSize.width, bounds.width - rect.minX - edgeMargin)
        let maxH = max(minSize.height, bounds.height - rect.minY - edgeMargin)
        let newW = min(max(minSize.width, rect.width + delta.x), maxW)
        let newH = min(max(minSize.height, rect.height + delta.y), maxH)
        return clamped(CGRect(x: rect.minX, y: rect.minY, width: newW, height: newH), in: bounds)
    }

    /// Resizes from the bottom-left corner by `(dx, dy)` while pinning the top-right corner.
    static func resizingBottomLeft(from rect: CGRect, delta: CGPoint, in bounds: CGRect) -> CGRect {
        let rightEdge = rect.maxX
        let maxW = max(minSize.width, rightEdge - edgeMargin)
        let maxH = max(minSize.height, bounds.height - rect.minY - edgeMargin)
        let newW = min(max(minSize.width, rect.width - delta.x), maxW)
        let newH = min(max(minSize.height, rect.height + delta.y), maxH)
        return clamped(CGRect(x: rightEdge - newW, y: rect.minY, width: newW, height: newH), in: bounds)
    }
}

struct PageAnnotations: Codable, Equatable {
    var strokes: [InkStroke] = []
}

/// Persisted scroll position, zoom scale, and active PDF page for a document so switching tabs
/// or reopening the document later restores the exact viewing position.
struct ViewportState: Codable, Equatable {
    var offsetX: CGFloat
    var offsetY: CGFloat
    var zoomScale: CGFloat
    var pageIndex: Int?

    var isValid: Bool {
        offsetX.isFinite && offsetY.isFinite && zoomScale.isFinite && zoomScale > 0
    }

    func isApproximatelyEqual(to other: ViewportState) -> Bool {
        abs(offsetX - other.offsetX) < 1.0
            && abs(offsetY - other.offsetY) < 1.0
            && abs(zoomScale - other.zoomScale) < 0.01
            && pageIndex == other.pageIndex
    }

    /// Clamps a saved content offset safely within the current scrollable content bounds.
    static func clampedOffset(_ offset: CGPoint, contentSize: CGSize, boundsSize: CGSize) -> CGPoint {
        let maxX = max(0, contentSize.width - boundsSize.width)
        let maxY = max(0, contentSize.height - boundsSize.height)
        let x = offset.x.isFinite ? min(max(0, offset.x), maxX) : 0
        let y = offset.y.isFinite ? min(max(0, offset.y), maxY) : 0
        return CGPoint(x: x, y: y)
    }
}

struct DocumentAnnotations: Codable, Equatable {
    var version: Int = 1
    /// Keyed by zero-based page index as a string, so the JSON stays a plain object.
    var pages: [String: PageAnnotations] = [:]
    /// Per-document multi-page math sticky-note pages (optional for backward compatibility).
    var scratchpadPages: [PageAnnotations]?
    /// Preferred background paper style for this document's sticky note.
    var scratchpadPaper: ScratchpadPaperStyle?
    /// Last floating position & size of this document's sticky note.
    var scratchpadFrame: CGRect?
    /// Last scroll offset, zoom scale, and PDF page index for reopening at the previous position.
    var viewport: ViewportState?

    /// Negative page indices (`-1, -2, ...`) map to zero-based scratchpad pages (`0, 1, ...`).
    static func scratchpadPageID(_ scratchpadIndex: Int) -> Int {
        -(max(0, scratchpadIndex) + 1)
    }

    var resolvedScratchpadPageCount: Int {
        max(1, scratchpadPages?.count ?? 0)
    }

    func page(_ index: Int) -> PageAnnotations {
        if index < 0 {
            let sIdx = -index - 1
            guard let list = scratchpadPages, sIdx >= 0, sIdx < list.count else {
                return PageAnnotations()
            }
            return list[sIdx]
        }
        return pages[String(index)] ?? PageAnnotations()
    }

    mutating func updatePage(_ index: Int, _ body: (inout PageAnnotations) -> Void) {
        if index < 0 {
            let sIdx = -index - 1
            var list = scratchpadPages ?? [PageAnnotations()]
            while list.count <= sIdx {
                list.append(PageAnnotations())
            }
            var target = list[sIdx]
            body(&target)
            list[sIdx] = target
            scratchpadPages = list
            return
        }
        var page = page(index)
        body(&page)
        pages[String(index)] = page.strokes.isEmpty ? nil : page
    }

    @discardableResult
    mutating func appendScratchpadPage() -> Int {
        var list = scratchpadPages ?? [PageAnnotations()]
        list.append(PageAnnotations())
        scratchpadPages = list
        return list.count - 1
    }
}

/// Current tool configuration, persisted between launches.
struct ToolSettings: Codable, Equatable {
    var kind: ToolKind = .pen
    /// Tool to return to on Apple Pencil double-tap ("switch to previous").
    var previousKind: ToolKind = .eraser

    // Pen (ballpoint only; fountain/brush kept on PenKind solely for decoding legacy annotations)
    var pen: PenKind = .ballpoint
    var color: RGBAColor = .ink
    var width: Float = 1.8
    var lineStyle: StrokeLineStyle = .solid
    var drawAndHold: Bool = true
    var smoothing: Float = 0.45
    var prediction: Bool = true

    // Cover Tape
    var tapeColor: RGBAColor = ToolSettings.tapePalette[0]
    var tapeWidth: Float = 26
    var tapeStraight: Bool = true

    // Standard Geometric Shapes
    var shapePreset: ShapePreset = .rightTriangle
    var shapeFilled: Bool = false

    // Laser Pointer
    var laserColor: RGBAColor = ToolSettings.laserPalette[0]

    // Eraser
    var eraserMode: EraserMode = .pixel
    var eraserRadius: Float = 8

    var fingerDrawing: Bool = false

    static let widthPresets: [Float] = [1.0, 1.8, 3.0]
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

    private static let defaultsKey = "toolSettings.v5"

    static func load(from defaults: UserDefaults = .standard) -> ToolSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var value = try? JSONDecoder().decode(ToolSettings.self, from: data) else {
            return ToolSettings()
        }
        value.pen = .ballpoint
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
