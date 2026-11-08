import AppKit
import ApplicationServices
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A real window currently on the tablet display.
struct TabletWindow { let id: CGWindowID; let pid: pid_t; let app: String; let title: String; let frame: CGRect }

/// Finds, places, raises and closes real app windows, limited to the tablet display.
enum Windows {
    static func onTablet(_ display: CGRect) -> [TabletWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [TabletWindow] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let num = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"],
                  wd > 120, h > 80, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { continue }
            let f = CGRect(x: x, y: y, width: wd, height: h)
            guard display.contains(CGPoint(x: f.midX, y: f.midY)) else { continue }
            out.append(TabletWindow(id: num, pid: pid, app: w[kCGWindowOwnerName as String] as? String ?? "",
                                    title: w[kCGWindowName as String] as? String ?? "", frame: f))
        }
        return out
    }

    private static func axWindows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private static func element(for w: TabletWindow) -> AXUIElement? {
        axWindows(w.pid).first { var i: CGWindowID = 0; return _AXUIElementGetWindow($0, &i) == .success && i == w.id }
    }

    static func raise(_ w: TabletWindow) {
        guard let el = element(for: w) else { return }
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    private static func element(_ t: InputTarget) -> AXUIElement? {
        axWindows(t.pid).first { var i: CGWindowID = 0; return _AXUIElementGetWindow($0, &i) == .success && i == t.window }
    }

    static func origin(_ t: InputTarget) -> CGPoint? { element(t).flatMap(frame(of:))?.origin }

    static func move(_ t: InputTarget, to p: CGPoint) {
        var o = p
        guard let el = element(t), let v = AXValueCreate(.cgPoint, &o) else { return }
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
    }

    static func close(_ w: TabletWindow) {
        guard let el = element(for: w) else { return }
        var b: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXCloseButtonAttribute as CFString, &b) == .success, let btn = b {
            AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
        }
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// iPadOS 26 windowing: a new window keeps its own size, fits on screen, and cascades over the others.
    private static func arrange(_ el: AXUIElement, area: CGRect, cascade: Int) {
        guard let f = frame(of: el) else { return }
        var size = CGSize(width: min(f.width, area.width * 0.92), height: min(f.height, area.height * 0.92))
        if let z = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, z) }
        let actual = frame(of: el)?.size ?? size
        let step = CGFloat(cascade % 6) * 26
        var o = CGPoint(x: area.midX - actual.width / 2 + step - 26, y: max(area.minY + 8, area.midY - actual.height / 2 + step - 26))
        if let p = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, p) }
    }

    /// Waits for the app's window and brings it to the tablet. A window already there is left where it is.
    static func adopt(pid: pid_t, display: CGRect, area: CGRect, cascade: Int, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<50 {
                let ws = axWindows(pid)
                if let here = ws.first(where: { frame(of: $0).map { display.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false }) {
                    AXUIElementPerformAction(here, kAXRaiseAction as CFString)
                    DispatchQueue.main.async(execute: completion); return
                }
                if let first = ws.first {
                    arrange(first, area: area, cascade: cascade)
                    AXUIElementPerformAction(first, kAXRaiseAction as CFString)
                    DispatchQueue.main.async(execute: completion); return
                }
                Thread.sleep(forTimeInterval: 0.12)
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func thumbnail(_ w: TabletWindow) async -> CGImage? {
        guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let sw = c.windows.first(where: { $0.windowID == w.id }) else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(w.frame.width); cfg.height = Int(w.frame.height); cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: sw), configuration: cfg)
    }

    /// True when the given app's focused element takes text. Asked per app because the Mac's focus is elsewhere.
    static func textFocused(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.15)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success, let raw = v else { return false }
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(raw as! AXUIElement, kAXRoleAttribute as CFString, &r) == .success, let role = r as? String else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
}
