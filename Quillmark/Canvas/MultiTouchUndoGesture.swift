import UIKit

extension Notification.Name {
    /// Posted on the main thread when a two-finger undo or three-finger redo gesture triggers,
    /// so `WorkspaceView` can show a subtle iPad-only toast (never projected to students).
    static let quillmarkUndoRedoFeedback = Notification.Name("app.quillmark.undoRedoFeedback")
}

/// Non-intrusive two-finger tap Undo / three-finger tap Redo controller shared across PDF, HTML,
/// and Scratchpad canvases. Strictly finger-only (`UITouch.TouchType.direct`), never interferes
/// with Apple Pencil strokes, two-finger pinch zoom, or two-finger scrolling.
final class MultiTouchUndoGestureController: NSObject, UIGestureRecognizerDelegate {
    private weak var session: DocumentSession?
    private weak var hostView: UIView?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    let twoFingerUndoTap = UITapGestureRecognizer()
    let threeFingerRedoTap = UITapGestureRecognizer()

    /// Optional exclusion check (e.g. skip when touching the floating scratchpad header bar).
    var shouldReceiveTouch: ((UITouch) -> Bool)?

    init(session: DocumentSession) {
        self.session = session
        super.init()
        configure(twoFingerUndoTap, touches: 2, action: #selector(handleTwoFingerUndo))
        configure(threeFingerRedoTap, touches: 3, action: #selector(handleThreeFingerRedo))
        twoFingerUndoTap.require(toFail: threeFingerRedoTap)
    }

    func attach(to view: UIView) {
        hostView = view
        view.addGestureRecognizer(twoFingerUndoTap)
        view.addGestureRecognizer(threeFingerRedoTap)
    }

    private func configure(_ recognizer: UITapGestureRecognizer, touches: Int, action: Selector) {
        recognizer.numberOfTouchesRequired = touches
        recognizer.numberOfTapsRequired = 1
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        recognizer.addTarget(self, action: action)
    }

    @objc private func handleTwoFingerUndo() {
        triggerUndo()
    }

    @objc private func handleThreeFingerRedo() {
        triggerRedo()
    }

    /// Programmatic entry points (also exercised directly in unit tests).
    func triggerUndo() {
        guard let session, session.tool.isMultiFingerUndoEnabled, session.canUndo else { return }
        haptic.impactOccurred()
        session.undo()
        NotificationCenter.default.post(name: .quillmarkUndoRedoFeedback, object: nil, userInfo: ["message": "已撤销"])
    }

    func triggerRedo() {
        guard let session, session.tool.isMultiFingerUndoEnabled, session.canRedo else { return }
        haptic.impactOccurred()
        session.redo()
        NotificationCenter.default.post(name: .quillmarkUndoRedoFeedback, object: nil, userInfo: ["message": "已重做"])
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let session, session.tool.isMultiFingerUndoEnabled else { return false }
        var current = touch.view
        while let v = current {
            if v is UIControl { return false }
            if v === hostView { break }
            current = v.superview
        }
        if let shouldReceiveTouch, !shouldReceiveTouch(touch) {
            return false
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
