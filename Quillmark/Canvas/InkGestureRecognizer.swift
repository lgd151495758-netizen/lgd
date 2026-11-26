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
        didSet {
            guard allowsFingerDrawing != oldValue else { return }
            updateAllowedTouchTypes()
        }
    }

    private var trackedTouch: UITouch?

    /// Returns `true` for scroll-view pan/pinch and WebKit deferring recognizers that must never
    /// be prevented or deadlocked by `InkGestureRecognizer`.
    static func isScrollOrZoomGesture(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer is UIPinchGestureRecognizer {
            return true
        }
        if recognizer is UIPanGestureRecognizer, recognizer.view is UIScrollView {
            return true
        }
        let typeName = String(describing: type(of: recognizer))
        if typeName.contains("Pinch") || typeName.contains("Deferring") {
            return true
        }
        return false
    }

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
        if allowedTouchTypes != types {
            allowedTouchTypes = types
        }
    }

    /// Cancels any stale or in-flight stroke when the hosting tab deactivates or hides.
    func cancelIfActive() {
        guard trackedTouch != nil || state == .began || state == .changed else { return }
        trackedTouch = nil
        inkDelegate?.inkCancelled()
        if state == .began || state == .changed {
            state = .cancelled
        } else {
            isEnabled = false
            isEnabled = true
        }
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Never prevent scroll-view pan/pinch recognizers:
        // - In Apple Pencil mode, pan/pinch ignore `.pencil` via `allowedTouchTypes`, so leaving
        //   them unblocked guarantees a stale or overlapping Pencil touch can never break zoom.
        // - In Finger Drawing mode, pan requires 2 fingers and pinch requires 2 fingers, so
        //   1-finger drawing never scrolls while 2-finger pinch (whose fingers land ~15ms apart)
        //   stays alive instead of being killed when Finger 1 lands first.
        if Self.isScrollOrZoomGesture(preventedGestureRecognizer) {
            return false
        }
        if let tracked = trackedTouch, tracked.type == .pencil {
            return true
        }
        return allowsFingerDrawing
    }

    private func activeDirectFingerCount(in event: UIEvent) -> Int {
        guard let allTouches = event.allTouches else { return 0 }
        return allTouches.reduce(into: 0) { count, touch in
            if touch.type == .direct, touch.phase != .ended, touch.phase != .cancelled {
                count += 1
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked = trackedTouch {
            // If UIKit hasn't called reset() after a rapid previous stroke, start fresh cleanly.
            if tracked.phase == .ended || tracked.phase == .cancelled {
                trackedTouch = nil
            } else {
                if tracked.type == .direct,
                   touches.contains(where: { $0.type == .direct }) || activeDirectFingerCount(in: event) >= 2 {
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
        let hasPencil = touches.contains(where: { $0.type == .pencil })
        let fingers = touches.filter { $0.type == .direct }
        if !hasPencil && (fingers.count > 1 || activeDirectFingerCount(in: event) > 1) {
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
        if touch.type == .direct, activeDirectFingerCount(in: event) >= 2 {
            trackedTouch = nil
            inkDelegate?.inkCancelled()
            state = .cancelled
            return
        }
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
