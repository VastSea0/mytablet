import AppKit
import CoreWLAN
import IOKit.ps
import QuartzCore
import ScreenCaptureKit

private final class ShellPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(frame: CGRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isReleasedWhenClosed = false
        ignoresMouseEvents = true // tablet touches are routed directly; the Mac's pointer never needs to land here
    }
}

/// The iPadOS-style experience that exists only on the tablet display.
/// It is drawn by ordinary windows on that display and drives real apps; the Mac's own screen is never touched.
final class Shell {
    enum Mode { case home, app, switcher }

    private let displayID: CGDirectDisplayID
    private var screen: NSScreen { NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID } ?? NSScreen.screens[0] }
    private var cgFrame: CGRect { CGDisplayBounds(displayID) }
    private var W: CGFloat { cgFrame.width }; private var H: CGFloat { cgFrame.height }

    private var main: ShellPanel!, dockPanel: ShellPanel!, keyPanel: ShellPanel!, pill: ShellPanel!
    private var root: CALayer!, wallpaper: CALayer!, pagesLayer: CALayer!, dots: CALayer!, switcherLayer: CALayer!
    private var clock: CATextLayer!, statusRight: CATextLayer!, emptyLabel: CATextLayer!
    private var dockRoot: CALayer!
    private var kb: KeyboardView!

    private let stateLock = NSLock()
    private var _mode = Mode.home, _dockRect: CGRect?, _kbRect: CGRect?
    private var mode: Mode {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _mode }
        set { stateLock.lock(); _mode = newValue; stateLock.unlock() }
    }
    private func setRects(dock: CGRect?, kb: CGRect?) { stateLock.lock(); _dockRect = dock; _kbRect = kb; stateLock.unlock() }

    private var apps: [AppEntry] = [], dock: [AppEntry] = []
    private struct Tile { let app: AppEntry; let frame: CGRect; let page: Int; let layer: CALayer }
    private var tiles: [Tile] = []
    private struct DockTile { let app: AppEntry?; let frame: CGRect; let layer: CALayer }
    private var dockTiles: [DockTile] = []
    private var page = 0, pageCount = 1

    private struct Card { let win: TabletWindow; let layer: CALayer; let x: CGFloat }
    private var cards: [Card] = []
    private var switcherOffset: CGFloat = 0
    private let cardSize = CGSize(width: 360, height: 240), cardGap: CGFloat = 36

    private enum Touch { case none, edge(CGPoint, Double), homePan, dock(DockTile?), keyboard, switcherPan, card(Int, CGPoint) }
    private var touch = Touch.none
    private var downPoint = CGPoint.zero, downTime = 0.0, lastPoint = CGPoint.zero, panBase: CGFloat = 0, dragging = false, pressedTile: Tile?

    var passTap: ((CGPoint) -> Void)?
    private var focusPid: pid_t?
    let edgeHeight: CGFloat = 32 // starts above Android's own bottom-edge system gesture band
    private let dockHeight: CGFloat = 96

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    // MARK: lifecycle

    func start() {
        build()
        apps = AppCatalog.installed(); dock = AppCatalog.dockApps()
        layoutAll()
        showHome(animated: false)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.updateStatus() }
        updateStatus()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layoutAll()
        }
    }

    private func build() {
        main = ShellPanel(frame: screen.frame, level: .statusBar)
        let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size)); host.wantsLayer = true
        main.contentView = host
        // AppKit owns the geometry of a view's backing layer, so the top-left-origin scene lives one level down.
        root = CALayer(); root.isGeometryFlipped = true; root.backgroundColor = NSColor.black.cgColor
        host.layer!.addSublayer(root)
        wallpaper = CALayer(); wallpaper.contentsGravity = .resizeAspectFill; root.addSublayer(wallpaper)
        pagesLayer = CALayer(); root.addSublayer(pagesLayer)
        dots = CALayer(); root.addSublayer(dots)
        switcherLayer = CALayer(); switcherLayer.isHidden = true; root.addSublayer(switcherLayer)
        clock = text(16, .semibold); statusRight = text(14, .medium); statusRight.alignmentMode = .right
        root.addSublayer(clock); root.addSublayer(statusRight)
        emptyLabel = text(18, .medium); emptyLabel.alignmentMode = .center; emptyLabel.string = "Açık uygulama yok"; emptyLabel.isHidden = true
        root.addSublayer(emptyLabel)

        dockPanel = ShellPanel(frame: .zero, level: .statusBar + 1)
        let dv = NSVisualEffectView(); dv.material = .hudWindow; dv.state = .active; dv.blendingMode = .behindWindow
        dv.wantsLayer = true; dv.layer?.cornerRadius = 26; dv.layer?.masksToBounds = true
        dockPanel.contentView = dv
        let overlay = CALayer(); overlay.isGeometryFlipped = true; dv.layer?.addSublayer(overlay); dockRoot = overlay

        keyPanel = ShellPanel(frame: .zero, level: .statusBar + 2)
        pill = ShellPanel(frame: .zero, level: .statusBar)
        let pv = NSView(); pv.wantsLayer = true; pv.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor; pv.layer?.cornerRadius = 3
        pill.contentView = pv
    }

    private func text(_ size: CGFloat, _ weight: NSFont.Weight) -> CATextLayer {
        let t = CATextLayer(); t.contentsScale = 2; t.font = NSFont.systemFont(ofSize: size, weight: weight); t.fontSize = size
        t.foregroundColor = NSColor.white.cgColor
        t.shadowOpacity = 0.45; t.shadowRadius = 3; t.shadowOffset = .zero
        return t
    }

    // MARK: layout

    private func layoutAll() {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        main.setFrame(screen.frame, display: true)
        let size = screen.frame.size
        main.contentView?.frame = CGRect(origin: .zero, size: size)
        root.frame = CGRect(origin: .zero, size: size)
        wallpaper.frame = CGRect(origin: .zero, size: size)
        loadWallpaper()
        clock.frame = CGRect(x: 22, y: 9, width: 300, height: 22)
        statusRight.frame = CGRect(x: size.width - 322, y: 10, width: 300, height: 20)
        emptyLabel.frame = CGRect(x: 0, y: size.height / 2 - 12, width: size.width, height: 26)
        layoutHome(size); layoutDock(size); layoutKeyboard(size)
        pill.setFrame(CGRect(x: screen.frame.midX - 70, y: screen.frame.minY + 5, width: 140, height: 6), display: true)
    }

    /// Uses the wallpaper macOS is actually showing on this display. Never blocks the main thread.
    private func loadWallpaper() {
        Task { [weak self] in
            guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
            // Virtual displays get no wallpaper window of their own, so reuse the one macOS renders for the Mac.
            guard let w = c.windows.first(where: { ($0.title ?? "").contains("Wallpaper") && ($0.owningApplication?.bundleIdentifier ?? "") == "com.apple.wallpaper.agent" })
                    ?? c.windows.first(where: { ($0.title ?? "") == "Wallpaper" }) else { Log.write("no wallpaper window"); return }
            let cfg = SCStreamConfiguration(); cfg.width = Int(w.frame.width) * 2; cfg.height = Int(w.frame.height) * 2; cfg.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { Log.write("wallpaper capture failed"); return }
            await MainActor.run { self?.wallpaper.contents = img }
        }
    }

    private func layoutHome(_ size: CGFloat2) {
        pagesLayer.sublayers?.forEach { $0.removeFromSuperlayer() }; tiles = []
        let icon: CGFloat = 76, cellW: CGFloat = 132, cellH: CGFloat = 122
        let top: CGFloat = 52, bottomSpace = dockHeight + 34
        let cols = max(3, Int((size.width - 48) / cellW))
        let rows = max(2, Int((size.height - top - bottomSpace) / cellH))
        let perPage = cols * rows
        pageCount = max(1, Int(ceil(Double(apps.count) / Double(perPage))))
        page = min(page, pageCount - 1)
        let gridW = CGFloat(cols) * cellW, left = (size.width - gridW) / 2
        for (i, a) in apps.enumerated() {
            let p = i / perPage, idx = i % perPage, c = idx % cols, r = idx / cols
            let x = CGFloat(p) * size.width + left + CGFloat(c) * cellW + (cellW - icon) / 2
            let y = top + CGFloat(r) * cellH
            let holder = CALayer(); holder.frame = CGRect(x: x, y: y, width: icon, height: icon)
            holder.contents = a.icon; holder.contentsGravity = .resizeAspect
            holder.shadowOpacity = 0.3; holder.shadowRadius = 5; holder.shadowOffset = CGSize(width: 0, height: 2)
            let label = text(12, .medium); label.alignmentMode = .center; label.truncationMode = .end
            label.string = a.name; label.frame = CGRect(x: -22, y: icon + 6, width: icon + 44, height: 18)
            holder.addSublayer(label)
            pagesLayer.addSublayer(holder)
            tiles.append(Tile(app: a, frame: CGRect(x: x, y: y, width: icon, height: icon), page: p, layer: holder))
        }
        pagesLayer.frame = CGRect(x: -CGFloat(page) * size.width, y: 0, width: size.width * CGFloat(pageCount), height: size.height)
        updateDots(size)
    }

    private func updateDots(_ size: CGFloat2) {
        dots.sublayers?.forEach { $0.removeFromSuperlayer() }
        let n = pageCount, gap: CGFloat = 14
        dots.frame = CGRect(x: 0, y: size.height - dockHeight - 26, width: size.width, height: 10)
        guard n > 1 else { return }
        var x = (size.width - CGFloat(n - 1) * gap) / 2 - 3.5
        for i in 0..<n {
            let d = CALayer(); d.frame = CGRect(x: x, y: 0, width: 7, height: 7); d.cornerRadius = 3.5
            d.backgroundColor = NSColor.white.withAlphaComponent(i == page ? 1 : 0.4).cgColor
            dots.addSublayer(d); x += gap
        }
    }

    private func layoutDock(_ size: CGFloat2) {
        dockRoot.sublayers?.forEach { $0.removeFromSuperlayer() }; dockTiles = []
        let icon: CGFloat = 66, gap: CGFloat = 14, maxApps = max(1, Int((size.width - 180) / (icon + gap)) - 1)
        let shown = Array(dock.prefix(maxApps))
        let width = CGFloat(shown.count + 1) * (icon + gap) + gap + 12
        let f = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY + 14, width: width, height: dockHeight - 14)
        dockPanel.setFrame(f, display: true)
        dockRoot.frame = CGRect(origin: .zero, size: f.size)
        var x = gap
        for a in shown {
            let l = CALayer(); l.frame = CGRect(x: x, y: (f.height - icon) / 2, width: icon, height: icon); l.contents = a.icon; l.contentsGravity = .resizeAspect
            dockRoot.addSublayer(l); dockTiles.append(DockTile(app: a, frame: l.frame, layer: l)); x += icon + gap
        }
        x += 6
        let sep = CALayer(); sep.frame = CGRect(x: x - gap / 2 - 3, y: 16, width: 1, height: f.height - 32); sep.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        dockRoot.addSublayer(sep)
        let kbBtn = CALayer(); kbBtn.frame = CGRect(x: x, y: (f.height - icon) / 2, width: icon, height: icon); kbBtn.cornerRadius = 15
        kbBtn.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        if let sym = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 28, weight: .regular)) {
            let glyph = CALayer(); glyph.frame = CGRect(x: 14, y: 18, width: icon - 28, height: icon - 36); glyph.contentsGravity = .resizeAspect
            glyph.contents = tinted(sym); kbBtn.addSublayer(glyph)
        }
        dockRoot.addSublayer(kbBtn); dockTiles.append(DockTile(app: nil, frame: kbBtn.frame, layer: kbBtn))
    }

    private func tinted(_ i: NSImage) -> CGImage? {
        let out = NSImage(size: i.size, flipped: false) { r in
            i.draw(in: r); NSColor.white.set(); r.fill(using: .sourceIn); return true
        }
        return out.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private var kbSize: CGSize { CGSize(width: screen.frame.width, height: min(250, screen.frame.height * 0.42)) }
    private func layoutKeyboard(_ size: CGFloat2) {
        let f = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: kbSize.width, height: kbSize.height)
        keyPanel.setFrame(f, display: true)
        kb = KeyboardView(frame: CGRect(origin: .zero, size: f.size))
        kb.onDismiss = { [weak self] in self?.setKeyboard(false) }
        kb.targetPid = { [weak self] in self?.focusPid }
        keyPanel.contentView = kb
    }

    private func updateStatus() {
        let df = DateFormatter(); df.locale = Locale(identifier: "tr_TR"); df.dateFormat = "HH:mm  d MMM EEE"
        clock.string = df.string(from: Date())
        var parts: [String] = []
        if let ssid = CWWiFiClient.shared().interface()?.rssiValue(), ssid != 0 { parts.append("Wi-Fi") }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef], let s = list.first,
           let d = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any],
           let c = d[kIOPSCurrentCapacityKey] as? Int {
            parts.append("%\(c)" + ((d[kIOPSIsChargingKey] as? Bool) == true ? " ⚡︎" : ""))
        }
        statusRight.string = parts.joined(separator: "   ")
    }

    // MARK: mode transitions

    private func showHome(animated: Bool) {
        mode = .home
        setDock(true); pill.orderOut(nil); setKeyboard(false)
        switcherLayer.isHidden = true; emptyLabel.isHidden = true
        pagesLayer.isHidden = false; dots.isHidden = false
        present(main, animated: animated)
    }

    private func present(_ w: NSWindow, animated: Bool) {
        w.alphaValue = animated ? 0 : 1
        w.orderFrontRegardless()
        if animated { NSAnimationContext.runAnimationGroup { $0.duration = 0.22; w.animator().alphaValue = 1 } }
    }

    private func enterApp() {
        mode = .app
        setDock(false)
        pill.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; main.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            guard let self, self.mode == .app else { return }
            self.main.orderOut(nil); self.main.alphaValue = 1
        })
    }

    private func setDock(_ on: Bool) {
        if on { dockPanel.orderFrontRegardless() } else { dockPanel.orderOut(nil) }
        publishRects(dock: on)
    }

    private func publishRects(dock: Bool? = nil) {
        let d = (dock ?? dockPanel.isVisible) ? localRect(dockPanel.frame) : nil
        setRects(dock: d, kb: keyPanel.isVisible ? localRect(keyPanel.frame) : nil)
    }

    private func localRect(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX - screen.frame.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
    }

    func setKeyboard(_ on: Bool) {
        if on { kb.refreshLabels(); keyPanel.orderFrontRegardless() } else { keyPanel.orderOut(nil) }
        publishRects()
    }

    // MARK: launching and window control

    private var usableArea: CGRect {
        let f = cgFrame, inset = screen.frame.maxY - screen.visibleFrame.maxY
        return CGRect(x: f.minX, y: f.minY + inset, width: f.width, height: f.height - inset)
    }

    private func launch(_ a: AppEntry) {
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false // never pull focus away from what's happening on the Mac
        enterApp()
        let display = cgFrame, area = usableArea
        NSWorkspace.shared.openApplication(at: a.url, configuration: cfg) { app, err in
            guard let app else { Log.write("launch \(a.name) failed: \(String(describing: err))"); return }
            DispatchQueue.main.async { self.focusPid = app.processIdentifier }
            Windows.adopt(pid: app.processIdentifier, display: display, area: area) { }
        }
    }

    private func showSwitcher() {
        mode = .switcher
        setKeyboard(false); setDock(false); pill.orderOut(nil)
        pagesLayer.isHidden = true; dots.isHidden = true
        switcherLayer.isHidden = false
        present(main, animated: true)
        rebuildCards()
    }

    private func rebuildCards() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switcherLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        switcherLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
        cards = []
        switcherOffset = 0
        let list = Windows.onTablet(cgFrame)
        emptyLabel.isHidden = !list.isEmpty
        let y = (H - cardSize.height) / 2
        for (i, w) in list.enumerated() {
            let x = 48 + CGFloat(i) * (cardSize.width + cardGap)
            let c = CALayer(); c.frame = CGRect(x: x, y: y, width: cardSize.width, height: cardSize.height); c.cornerRadius = 16; c.masksToBounds = true
            c.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1).cgColor; c.contentsGravity = .resizeAspect
            let label = text(13, .semibold); label.alignmentMode = .center; label.frame = CGRect(x: x, y: y - 26, width: cardSize.width, height: 20)
            label.string = w.app
            switcherLayer.addSublayer(c); switcherLayer.addSublayer(label)
            cards.append(Card(win: w, layer: c, x: x))
            Task { [weak c] in
                let img = await Windows.thumbnail(w)
                await MainActor.run { c?.contents = img }
            }
        }
        CATransaction.commit()
    }

    private func applyCardOffset(_ animated: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.25) }
        switcherLayer.bounds.origin.x = switcherOffset
        CATransaction.commit()
    }

    private func raise(_ w: TabletWindow) { mode = .app; enterApp(); Windows.raise(w) }

    private func cycle(_ dir: Int) {
        let list = Windows.onTablet(cgFrame)
        guard list.count > 1 else { return }
        Windows.raise(dir > 0 ? list[1] : list[list.count - 1])
    }

    // MARK: touch routing (coordinates are points from the top-left of the tablet display)

    /// Runs on the gesture queue at the first finger of a sequence: does the shell own it?
    func captures(_ p: CGPoint, height: CGFloat) -> Bool {
        if p.y >= height - edgeHeight { return true }
        stateLock.lock(); defer { stateLock.unlock() }
        if _mode != .app { return true }
        if let r = _kbRect, r.contains(p) { return true }
        if _dockRect != nil { return true } // a tap outside dismisses the dock
        return false
    }

    func handle(_ e: TouchEvent) {
        guard let f = e.points.first else { return }
        let p = CGPoint(x: CGFloat(f.x) * W, y: CGFloat(f.y) * H)
        switch e.action {
        case 0 where e.points.count == 1: began(p)
        case 2 where e.points.count == 1: moved(p)
        case 1 where e.points.count == 1: ended(p)
        case 3: cancelled()
        default: break
        }
        lastPoint = p
    }

    /// Android took the gesture away (system bar reveal): never leave the UI mid-flight.
    private func cancelled() {
        press(pressedTile?.layer, false); pressedTile = nil
        if case .homePan = touch { settlePage(dx: 0, dt: 1) }
        if case .keyboard = touch { kb.touchUp() }
        touch = .none
    }

    private func began(_ p: CGPoint) {
        downPoint = p; downTime = CFAbsoluteTimeGetCurrent(); dragging = false
        stateLock.lock(); let kbR = _kbRect, dockR = _dockRect; stateLock.unlock()
        if p.y >= H - edgeHeight && !(kbR?.contains(p) ?? false) { touch = .edge(p, downTime); return }
        if let r = kbR, r.contains(p) {
            kb.touchDown(at: CGPoint(x: p.x - r.minX, y: p.y - r.minY)); touch = .keyboard; return
        }
        if let r = dockR {
            if r.contains(p) {
                let local = CGPoint(x: p.x - r.minX, y: p.y - r.minY)
                let t = dockTiles.first { $0.frame.insetBy(dx: -6, dy: -8).contains(local) }
                press(t?.layer, true); touch = .dock(t); return
            }
            if mode == .app { setDock(false); touch = .none; return }
        }
        switch mode {
        case .home:
            panBase = pagesLayer.frame.minX
            pressedTile = tiles.first { $0.page == page && $0.frame.insetBy(dx: -18, dy: -10).offsetBy(dx: CGFloat(page) * -W, dy: 0).contains(p) }
            press(pressedTile?.layer, true)
            touch = .homePan
        case .switcher:
            let cp = CGPoint(x: p.x + switcherOffset, y: p.y)
            if let i = cards.firstIndex(where: { $0.layer.frame.contains(cp) }) { touch = .card(i, p) } else { panBase = switcherOffset; touch = .switcherPan }
        case .app: touch = .none
        }
    }

    private func press(_ l: CALayer?, _ down: Bool) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.1)
        l?.transform = down ? CATransform3DMakeScale(0.9, 0.9, 1) : CATransform3DIdentity
        l?.opacity = down ? 0.7 : 1
        CATransaction.commit()
    }

    private func moved(_ p: CGPoint) {
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        // The bottom key row shares the screen edge: a clear upward pull is the home gesture, not a key.
        if case .keyboard = touch, downPoint.y >= H - edgeHeight, dy < -45 {
            kb.cancelTouch(); touch = .edge(downPoint, downTime); return
        }
        if !dragging && hypot(dx, dy) > 8 { dragging = true; press(pressedTile?.layer, false) }
        guard dragging else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        switch touch {
        case .homePan:
            var x = panBase + dx
            let minX = -CGFloat(pageCount - 1) * W
            if x > 0 { x /= 3 } else if x < minX { x = minX + (x - minX) / 3 } // rubber band at the ends
            pagesLayer.frame.origin.x = x
        case .switcherPan, .card:
            if case .card(let i, _) = touch, abs(dy) > abs(dx), dy < 0 {
                cards[i].layer.setAffineTransform(CGAffineTransform(translationX: 0, y: dy)); return
            }
            if case .card = touch { touch = .switcherPan; panBase = switcherOffset }
            switcherOffset = max(0, panBase - dx); applyCardOffset(false)
        default: break
        }
    }

    private func ended(_ p: CGPoint) {
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y, dt = CFAbsoluteTimeGetCurrent() - downTime
        defer { touch = .none; pressedTile = nil }
        switch touch {
        case .edge: edgeEnded(dx: dx, dy: dy, dt: dt)
        case .keyboard: kb.touchUp()
        case .dock(let t):
            press(t?.layer, false)
            guard !dragging, let t else { return }
            if let a = t.app { launch(a) } else { setKeyboard(!keyPanel.isVisible) }
        case .homePan:
            press(pressedTile?.layer, false)
            if !dragging, let t = pressedTile { launch(t.app); return }
            if dragging { settlePage(dx: dx, dt: dt) }
        case .switcherPan: break
        case .card(let i, _):
            guard i < cards.count else { return }
            if dragging && dy < -120 {
                Windows.close(cards[i].win)
                CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
                cards[i].layer.setAffineTransform(CGAffineTransform(translationX: 0, y: -H)); cards[i].layer.opacity = 0
                CATransaction.commit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.rebuildCards() }
            } else if dragging {
                CATransaction.begin(); CATransaction.setAnimationDuration(0.2); cards[i].layer.setAffineTransform(.identity); CATransaction.commit()
            } else { raise(cards[i].win) }
        case .none:
            if case .switcher = mode, !dragging { showHome(animated: false) }
        }
    }

    private func settlePage(dx: CGFloat, dt: Double) {
        if abs(dx) > W * 0.18 || (abs(dx) > 40 && dt < 0.25) { page = max(0, min(pageCount - 1, page + (dx < 0 ? 1 : -1))) }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1))
        pagesLayer.frame.origin.x = -CGFloat(page) * W
        CATransaction.commit()
        updateDots(CGFloat2(width: W, height: H))
    }

    private func edgeEnded(dx: CGFloat, dy: CGFloat, dt: Double) {
        let up = -dy
        if hypot(dx, dy) < 8 { if mode == .app { passTap?(downPoint) }; return } // a plain tap belongs to the app underneath
        if abs(dx) > 90 && abs(dx) > up * 1.5 { if mode == .app { cycle(dx < 0 ? 1 : -1) }; return }
        guard up > 26 else { return }
        switch mode {
        case .home: if up > 110 { showSwitcher() }
        case .switcher: showHome(animated: true)
        case .app:
            if up < 110 && dt < 0.5 { setDock(true) }
            else if dt > 0.55 { showSwitcher() }
            else { showHome(animated: true) }
        }
    }

    func system(_ g: GestureEngine.SystemGesture) {
        switch g {
        case .up: if mode == .switcher { showHome(animated: true) } else { showSwitcher() }
        case .down: if mode == .switcher { showHome(animated: true) }
        case .left: if mode == .app { cycle(1) }
        case .right: if mode == .app { cycle(-1) }
        }
    }

    /// After a real tap on app content, mirror iPadOS: text focus brings up the keyboard.
    func tappedInApp(_ target: InputTarget?) {
        guard let target else { return }
        focusPid = target.pid
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let focused = Windows.textFocused(pid: target.pid)
            DispatchQueue.main.async {
                guard self.mode == .app else { return }
                if focused != self.keyPanel.isVisible { self.setKeyboard(focused) }
            }
        }
    }
}

private typealias CGFloat2 = CGSize
