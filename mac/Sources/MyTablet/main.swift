import AppKit
import ApplicationServices
import CoreGraphics

final class AppController: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var display: VirtualDisplay?
    private var session: Session?
    private var shell: Shell?
    private var layoutIndex = 0
    private let stateItem = NSMenuItem(title: "Başlatılıyor…", action: nil, keyEquivalent: "")
    private let statsItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
    private var layoutItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "MyTablet")
        let m = NSMenu()
        m.addItem(stateItem); m.addItem(statsItem); m.addItem(.separator())
        for (i, l) in DisplayLayout.all.enumerated() {
            let it = NSMenuItem(title: l.name, action: #selector(pick(_:)), keyEquivalent: "")
            it.tag = i; it.target = self; it.state = i == layoutIndex ? .on : .off
            m.addItem(it); layoutItems.append(it)
        }
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
        item.menu = m

        requestPermissions()
        let d = VirtualDisplay(layout: DisplayLayout.all[layoutIndex])
        display = d
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.startSession() }
    }

    private func requestPermissions() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opt) { Log.write("accessibility not granted") }
    }

    private func startSession() {
        guard let d = display else { return }
        let s = Session(layout: DisplayLayout.all[layoutIndex])
        s.onState = { [weak self] t in DispatchQueue.main.async { self?.stateItem.title = t } }
        s.onStats = { [weak self] st in
            let line = "\(st.fps) fps · \(st.kbps / 1000) Mb/s · \(String(format: "%.0f", st.latencyMs)) ms"
            DispatchQueue.main.async { self?.statsItem.title = line }
            Log.write("stats fps=\(st.fps) mbps=\(st.kbps / 1000) latency=\(st.latencyMs) rtt=\(st.rttMs) skipped=\(st.skipped) ax=\(AXIsProcessTrusted())")
        }
        session = s
        let sh = Shell(displayID: d.id)
        shell = sh
        let testing = ProcessInfo.processInfo.environment["MYTABLET_REPLAY"] != nil // replays target windows directly, no shell on top
        if !testing { sh.start() }
        if !testing { s.gestures.shellCaptures = { [weak sh] p, h in sh?.captures(p, height: h) ?? false } }
        s.gestures.shellHandle = { [weak sh] e in DispatchQueue.main.async { sh?.handle(e) } }
        s.gestures.onSystemGesture = { [weak sh] g in DispatchQueue.main.async { sh?.system(g) } }
        s.gestures.onTap = { [weak sh] t in sh?.tappedInApp(t) }
        sh.passTap = { [weak s] p in s?.gestures.forwardTap(p) }
        s.start(display: d)
        if let path = ProcessInfo.processInfo.environment["MYTABLET_REPLAY"] { Replay.run(path, into: s.gestures) }
    }

    @objc private func pick(_ s: NSMenuItem) {
        layoutIndex = s.tag
        for (i, it) in layoutItems.enumerated() { it.state = i == layoutIndex ? .on : .off }
        display?.apply(DisplayLayout.all[layoutIndex])
        session?.gestures.setFrame(display?.bounds ?? .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.session?.gestures.setFrame(self?.display?.bounds ?? .zero)
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        session?.stop()
        _ = Adb.run(["shell", "am force-stop dev.mytablet"])
    }
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
