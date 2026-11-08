import ApplicationServices
import CoreGraphics
import CPrivate
import Foundation

/// All synthetic input leaves through here.
final class Injector {
    private let src = CGEventSource(stateID: .hidSystemState)
    private var remX = 0.0, remY = 0.0

    func move(_ p: CGPoint) { CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }

    func mouse(_ t: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }

    enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, mayBegin = 128 }
    enum MomentumPhase: Int64 { case none = 0, begin = 1, cont = 2, end = 3 }

    /// Deltas follow the finger, in points: +y moves content down.
    func scroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase = .none) {
        let tx = dx + remX, ty = dy + remY
        let ix = tx.rounded(), iy = ty.rounded()
        remX = tx - ix; remY = ty - iy
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(iy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(ix))
        e.post(tap: .cghidEventTap)
    }

    func magnify(at p: CGPoint, delta: Double, phase: Int32) { MTPostGesture(p, .magnify, delta, phase) }
    func rotate(at p: CGPoint, degrees: Double, phase: Int32) { MTPostGesture(p, .rotate, degrees, phase) }

    func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// Decides whether a finger landing at a point should drag (window chrome, sliders) rather than scroll.
enum HitTest {
    private static let system: AXUIElement = {
        let s = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(s, 0.05); return s
    }()
    private static let dragRoles: Set<String> = ["AXSlider", "AXSplitter", "AXScrollBar", "AXValueIndicator", "AXIncrementor", "AXColorWell"]

    static func wantsDrag(at p: CGPoint) -> Bool {
        if inTitleBar(p) { return true }
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success, var cur = el else { return false }
        for _ in 0..<5 {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &v) == .success,
               let r = v as? String, dragRoles.contains(r) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success, let par = parent else { break }
            cur = par as! AXUIElement
        }
        return false
    }

    private static func inTitleBar(_ p: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let h = b["Height"] else { continue }
            if CGRect(x: x, y: y, width: width, height: h).contains(p) { return p.y - y < 28 }
        }
        return false
    }
}
