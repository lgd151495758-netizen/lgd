import UIKit

/// Transparent ink layer laid over one PDF page.
/// Committed strokes are vector `CAShapeLayer`s (they stay sharp when the page is zoomed);
/// the stroke being drawn lives in `liveLayer` and includes Apple Pencil predicted points.
final class PageInkView: UIView, InkInputDelegate {
    let pageIndex: Int
    let pageSize: CGSize
    private weak var session: DocumentSession?

    private let inkRecognizer = InkGestureRecognizer(target: nil, action: nil)
    private let liveLayer = CAShapeLayer()
    private var strokeLayers: [UUID: CAShapeLayer] = [:]
    private var renderedStrokes: [UUID: InkStroke] = [:]
    private var lastLayoutSize: CGSize = .zero

    private var livePoints: [InkPoint] = []
    private var liveTool = ToolSettings()
    private var liveStartTime: TimeInterval = 0
    /// estimationUpdateIndex -> index into the stroke's points, for force values that arrive later.
    private var pendingEstimates: [NSNumber: Int] = [:]
    private var lastCommitted: (id: UUID, points: [InkPoint])?

    init(pageIndex: Int, pageSize: CGSize, session: DocumentSession) {
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        liveLayer.fillRule = .nonZero
        layer.addSublayer(liveLayer)
        inkRecognizer.inkDelegate = self
        addGestureRecognizer(inkRecognizer)
        updateInputMode(fingerDrawing: session.tool.fingerDrawing)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var pageToView: CGAffineTransform {
        let s = PageMapping.scale(viewSize: bounds.size, pageSize: pageSize)
        return CGAffineTransform(scaleX: s, y: s)
    }

    func updateInputMode(fingerDrawing: Bool) {
        inkRecognizer.allowsFingerDrawing = fingerDrawing
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.frame = bounds
        let transform = pageToView
        for (id, shape) in strokeLayers {
            shape.frame = bounds
            if let stroke = renderedStrokes[id] {
                shape.path = stroke.outlinePath(transform: transform)
            }
        }
        CATransaction.commit()
    }

    /// Brings the shape layers in line with the session's strokes for this page.
    func sync() {
        guard let session else { return }
        let strokes = session.strokes(onPage: pageIndex)
        let ids = Set(strokes.map(\.id))
        let transform = pageToView

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in Array(strokeLayers.keys) where !ids.contains(id) {
            strokeLayers[id]?.removeFromSuperlayer()
            strokeLayers[id] = nil
            renderedStrokes[id] = nil
        }
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
                shape.fillColor = stroke.color.cgColor
                shape.path = stroke.outlinePath(transform: transform)
                renderedStrokes[stroke.id] = stroke
            }
            // Re-inserting keeps z-order equal to stroke order, below the live stroke.
            layer.insertSublayer(shape, below: liveLayer)
        }
        CATransaction.commit()
    }

    // MARK: Input

    func inkBegan(_ touch: UITouch, event: UIEvent?) {
        guard let session else { return }
        liveTool = session.tool
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        lastCommitted = nil
        liveStartTime = touch.timestamp
        append(event?.coalescedTouches(for: touch) ?? [touch])
        updateLiveStroke(predicted: [])
    }

    func inkMoved(_ touch: UITouch, event: UIEvent?) {
        append(event?.coalescedTouches(for: touch) ?? [touch])
        let predicted = liveTool.prediction ? (event?.predictedTouches(for: touch) ?? []) : []
        updateLiveStroke(predicted: predicted)
    }

    func inkEnded(_ touch: UITouch, event: UIEvent?) {
        append(event?.coalescedTouches(for: touch) ?? [touch])
        commitLiveStroke()
    }

    func inkCancelled() {
        livePoints.removeAll()
        pendingEstimates.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = nil
        CATransaction.commit()
    }

    func inkEstimatedPropertiesUpdated(_ touch: UITouch) {
        guard let updateIndex = touch.estimationUpdateIndex, let pointIndex = pendingEstimates[updateIndex] else { return }
        let force = forceValue(touch)
        if !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
            pendingEstimates[updateIndex] = nil
        }
        if var committed = lastCommitted {
            guard pointIndex < committed.points.count else { return }
            committed.points[pointIndex].force = force
            lastCommitted = committed
            session?.refineStroke(id: committed.id, page: pageIndex, points: committed.points)
        } else if pointIndex < livePoints.count {
            livePoints[pointIndex].force = force
        }
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        super.touchesEstimatedPropertiesUpdated(touches)
        for touch in touches {
            inkEstimatedPropertiesUpdated(touch)
        }
    }

    private func append(_ touches: [UITouch]) {
        for touch in touches {
            if let updateIndex = touch.estimationUpdateIndex,
               touch.estimatedPropertiesExpectingUpdates.contains(.force) {
                pendingEstimates[updateIndex] = livePoints.count
            }
            livePoints.append(inkPoint(from: touch))
        }
    }

    private func forceValue(_ touch: UITouch) -> Float {
        PenModel.normalizedForce(raw: touch.force, maximum: touch.maximumPossibleForce, isStylus: touch.type == .pencil)
    }

    private func inkPoint(from touch: UITouch) -> InkPoint {
        let location = touch.preciseLocation(in: self)
        let scale = PageMapping.scale(viewSize: bounds.size, pageSize: pageSize)
        let isStylus = touch.type == .pencil
        return InkPoint(x: Float(location.x / scale),
                        y: Float(location.y / scale),
                        force: forceValue(touch),
                        azimuth: isStylus ? Float(touch.azimuthAngle(in: self)) : 0,
                        altitude: isStylus ? Float(touch.altitudeAngle) : .pi / 2,
                        t: Float(touch.timestamp - liveStartTime))
    }

    private func makeStroke(points: [InkPoint]) -> InkStroke {
        InkStroke(id: UUID(), pen: liveTool.pen, color: liveTool.color, width: liveTool.width,
                  smoothing: liveTool.smoothing, points: points)
    }

    private func updateLiveStroke(predicted: [UITouch]) {
        guard !livePoints.isEmpty else { return }
        let points = livePoints + predicted.map { inkPoint(from: $0) }
        let stroke = makeStroke(points: points)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.fillColor = stroke.color.cgColor
        liveLayer.path = stroke.outlinePath(transform: pageToView, finished: false)
        CATransaction.commit()
    }

    private func commitLiveStroke() {
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveLayer.path = nil
            CATransaction.commit()
        }
        guard let session, !livePoints.isEmpty else { return }
        let stroke = makeStroke(points: livePoints)
        lastCommitted = (stroke.id, stroke.points)
        livePoints.removeAll(keepingCapacity: true)
        session.addStroke(stroke, page: pageIndex)
    }
}
