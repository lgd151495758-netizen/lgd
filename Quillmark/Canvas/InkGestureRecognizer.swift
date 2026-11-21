import UIKit
import UIKit.UIGestureRecognizerSubclass

protocol InkInputDelegate: AnyObject {
    func inkBegan(_ touch: UITouch, event: UIEvent?)
    func inkMoved(_ touch: UITouch, event: UIEvent?)
    func inkEnded(_ touch: UITouch, event: UIEvent?)
    func inkCancelled()
    func inkEstimatedPropertiesUpdated(_ touch: UITouch)
}

/// Tracks a single drawing touch. By default only Apple Pencil draws; fingers keep scrolling
/// and zooming the page. With finger drawing on, one finger draws and a second finger cancels
/// the stroke so the user can pan/zoom.
///
/// Explicitly refuses to be prevented by system/WebKit gesture recognizers so fast strokes are
/// never hijacked or cancelled mid-flight.
final class InkGestureRecognizer: UIGestureRecognizer {
    weak var inkDelegate: InkInputDelegate?

    var allowsFingerDrawing = false {
        didSet { updateAllowedTouchTypes() }
    }

    private var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        updateAllowedTouchTypes()
    }

    private func updateAllowedTouchTypes() {
        var types = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if allowsFingerDrawing {
            types.append(NSNumber(value: UITouch.TouchType.direct.rawValue))
        }
        allowedTouchTypes = types
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if let tracked = trackedTouch, tracked.type == .pencil {
            return true
        }
        return allowsFingerDrawing
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked = trackedTouch {
            // If UIKit hasn't called reset() after a rapid previous stroke, start fresh cleanly.
            if tracked.phase == .ended || tracked.phase == .cancelled {
                trackedTouch = nil
            } else {
                if tracked.type == .direct, touches.contains(where: { $0.type == .direct }) {
                    trackedTouch = nil
                    inkDelegate?.inkCancelled()
                    state = .cancelled
                    return
                }
                for touch in touches where touch !== tracked {
                    ignore(touch, for: event)
                }
                return
            }
        }
        let fingers = touches.filter { $0.type == .direct }
        if fingers.count > 1 {
            state = .failed
            return
        }
        guard let touch = touches.first(where: { $0.type == .pencil }) ?? touches.first else { return }
        for other in touches where other !== touch {
            ignore(other, for: event)
        }
        trackedTouch = touch
        state = .began
        inkDelegate?.inkBegan(touch, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        state = .changed
        inkDelegate?.inkMoved(touch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        trackedTouch = nil
        inkDelegate?.inkEnded(touch, event: event)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        trackedTouch = nil
        inkDelegate?.inkCancelled()
        state = .cancelled
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        for touch in touches {
            inkDelegate?.inkEstimatedPropertiesUpdated(touch)
        }
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }
}
