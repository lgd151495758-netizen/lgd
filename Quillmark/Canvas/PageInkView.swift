import UIKit

/// Passive vector ink renderer laid over one PDF page.
/// Committed strokes are vector `CAShapeLayer`s (sharp at any PDF zoom level), organized in three
/// sublayer tiers: 18% shape shading fills → legacy multiply highlighters → opaque pen/shape/tape ink.
///
/// Touch handling and live tool interaction are unified in `EditorViewController`, so this view is
/// non-interactive and never interferes with `PDFView` scrolling/zooming.
final class PageInkView: UIView {
    let pageIndex: Int
    let pageSize: CGSize
    private weak var session: DocumentSession?

    static let highlighterOpacity: Float = 0.6

    /// Strokes temporarily hidden while being moved/edited at 120fps in `EditorViewController`'s live overlay.
    var hiddenStrokeIDs: Set<UUID> = [] {
        didSet {
            guard hiddenStrokeIDs != oldValue else { return }
            sync()
        }
    }

    private let fillContainer = CALayer()
    private let highlightContainer = CALayer()
    private let inkContainer = CALayer()
    private var strokeLayers: [UUID: CAShapeLayer] = [:]
    private var fillLayers: [UUID: CAShapeLayer] = [:]
    private var renderedStrokes: [UUID: InkStroke] = [:]
    private var lastLayoutSize: CGSize = .zero

    init(pageIndex: Int, pageSize: CGSize, session: DocumentSession) {
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false

        layer.addSublayer(fillContainer)
        layer.addSublayer(highlightContainer)
        layer.addSublayer(inkContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var pageScale: CGFloat {
        PageMapping.scale(viewSize: bounds.size, pageSize: pageSize)
    }

    private var pageToView: CGAffineTransform {
        CGAffineTransform(scaleX: pageScale, y: pageScale)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let containers: [CALayer] = [fillContainer, highlightContainer, inkContainer]
        for container in containers {
            container.frame = bounds
        }
        let transform = pageToView
        for (id, shape) in strokeLayers {
            shape.frame = bounds
            if let stroke = renderedStrokes[id] {
                shape.path = stroke.outlinePath(transform: transform, finished: true)
            }
        }
        for (id, fillShape) in fillLayers {
            fillShape.frame = bounds
            if let stroke = renderedStrokes[id] {
                fillShape.path = stroke.fillPath(transform: transform)
            }
        }
        CATransaction.commit()
    }

    /// Brings the shape layers in line with the session's strokes for this page.
    func sync() {
        guard let session else { return }
        let visible = session.strokes(onPage: pageIndex).filter { !hiddenStrokeIDs.contains($0.id) }
        render(visible)
    }

    /// Renders a transient stroke array during live erasing before committing to `DocumentSession`.
    func renderPreview(_ strokes: [InkStroke]) {
        let visible = strokes.filter { !hiddenStrokeIDs.contains($0.id) }
        render(visible)
    }

    private func render(_ strokes: [InkStroke]) {
        let ids = Set(strokes.map(\.id))
        let transform = pageToView

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in Array(strokeLayers.keys) where !ids.contains(id) {
            strokeLayers[id]?.removeFromSuperlayer()
            strokeLayers[id] = nil
            fillLayers[id]?.removeFromSuperlayer()
            fillLayers[id] = nil
            renderedStrokes[id] = nil
        }
        var fillIdx = 0
        var highlightIdx = 0
        var inkIdx = 0
        for stroke in strokes {
            let shape: CAShapeLayer
            if let existing = strokeLayers[stroke.id] {
                shape = existing
            } else {
                shape = CAShapeLayer()
                shape.frame = bounds
                shape.fillRule = .nonZero
                strokeLayers[stroke.id] = shape
            }
            if renderedStrokes[stroke.id] != stroke {
                Self.applyAppearance(highlighter: stroke.isHighlighter, tape: stroke.isTape,
                                     revealed: stroke.isRevealed, color: stroke.color, to: shape)
                shape.path = stroke.outlinePath(transform: transform, finished: true)

                if let fillColor = stroke.fillColor, let fillPath = stroke.fillPath(transform: transform) {
                    let fl = fillLayers[stroke.id] ?? {
                        let layer = CAShapeLayer()
                        layer.frame = bounds
                        layer.fillRule = .nonZero
                        layer.opacity = 0.18
                        fillLayers[stroke.id] = layer
                        return layer
                    }()
                    fl.frame = bounds
                    fl.fillColor = fillColor.cgColor
                    fl.path = fillPath
                } else if let oldFill = fillLayers.removeValue(forKey: stroke.id) {
                    oldFill.removeFromSuperlayer()
                }
                renderedStrokes[stroke.id] = stroke
            }
            if let fl = fillLayers[stroke.id] {
                Self.ensureLayer(fl, in: fillContainer, at: fillIdx)
                fillIdx += 1
            }
            if stroke.isHighlighter {
                Self.ensureLayer(shape, in: highlightContainer, at: highlightIdx)
                highlightIdx += 1
            } else {
                Self.ensureLayer(shape, in: inkContainer, at: inkIdx)
                inkIdx += 1
            }
        }
        CATransaction.commit()
    }

    /// Inserts or repositions `layer` only when its z-order actually differs, avoiding CoreAnimation
    /// layer-tree churn for hundreds of untouched strokes during precise erasing.
    private static func ensureLayer(_ layer: CALayer, in container: CALayer, at index: Int) {
        if let sublayers = container.sublayers, index < sublayers.count, sublayers[index] === layer {
            return
        }
        container.insertSublayer(layer, at: UInt32(index))
    }

    private static func applyAppearance(highlighter: Bool, tape: Bool = false, revealed: Bool = false,
                                        color: RGBAColor, to shape: CAShapeLayer) {
        shape.fillColor = color.cgColor
        if highlighter {
            shape.opacity = highlighterOpacity
            shape.compositingFilter = "multiplyBlendMode"
            shape.strokeColor = nil
            shape.lineDashPattern = nil
        } else if tape {
            shape.opacity = revealed ? 0.16 : 0.96
            shape.compositingFilter = nil
            shape.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
            shape.lineWidth = 1
            shape.lineDashPattern = [5, 3]
        } else {
            shape.opacity = 1
            shape.compositingFilter = nil
            shape.strokeColor = nil
            shape.lineDashPattern = nil
        }
    }
}
