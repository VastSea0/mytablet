// Diagnostic window for the MyTablet display: 60fps motion plus a log of every input event AppKit receives.
// usage: TouchLab <logfile> [--animate]
import AppKit
let args = CommandLine.arguments
let logURL = URL(fileURLWithPath: args[1]); FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logH = try! FileHandle(forWritingTo: logURL)
func log(_ s: String) { logH.write(Data((s + "\n").utf8)) }
final class V: NSView {
    var x: CGFloat = 0; var animate = args.contains("--animate")
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ r: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSColor.systemRed.setFill(); NSRect(x: x, y: 40, width: 60, height: 60).fill()
        let t = "Keskinlik testi: The quick brown fox — 0123456789 — şğıİçöü — il1| O0"
        for (i, s) in [10, 11, 12, 13, 15, 18].enumerated() {
            (t as NSString).draw(at: NSPoint(x: 20, y: 500 - i * 34), withAttributes: [.font: NSFont.systemFont(ofSize: CGFloat(s)), .foregroundColor: NSColor.black])
        }
    }
    func e(_ n: String, _ ev: NSEvent, _ x: String = "") { log("\(n) \(Int(ev.locationInWindow.x)),\(Int(ev.locationInWindow.y)) clicks=\((ev.type == .leftMouseDown || ev.type == .leftMouseUp) ? ev.clickCount : 0) \(x)") }
    override func mouseDown(with ev: NSEvent) { e("leftDown", ev) }
    override func mouseUp(with ev: NSEvent) { e("leftUp", ev) }
    override func mouseDragged(with ev: NSEvent) { e("leftDrag", ev) }
    override func rightMouseDown(with ev: NSEvent) { e("rightDown", ev) }
    override func rightMouseUp(with ev: NSEvent) { e("rightUp", ev) }
    override func scrollWheel(with ev: NSEvent) { e("scroll", ev, "dx=\(ev.scrollingDeltaX) dy=\(ev.scrollingDeltaY) precise=\(ev.hasPreciseScrollingDeltas) phase=\(ev.phase.rawValue) mom=\(ev.momentumPhase.rawValue) inverted=\(ev.isDirectionInvertedFromDevice)") }
    override func magnify(with ev: NSEvent) { e("magnify", ev, "m=\(ev.magnification) phase=\(ev.phase.rawValue)") }
    override func rotate(with ev: NSEvent) { e("rotate", ev, "r=\(ev.rotation) phase=\(ev.phase.rawValue)") }
}
let app = NSApplication.shared; app.setActivationPolicy(.regular)
let screen = NSScreen.screens.first { $0.localizedName.contains("MyTablet") }!
let w = NSWindow(contentRect: screen.frame.insetBy(dx: 40, dy: 40), styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
w.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 30), display: true)
let v = V(); w.contentView = v; w.title = "TouchLab"; w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v); app.activate(ignoringOtherApps: true)
log("ready screen=\(screen.frame) backing=\(screen.backingScaleFactor) win=\(w.frame) contentH=\(v.bounds.height)")
if v.animate { Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { _ in v.x = (v.x + 5).truncatingRemainder(dividingBy: v.bounds.width - 60); v.needsDisplay = true } }
app.run()
