import Foundation

enum Adb {
    static let path: String = {
        let c = NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        return FileManager.default.isExecutableFile(atPath: c) ? c : "/opt/homebrew/bin/adb"
    }()
    @discardableResult static func run(_ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = o
        do { try p.run() } catch { return (-1, "\(error)") }
        let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
    static var connected: Bool {
        run(["devices"]).1.split(separator: "\n").dropFirst().contains { $0.hasSuffix("device") }
    }
    /// Installs the bundled receiver when its hash differs from what's on the tablet.
    static func ensureInstalled() {
        guard let apk = Bundle.main.url(forResource: "MyTabletReceiver", withExtension: "apk"),
              let data = try? Data(contentsOf: apk) else { Log.write("bundled apk missing"); return }
        let sum = data.reduce(into: UInt64(14695981039346656037)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }
        let tag = String(sum, radix: 16)
        if run(["shell", "cat /data/local/tmp/mytablet.tag 2>/dev/null"]).1.trimmingCharacters(in: .whitespacesAndNewlines) == tag,
           run(["shell", "pm path dev.mytablet"]).1.contains("package:") { return }
        let r = run(["install", "-r", "-g", apk.path]); Log.write("adb install: \(r.1)")
        run(["shell", "echo \(tag) > /data/local/tmp/mytablet.tag"])
    }
    static func launchReceiver(port: UInt16) {
        run(["forward", "tcp:\(port)", "tcp:\(port)"])
        run(["shell", "input keyevent KEYCODE_WAKEUP; am start -n dev.mytablet/.MainActivity"])
    }
}
