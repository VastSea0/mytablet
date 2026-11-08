import AppKit
/// Test aid: feeds a recorded touch script through the gesture engine.
/// Line format: `<delay-seconds> <action> <actionID> <id:x:y> ...`
enum Replay {
    static func run(_ path: String, into g: GestureEngine) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        HitTest.onlyOwner = "TouchLab"
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 7)
            let before = CGEvent(source: nil)?.location ?? .zero, front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            defer {
                Thread.sleep(forTimeInterval: 1.5)
                Log.write("replay-end cursor \(before) -> \(CGEvent(source: nil)?.location ?? .zero) front \(front) -> \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            }
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ")
                guard f.count >= 3, let d = Double(f[0]), let a = Int(f[1]), let i = Int(f[2]) else { continue }
                Thread.sleep(forTimeInterval: d)
                if a == 9, let pid = g.focused?.pid { // type the key code in `actionID` to the tablet-focused app
                    for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(i), keyDown: down)?.postToPid(pid) }
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
