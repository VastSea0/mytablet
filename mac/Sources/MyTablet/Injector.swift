import ApplicationServices
import CoreGraphics
import CPrivate
import Foundation

/// The window under a finger, which is also the tablet's own notion of keyboard focus.
struct InputTarget { let pid: pid_t; let window: CGWindowID }

/// All synthetic input leaves through here.
///
/// macOS has one pointer and drops mouse events posted to a specific process (measured on macOS 27:
/// clicks, scrolls and gestures via CGEventPostToPid never arrive). So instead of moving the pointer
/// for a whole touch, each discrete action teleports it to the finger and back:
/// about 0.3 ms for a scroll event, about 10 ms for a click. Only continuous drags and pinches, which
/// WindowServer routes by the live pointer position, hold it for their duration.
final class Injector {
    private let src = CGEventSource(stateID: .hidSystemState)
    private var remX = 0.0, remY = 0.0
    /// True while a drag or pinch keeps the pointer on the tablet.
    var holdingPointer = false

    /// The tablet's bounds; set by the gesture engine.
    var tabletFrame = CGRect.zero
    private var lastHome: CGPoint?

    /// Where the Mac's pointer belongs. Reading the live position mid-hop can return the tablet
    /// position, so while it's on the tablet the last position seen on the Mac wins.
    private var pointer: CGPoint {
        let c = CGEvent(source: nil)?.location ?? .zero
        if !tabletFrame.contains(c) { lastHome = c }
        return lastHome ?? c
    }

    /// A posted move, not CGWarpMouseCursorPosition: a warp suppresses input for 250 ms,
    /// which would drop the next touch and freeze the Mac's own trackpad.
    private func warp(_ p: CGPoint) { move(p) }

    func move(_ p: CGPoint) { CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }

    func mouse(_ t: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
        guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.post(tap: .cghidEventTap)
    }

    /// A complete click that hands the pointer straight back.
    func click(_ p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
        let home = pointer
        move(p)
        usleep(4000) // WindowServer needs a beat at the new position or it drops the press
        mouse(button == .left ? .leftMouseDown : .rightMouseDown, p, button: button, clicks: clicks)
        mouse(button == .left ? .leftMouseUp : .rightMouseUp, p, button: button, clicks: clicks)
        usleep(4000)
        if !holdingPointer { warp(home) }
    }

    /// Takes the pointer for a continuous gesture; `release` gives it back.
    private var heldFrom: CGPoint?
    func hold(at p: CGPoint) {
        if !holdingPointer { heldFrom = pointer }
        holdingPointer = true
        move(p)
        usleep(16000) // gestures route by the settled pointer position
    }
    func release() {
        holdingPointer = false
        if let h = heldFrom { warp(h); heldFrom = nil }
    }

    enum ScrollPhase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, mayBegin = 128 }
    enum MomentumPhase: Int64 { case none = 0, begin = 1, cont = 2, end = 3 }

    /// Deltas follow the finger, in points: +y moves content down.
    func scroll(at p: CGPoint, dx: Double, dy: Double, phase: ScrollPhase, momentum: MomentumPhase = .none) {
        let tx = dx + remX, ty = dy + remY
        let ix = tx.rounded(), iy = ty.rounded()
        remX = tx - ix; remY = ty - iy
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.location = p
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(iy))
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(ix))
        if holdingPointer { e.post(tap: .cghidEventTap); return }
        let home = pointer
        e.post(tap: .cghidEventTap)
        warp(home)
    }

    func magnify(at p: CGPoint, delta: Double, phase: Int32) { MTPostGesture(p, .magnify, delta, phase) }
    func rotate(at p: CGPoint, degrees: Double, phase: Int32) { MTPostGesture(p, .rotate, degrees, phase) }
}

enum DragKind { case none, moveWindow, control }

enum HitTest {
    private static let system: AXUIElement = {
        let s = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(s, 0.05); return s
    }()
    private static let dragRoles: Set<String> = ["AXSlider", "AXSplitter", "AXScrollBar", "AXValueIndicator", "AXIncrementor", "AXColorWell"]
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText", "AXWebArea"]
    /// True when the app has a menu open, which reactivating another app would dismiss.
    static func hasOpenMenu(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) >= 101 }
    }

    private static let systemOwners: Set<String> = ["Window Server", "WindowServer", "Dock", "SystemUIServer", "Control Center", "ControlCenter"]

    private struct Win { let id: CGWindowID; let pid: pid_t; let layer: Int; let owner: String; let frame: CGRect }

    private static func windows(at p: CGPoint) -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let layer = w[kCGWindowLayer as String] as? Int, layer < 1000,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"] else { return nil }
            let f = CGRect(x: x, y: y, width: wd, height: h)
            return f.contains(p) ? Win(id: id, pid: pid, layer: layer, owner: w[kCGWindowOwnerName as String] as? String ?? "", frame: f) : nil
        }
    }

    /// Replay safety: when set, only this owner's windows can ever receive input.
    static var onlyOwner: String?

    /// Topmost app-owned window at a point, or nil when it's system UI that only the real pointer can drive.
    static func target(at p: CGPoint) -> InputTarget? {
        for w in windows(at: p) {
            // The Dock keeps a transparent display-sized window; only its small visible bar is real UI.
            if w.owner == "Dock" && w.frame.height > 200 { continue }
            if let only = onlyOwner { return w.owner == only ? InputTarget(pid: w.pid, window: w.id) : nil }
            return systemOwners.contains(w.owner) ? nil : InputTarget(pid: w.pid, window: w.id)
        }
        return nil
    }

    static func dragKind(at p: CGPoint) -> DragKind {
        if let w = windows(at: p).first(where: { $0.layer == 0 }), p.y - w.frame.minY < 28 { return .moveWindow }
        return roleChain(at: p).contains(where: dragRoles.contains) ? .control : .none
    }

    static func isText(at p: CGPoint) -> Bool { roleChain(at: p).contains(where: textRoles.contains) }

    private static func roleChain(at p: CGPoint) -> [String] {
        var el: AXUIElement?, out: [String] = []
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success, var cur = el else { return [] }
        for _ in 0..<5 {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &v) == .success, let r = v as? String { out.append(r) }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success, let par = parent else { break }
            cur = par as! AXUIElement
        }
        return out
    }
}
