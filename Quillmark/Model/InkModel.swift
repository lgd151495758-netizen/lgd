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

    /// True for white / bright chalk colors that need a subtle border on light UI backgrounds.
    var isVeryLight: Bool {
        (0.299 * r + 0.587 * g + 0.114 * b) > 0.82
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

/// Independent annotation layer on the same document (e.g. "默认板书", "九(1)班", "九(2)班")
/// so a teacher can teach multiple classes on one PDF/HTML without duplicating source files.
struct InkLayer: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var createdAt: Date
    var pages: [String: PageAnnotations]
    var scratchpadPages: [PageAnnotations]?

    init(id: UUID = UUID(),
         name: String,
         createdAt: Date = Date(),
         pages: [String: PageAnnotations] = [:],
         scratchpadPages: [PageAnnotations]? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.pages = pages
        self.scratchpadPages = scratchpadPages
    }

    /// Total stroke count across all main document pages in this layer.
    var mainStrokeCount: Int {
        pages.values.reduce(0) { $0 + $1.strokes.count }
    }
}

struct DocumentAnnotations: Codable, Equatable {
    enum NewLayerTemplate: Equatable {
        /// Start completely clean (no handwriting, no cover tapes).
        case blank
        /// Keep Cover Tapes from the active layer and reset them to covered (`revealed = false`).
        case keepTapesFromCurrent
        /// Duplicate all strokes, shapes, cover tapes, and scratchpad pages from the active layer.
        case duplicateCurrent
    }

    static let implicitDefaultLayerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultLayerName = "默认板书"

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
    /// Multi-class annotation layers (optional for backward compatibility with v1.3 documents).
    var layers: [InkLayer]?
    /// Currently active layer ID when `layers` is populated.
    var activeLayerID: UUID?

    /// Negative page indices (`-1, -2, ...`) map to zero-based scratchpad pages (`0, 1, ...`).
    static func scratchpadPageID(_ scratchpadIndex: Int) -> Int {
        -(max(0, scratchpadIndex) + 1)
    }

    var resolvedScratchpadPageCount: Int {
        max(1, scratchpadPages?.count ?? 0)
    }

    /// Non-empty scratchpad pages in display order alongside their zero-based page index.
    var nonEmptyScratchpadPages: [(index: Int, strokes: [InkStroke])] {
        guard let list = scratchpadPages else { return [] }
        return list.enumerated().compactMap { idx, page in
            page.strokes.isEmpty ? nil : (idx, page.strokes)
        }
    }

    /// All layers with the currently active layer reflecting the latest top-level `pages` and `scratchpadPages`.
    var resolvedLayers: [InkLayer] {
        guard var list = layers, !list.isEmpty else {
            return [
                InkLayer(
                    id: activeLayerID ?? Self.implicitDefaultLayerID,
                    name: Self.defaultLayerName,
                    createdAt: Date(timeIntervalSince1970: 0),
                    pages: pages,
                    scratchpadPages: scratchpadPages
                ),
            ]
        }
        let currentID = activeLayerID ?? list[0].id
        if let idx = list.firstIndex(where: { $0.id == currentID }) {
            list[idx].pages = pages
            list[idx].scratchpadPages = scratchpadPages
        }
        return list
    }

    var resolvedActiveLayerID: UUID {
        if let list = layers, !list.isEmpty {
            if let activeLayerID, list.contains(where: { $0.id == activeLayerID }) {
                return activeLayerID
            }
            return list[0].id
        }
        return activeLayerID ?? Self.implicitDefaultLayerID
    }

    var activeLayerName: String {
        let currentID = resolvedActiveLayerID
        return resolvedLayers.first(where: { $0.id == currentID })?.name ?? Self.defaultLayerName
    }

    var hasMultipleLayers: Bool {
        (layers?.count ?? 0) > 1
    }

    /// Writes the active top-level `pages` and `scratchpadPages` back into `layers` if layers are enabled.
    mutating func syncActiveLayerFromTopLevel() {
        guard var list = layers, !list.isEmpty else { return }
        let currentID = resolvedActiveLayerID
        if let idx = list.firstIndex(where: { $0.id == currentID }) {
            list[idx].pages = pages
            list[idx].scratchpadPages = scratchpadPages
            activeLayerID = currentID
            layers = list
        }
    }

    /// Materializes the implicit single layer into `layers` so multi-layer operations have stable IDs.
    @discardableResult
    mutating func ensureLayersInitialized(defaultName: String = DocumentAnnotations.defaultLayerName) -> UUID {
        if var list = layers, !list.isEmpty {
            let currentID = resolvedActiveLayerID
            activeLayerID = currentID
            if let idx = list.firstIndex(where: { $0.id == currentID }) {
                list[idx].pages = pages
                list[idx].scratchpadPages = scratchpadPages
                layers = list
            }
            return currentID
        }
        let id = activeLayerID ?? Self.implicitDefaultLayerID
        let initial = InkLayer(id: id, name: defaultName, createdAt: Date(),
                               pages: pages, scratchpadPages: scratchpadPages)
        layers = [initial]
        activeLayerID = id
        return id
    }

    /// Switches the active annotation layer, saving current strokes into the previous layer first.
    @discardableResult
    mutating func switchToLayer(_ targetID: UUID) -> Bool {
        syncActiveLayerFromTopLevel()
        guard let list = layers, let target = list.first(where: { $0.id == targetID }) else {
            return false
        }
        activeLayerID = target.id
        pages = target.pages
        scratchpadPages = target.scratchpadPages
        return true
    }

    /// Creates a new class layer derived from `template` and switches to it immediately.
    @discardableResult
    mutating func createLayer(name: String, template: NewLayerTemplate) -> InkLayer {
        ensureLayersInitialized()
        syncActiveLayerFromTopLevel()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty ? "班级 \((layers?.count ?? 1) + 1)" : trimmed

        let newPages: [String: PageAnnotations]
        let newScratchpad: [PageAnnotations]?
        switch template {
        case .blank:
            newPages = [:]
            newScratchpad = nil
        case .keepTapesFromCurrent:
            var keptPages: [String: PageAnnotations] = [:]
            for (key, page) in pages {
                let kept: [InkStroke] = page.strokes.compactMap { stroke in
                    guard stroke.isTape else { return nil }
                    var covered = stroke
                    covered.id = UUID()
                    covered.revealed = false
                    return covered
                }
                if !kept.isEmpty {
                    keptPages[key] = PageAnnotations(strokes: kept)
                }
            }
            newPages = keptPages
            newScratchpad = nil
        case .duplicateCurrent:
            newPages = pages
            newScratchpad = scratchpadPages
        }

        let created = InkLayer(id: UUID(), name: resolvedName, createdAt: Date(),
                               pages: newPages, scratchpadPages: newScratchpad)
        var list = layers ?? []
        list.append(created)
        layers = list
        activeLayerID = created.id
        pages = created.pages
        scratchpadPages = created.scratchpadPages
        return created
    }

    @discardableResult
    mutating func renameLayer(_ id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        ensureLayersInitialized()
        guard var list = layers, let idx = list.firstIndex(where: { $0.id == id }) else { return false }
        list[idx].name = trimmed
        layers = list
        return true
    }

    /// Deletes a layer when at least two layers exist. If the active layer is deleted, switches to an adjacent one.
    @discardableResult
    mutating func deleteLayer(_ id: UUID) -> Bool {
        syncActiveLayerFromTopLevel()
        guard var list = layers, list.count > 1,
              let idx = list.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let removingActive = (resolvedActiveLayerID == id)
        list.remove(at: idx)
        layers = list
        if removingActive {
            let nextIdx = min(idx, list.count - 1)
            let nextLayer = list[nextIdx]
            activeLayerID = nextLayer.id
            pages = nextLayer.pages
            scratchpadPages = nextLayer.scratchpadPages
        }
        return true
    }

    /// Shifts all PDF page indices `>= insertIndex` up by `+1` in both top-level `pages` and every class layer.
    mutating func shiftPageIndicesForInsertedPage(at insertIndex: Int) {
        func shifted(_ dict: [String: PageAnnotations]) -> [String: PageAnnotations] {
            var result: [String: PageAnnotations] = [:]
            result.reserveCapacity(dict.count)
            for (key, value) in dict {
                if let pageNum = Int(key), pageNum >= insertIndex {
                    result[String(pageNum + 1)] = value
                } else {
                    result[key] = value
                }
            }
            return result
        }

        syncActiveLayerFromTopLevel()
        pages = shifted(pages)
        if var list = layers {
            for i in list.indices {
                list[i].pages = shifted(list[i].pages)
            }
            layers = list
        }
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

/// One customizable quick-access pen slot in the toolbar (color + width + solid/dashed/dotted style).
struct PenPreset: Codable, Equatable, Identifiable {
    var id: Int
    var color: RGBAColor
    var width: Float
    var lineStyle: StrokeLineStyle
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
    /// Four quick-switch pen slots (customizable in-place; optional for v1.4 backward compatibility).
    var penPresets: [PenPreset]?
    var activePenPresetIndex: Int?
    /// Two-finger tap to undo and three-finger tap to redo across all canvases (default on).
    var multiFingerUndo: Bool?
    /// Four pinned favorite colors shown directly on the toolbar (customizable via the color palette).
    var quickColors: [RGBAColor]?

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
        RGBAColor(0.98, 0.80, 0.12), // bright chalk yellow (great for dark-mode HTML courseware)
        RGBAColor(0.97, 0.97, 0.99), // chalk white (great for dark-mode HTML courseware)
    ]

    /// The 4 most frequently used math teaching colors displayed directly on the toolbar.
    static let defaultQuickColors: [RGBAColor] = [
        .ink,                        // classic black
        RGBAColor(0.80, 0.16, 0.16), // emphasis red
        RGBAColor(0.10, 0.27, 0.66), // deep blue
        RGBAColor(0.11, 0.55, 0.32), // forest green
    ]

    /// Curated 16-swatch classroom palette shown inside the Color Palette popover.
    static let extendedPalette: [RGBAColor] = [
        .ink,                        // classic black
        RGBAColor(0.42, 0.45, 0.50), // slate gray
        RGBAColor(0.97, 0.97, 0.99), // chalk white (dark HTML courseware)
        RGBAColor(0.10, 0.27, 0.66), // deep blue
        RGBAColor(0.05, 0.52, 0.88), // bright azure
        RGBAColor(0.02, 0.68, 0.78), // cyan
        RGBAColor(0.80, 0.16, 0.16), // crimson red
        RGBAColor(0.94, 0.32, 0.42), // coral rose
        RGBAColor(0.84, 0.20, 0.58), // magenta
        RGBAColor(0.48, 0.25, 0.70), // violet
        RGBAColor(0.36, 0.34, 0.84), // indigo
        RGBAColor(0.11, 0.55, 0.32), // forest green
        RGBAColor(0.16, 0.72, 0.42), // emerald
        RGBAColor(0.54, 0.66, 0.12), // olive
        RGBAColor(0.93, 0.50, 0.10), // vivid orange
        RGBAColor(0.98, 0.80, 0.12), // bright chalk yellow
    ]

    var resolvedQuickColors: [RGBAColor] {
        if let quickColors, quickColors.count == Self.defaultQuickColors.count {
            return quickColors
        }
        return Self.defaultQuickColors
    }

    mutating func setQuickColor(_ newColor: RGBAColor, at index: Int) {
        var colors = resolvedQuickColors
        guard index >= 0, index < colors.count else { return }
        colors[index] = newColor
        quickColors = colors
        color = newColor
    }

    mutating func resetQuickColorsToDefault() {
        quickColors = Self.defaultQuickColors
    }

    static let defaultPenPresets: [PenPreset] = [
        PenPreset(id: 0, color: .ink, width: 1.8, lineStyle: .solid),
        PenPreset(id: 1, color: RGBAColor(0.80, 0.16, 0.16), width: 1.8, lineStyle: .solid),
        PenPreset(id: 2, color: RGBAColor(0.10, 0.27, 0.66), width: 1.8, lineStyle: .dashed),
        PenPreset(id: 3, color: RGBAColor(0.97, 0.97, 0.99), width: 1.8, lineStyle: .solid),
    ]

    var isMultiFingerUndoEnabled: Bool {
        multiFingerUndo ?? true
    }

    var resolvedPenPresets: [PenPreset] {
        if let penPresets, penPresets.count == Self.defaultPenPresets.count {
            return penPresets
        }
        return Self.defaultPenPresets
    }

    var resolvedActivePenPresetIndex: Int {
        let presets = resolvedPenPresets
        if let idx = activePenPresetIndex, idx >= 0, idx < presets.count {
            return idx
        }
        if let match = presets.firstIndex(where: { $0.color == color && $0.width == width && $0.lineStyle == lineStyle }) {
            return match
        }
        return 0
    }

    /// Switches straight to the pen tool with the saved color, width, and line style of slot `index`.
    mutating func selectPenPreset(at index: Int) {
        var presets = resolvedPenPresets
        guard index >= 0, index < presets.count else { return }
        if penPresets == nil {
            penPresets = presets
        }
        select(.pen)
        pen = .ballpoint
        activePenPresetIndex = index
        let slot = presets[index]
        color = slot.color
        width = slot.width
        lineStyle = slot.lineStyle
        presets[index] = slot
        penPresets = presets
    }

    mutating func updatePenColor(_ newColor: RGBAColor) {
        color = newColor
        syncActivePenPreset()
    }

    mutating func updatePenWidth(_ newWidth: Float) {
        width = newWidth
        syncActivePenPreset()
    }

    mutating func updatePenLineStyle(_ newStyle: StrokeLineStyle) {
        lineStyle = newStyle
        syncActivePenPreset()
    }

    mutating func resetPenPresetsToDefault() {
        penPresets = Self.defaultPenPresets
        let idx = min(max(0, activePenPresetIndex ?? 0), Self.defaultPenPresets.count - 1)
        activePenPresetIndex = idx
        let slot = Self.defaultPenPresets[idx]
        color = slot.color
        width = slot.width
        lineStyle = slot.lineStyle
    }

    private mutating func syncActivePenPreset() {
        guard kind == .pen else { return }
        var presets = resolvedPenPresets
        let idx = resolvedActivePenPresetIndex
        presets[idx] = PenPreset(id: idx, color: color, width: width, lineStyle: lineStyle)
        penPresets = presets
        activePenPresetIndex = idx
    }

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
