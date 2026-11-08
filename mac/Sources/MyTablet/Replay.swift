import AppKit
/// Test aid: feeds a recorded touch script through the gesture engine.
/// Line format: `<delay-seconds> <action> <actionID> <id:x:y> ...`
enum Replay {
    static func run(_ path: String, into g: GestureEngine) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        HitTest.onlyOwner = [ProcessInfo.processInfo.environment["MYTABLET_ONLY"] ?? "TouchLab"]
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 7)
            // Simulates someone using the Mac throughout: steady typing and pointer movement on the built-in display.
            var typed = 0, macBusy = ProcessInfo.processInfo.environment["MYTABLET_MACBUSY"] != nil
            if macBusy { Thread.detachNewThread {
                var x = 300.0
                while macBusy {
                    for d in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 38, keyDown: d)?.post(tap: .cghidEventTap) }
                    typed += 1
                    x = x > 700 ? 300 : x + 3
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: 400), mouseButton: .left)?.post(tap: .cghidEventTap)
                    Thread.sleep(forTimeInterval: 0.05)
                }
            } }
            let before = CGEvent(source: nil)?.location ?? .zero, front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            defer {
                Thread.sleep(forTimeInterval: 1.5)
                macBusy = false
                Log.write("typed \(typed)")
                Log.write("replay-end cursor \(before) -> \(CGEvent(source: nil)?.location ?? .zero) front \(front) -> \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            }
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ")
                guard f.count >= 3, let d = Double(f[0]), let a = Int(f[1]), let i = Int(f[2]) else { continue }
                Thread.sleep(forTimeInterval: d)
                if a == 9, let pid = g.focused?.pid { // type the key code in `actionID` to the tablet-focused app
                    for down in [true, false] { if let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(i), keyDown: down) { BackgroundInput.key(e, pid: pid) } }
                    continue
                }
                let pts = f[3...].map { s -> TouchPoint in
                    let p = s.split(separator: ":"); return TouchPoint(id: Int(p[0])!, x: Double(p[1])!, y: Double(p[2])!)
                }
                g.handle(TouchEvent(action: a, actionID: i, points: pts))
            }
        }
    }
}
