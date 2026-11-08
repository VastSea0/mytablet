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

extension CALayer {
    /// Physically based motion that picks up from wherever the layer currently is.
    func spring(_ path: String, to v: Any, damping: CGFloat = 26, stiffness: CGFloat = 280) {
        let a = CASpringAnimation(keyPath: path)
        a.damping = damping; a.stiffness = stiffness; a.mass = 1
        a.fromValue = presentation()?.value(forKeyPath: path) ?? value(forKeyPath: path)
        a.toValue = v; a.duration = a.settlingDuration
        CATransaction.begin(); CATransaction.setDisableActions(true); setValue(v, forKeyPath: path); CATransaction.commit()
        add(a, forKey: path)
    }
    func springFrame(_ r: CGRect, damping: CGFloat = 26, stiffness: CGFloat = 280) {
        spring("position", to: NSValue(point: CGPoint(x: r.midX, y: r.midY)), damping: damping, stiffness: stiffness)
        spring("bounds", to: NSValue(rect: CGRect(origin: .zero, size: r.size)), damping: damping, stiffness: stiffness)
    }
    func place(_ r: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        position = CGPoint(x: r.midX, y: r.midY); bounds = CGRect(origin: .zero, size: r.size)
        CATransaction.commit()
    }
    func snapshot() -> CGImage? {
        let s: CGFloat = 2
        guard let c = CGContext(data: nil, width: Int(bounds.width * s), height: Int(bounds.height * s), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        c.translateBy(x: 0, y: bounds.height * s); c.scaleBy(x: s, y: -s)
        render(in: c)
        return c.makeImage()
    }
}

/// The iPadOS-style experience that exists only on the tablet display.
/// It is drawn by ordinary windows on that display and drives real apps; the Mac's own screen is never touched.
final class Shell {
    enum Mode { case home, app, switcher }

    private let displayID: CGDirectDisplayID
    private var screen: NSScreen { NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID } ?? NSScreen.screens[0] }
    private var cgFrame: CGRect { CGDisplayBounds(displayID) }
    private var W: CGFloat { cgFrame.width }
    private var H: CGFloat { cgFrame.height }

    private var main: ShellPanel!, dockPanel: ShellPanel!, keyPanel: ShellPanel!, pill: ShellPanel!, ccPanel: ShellPanel!, overlayPanel: ShellPanel!
    private var root: CALayer!, wallpaper: CALayer!, homeLayer: CALayer!, pagesLayer: CALayer!, dots: CALayer!, switcherLayer: CALayer!
    private var overlay: CALayer!, ccRoot: CALayer!, ccDim: CALayer!, ccSheet: CALayer!
    private var clock: CATextLayer!, statusRight: CATextLayer!, emptyLabel: CATextLayer!, doneButton: CALayer!, addButton: CALayer!
    private var dockGlass: NSVisualEffectView!, dockRoot: CALayer!
    private var kb: KeyboardView!

    // Read by the gesture queue at touch-down.
    private let stateLock = NSLock()
    private var _mode = Mode.home, _dockRect: CGRect?, _kbRect: CGRect?, _ccOpen = false
    private var mode: Mode {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _mode }
        set { stateLock.lock(); _mode = newValue; stateLock.unlock() }
    }
    private func publish(dock: CGRect??, kb: CGRect??, cc: Bool?) {
        stateLock.lock()
        if let dock { _dockRect = dock }
        if let kb { _kbRect = kb }
        if let cc { _ccOpen = cc }
        stateLock.unlock()
    }

    private var apps: [String: AppEntry] = [:], layout = HomeLayout()
    private var recents: [String] = []
    private var tileLayers: [String: CALayer] = [:]
    private var tileFrames: [String: CGRect] = [:]     // page-space frames
    private let icon: CGFloat = 76, cellW: CGFloat = 132, cellH: CGFloat = 122, gridTop: CGFloat = 52
    private let dockHeight: CGFloat = 96
    private var cols = 6, rows = 3, page = 0
    private var pageOffset: CGFloat = 0
    private var editing = false

    private struct DockTile { let path: String?; let frame: CGRect; let layer: CALayer }
    private var dockTiles: [DockTile] = []

    private struct Card { let win: TabletWindow; let layer: CALayer; let label: CALayer; let x: CGFloat }
    private var cards: [Card] = []
    private var switcherOffset: CGFloat = 0
    private let cardSize = CGSize(width: 360, height: 240), cardGap: CGFloat = 36

    private var liveCard: CALayer?, liveWin: TabletWindow?, liveShown = false

    // Folder view
    private var folderPos: (page: Int, index: Int)?
    private var folderDim: CALayer?, folderPanel: CALayer?, folderTitle: CATextLayer?
    private var folderTiles: [(path: String, frame: CGRect, badge: CGRect)] = []
    private var renaming = false

    // Widget gallery
    private var gallery: CALayer?
    private var galleryCards: [(kind: WidgetKind, frame: CGRect)] = []

    private enum Touch {
        case none, edge, topEdge, home, dock(DockTile?), keyboard, switcherPan, card(Int)
        case drag(HomeItem), folder, folderOutside, gallery, cc, ccSlider(Int)
    }
    private var touch = Touch.none
    private var downPoint = CGPoint.zero, downTime = 0.0, lastPoint = CGPoint.zero, panBase: CGFloat = 0, dragging = false
    private var pressedKey: String?
    private var longPress: Timer?

    private var dragLayer: CALayer?, hoverKey: String?, hoverSince = 0.0, edgeSince = 0.0, hoverAnchor = CGPoint.zero

    private var launchUntil = Date.distantPast

    var passTap: ((CGPoint) -> Void)?
    var playSound: ((Int) -> Void)?
    private var focusPid: pid_t?
    private let topEdge: CGFloat = 44 // reaches below Android's status bar so the pull starts where Android can't take it
    let edgeHeight: CGFloat = 32 // starts above Android's own bottom-edge system gesture band

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    // MARK: lifecycle

    func start() {
        build()
        reloadApps()
        layoutAll()
        showHome(animated: false)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.updateStatus() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        updateStatus()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layoutAll()
        }
    }

    private func reloadApps() {
        let list = AppCatalog.installed()
        apps = Dictionary(list.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let dockDefault = AppCatalog.dockApps().map(\.url.path).filter { apps[$0] != nil }
        layout = HomeLayout.load() ?? HomeLayout()
        layout.reconcile(installed: list.map(\.url.path), dockDefault: dockDefault)
    }

    func resetLayout() {
        HomeLayout.reset()
        reloadApps()
        page = 0
        rebuildHome(); layoutDock()
    }

    private func panel(_ level: NSWindow.Level) -> ShellPanel { ShellPanel(frame: .zero, level: level) }

    private func build() {
        main = panel(.statusBar)
        let host = NSView(); host.wantsLayer = true
        main.contentView = host
        // AppKit owns the geometry of a view's backing layer, so the top-left-origin scene lives one level down.
        root = CALayer(); root.isGeometryFlipped = true; root.backgroundColor = NSColor.black.cgColor
        host.layer!.addSublayer(root)
        wallpaper = CALayer(); wallpaper.contentsGravity = .resizeAspectFill; root.addSublayer(wallpaper)
        homeLayer = CALayer(); root.addSublayer(homeLayer)
        pagesLayer = CALayer(); homeLayer.addSublayer(pagesLayer)
        dots = CALayer(); homeLayer.addSublayer(dots)
        switcherLayer = CALayer(); switcherLayer.isHidden = true; root.addSublayer(switcherLayer)
        clock = text(16, .semibold); statusRight = text(14, .medium); statusRight.alignmentMode = .right
        root.addSublayer(clock); root.addSublayer(statusRight)
        emptyLabel = text(18, .medium); emptyLabel.alignmentMode = .center; emptyLabel.string = "Açık uygulama yok"; emptyLabel.isHidden = true
        root.addSublayer(emptyLabel)
        addButton = pillButton("+"); doneButton = pillButton("Bitti")
        addButton.isHidden = true; doneButton.isHidden = true
        root.addSublayer(addButton); root.addSublayer(doneButton)

        dockPanel = panel(.statusBar + 1)
        let dockHost = NSView(); dockHost.wantsLayer = true
        dockPanel.contentView = dockHost
        dockGlass = NSVisualEffectView(); dockGlass.material = .hudWindow; dockGlass.state = .active; dockGlass.blendingMode = .behindWindow
        dockGlass.wantsLayer = true; dockGlass.layer?.cornerRadius = 26; dockGlass.layer?.masksToBounds = true
        dockHost.addSubview(dockGlass)
        dockRoot = CALayer(); dockRoot.isGeometryFlipped = true; dockGlass.layer?.addSublayer(dockRoot)

        keyPanel = panel(.statusBar + 2)
        pill = panel(.statusBar)
        let pv = NSView(); pv.wantsLayer = true; pv.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor; pv.layer?.cornerRadius = 3
        pill.contentView = pv

        ccPanel = panel(.statusBar + 3)
        let ccHost = NSView(); ccHost.wantsLayer = true; ccPanel.contentView = ccHost
        ccRoot = CALayer(); ccRoot.isGeometryFlipped = true; ccHost.layer!.addSublayer(ccRoot)
        ccDim = CALayer(); ccDim.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor; ccDim.opacity = 0; ccRoot.addSublayer(ccDim)
        ccSheet = CALayer(); ccRoot.addSublayer(ccSheet)

        overlayPanel = panel(.statusBar + 4)
        let ov = NSView(); ov.wantsLayer = true; overlayPanel.contentView = ov
        overlay = CALayer(); overlay.isGeometryFlipped = true; ov.layer!.addSublayer(overlay)
    }

    private func text(_ size: CGFloat, _ weight: NSFont.Weight) -> CATextLayer {
        let t = CATextLayer(); t.contentsScale = 2; t.font = NSFont.systemFont(ofSize: size, weight: weight); t.fontSize = size
        t.foregroundColor = NSColor.white.cgColor
        t.shadowOpacity = 0.45; t.shadowRadius = 3; t.shadowOffset = .zero
        return t
    }

    private func pillButton(_ s: String) -> CALayer {
        let l = CALayer(); l.cornerRadius = 14; l.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        let t = text(14, .semibold); t.alignmentMode = .center; t.string = s; t.name = "t"
        l.addSublayer(t)
        return l
    }

    private func tinted(_ name: String, _ pt: CGFloat, _ color: NSColor = .white) -> CGImage? {
        guard let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: pt, weight: .medium)) else { return nil }
        let out = NSImage(size: i.size, flipped: false) { r in i.draw(in: r); color.set(); r.fill(using: .sourceIn); return true }
        return out.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: layout

    private func layoutAll() {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        let f = screen.frame, size = f.size
        for p in [main!, ccPanel!, overlayPanel!] { p.setFrame(f, display: true); p.contentView?.frame = CGRect(origin: .zero, size: size) }
        root.frame = CGRect(origin: .zero, size: size)
        wallpaper.frame = root.frame; homeLayer.frame = root.frame; pagesLayer.frame = root.frame; ccRoot.frame = root.frame; ccDim.frame = root.frame; overlay.frame = root.frame
        loadWallpaper()
        clock.frame = CGRect(x: 22, y: 9, width: 300, height: 22)
        statusRight.frame = CGRect(x: size.width - 322, y: 10, width: 300, height: 20)
        emptyLabel.frame = CGRect(x: 0, y: size.height / 2 - 12, width: size.width, height: 26)
        for (b, x, w) in [(addButton!, 20.0, 40.0), (doneButton!, size.width - 92, 72.0)] {
            b.frame = CGRect(x: x, y: 40, width: w, height: 30)
            b.sublayers?.first { $0.name == "t" }?.frame = CGRect(x: 0, y: 6, width: w, height: 20)
        }
        cols = max(3, Int((size.width - 48) / cellW))
        rows = max(2, Int((size.height - gridTop - dockHeight - 34) / cellH))
        rebuildHome(); layoutDock(); layoutKeyboard(); buildControlCenter()
        pill.setFrame(CGRect(x: f.midX - 70, y: f.minY + 5, width: 140, height: 6), display: true)
    }

    /// Uses the wallpaper macOS is actually showing. Never blocks the main thread.
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

    // MARK: home grid

    private var gridLeft: CGFloat { (W - CGFloat(cols) * cellW) / 2 }

    private func normalize() {
        var i = 0
        while i < layout.pages.count {
            let over = flow(layout.pages[i], cols: cols, rows: rows).overflow
            if !over.isEmpty {
                layout.pages[i].removeLast(over.count)
                if i + 1 == layout.pages.count { layout.pages.append([]) }
                layout.pages[i + 1].insert(contentsOf: over, at: 0)
            }
            i += 1
        }
        layout.pages.removeAll { $0.isEmpty }
        if layout.pages.isEmpty { layout.pages = [[]] }
        page = min(page, layout.pages.count - 1)
    }

    private func frame(for item: HomeItem, page p: Int, cell: (c: Int, r: Int)) -> CGRect {
        let inset = (cellW - icon) / 2
        let x = CGFloat(p) * W + gridLeft + CGFloat(cell.c) * cellW + inset
        let y = gridTop + CGFloat(cell.r) * cellH
        let (w, h) = item.cells
        if w == 1 && h == 1 { return CGRect(x: x, y: y, width: icon, height: icon) }
        return CGRect(x: x, y: y, width: CGFloat(w) * cellW - 2 * inset, height: CGFloat(h) * cellH - 30)
    }

    private func label(_ s: String, width: CGFloat, y: CGFloat) -> CATextLayer {
        let t = text(12, .medium); t.alignmentMode = .center; t.truncationMode = .end; t.string = s
        t.frame = CGRect(x: -22, y: y, width: width + 44, height: 18)
        return t
    }

    private func makeTile(_ item: HomeItem, _ f: CGRect) -> CALayer {
        let l = CALayer()
        l.bounds = CGRect(origin: .zero, size: f.size); l.position = CGPoint(x: f.midX, y: f.midY)
        l.shadowOpacity = 0.3; l.shadowRadius = 5; l.shadowOffset = CGSize(width: 0, height: 2)
        switch item {
        case .app(let p):
            l.contents = apps[p]?.icon; l.contentsGravity = .resizeAspect
            l.addSublayer(label(apps[p]?.name ?? "", width: f.width, y: f.height + 6))
        case .folder(let folder):
            let bg = CALayer(); bg.frame = l.bounds; bg.cornerRadius = 18
            bg.backgroundColor = NSColor.white.withAlphaComponent(0.32).cgColor
            let mini = (f.width - 20) / 3
            for (i, p) in folder.apps.prefix(9).enumerated() {
                let m = CALayer(); m.frame = CGRect(x: 7 + CGFloat(i % 3) * (mini + 3), y: 7 + CGFloat(i / 3) * (mini + 3), width: mini, height: mini)
                m.contents = apps[p]?.icon; m.contentsGravity = .resizeAspect; bg.addSublayer(m)
            }
            l.addSublayer(bg)
            l.addSublayer(label(folder.name, width: f.width, y: f.height + 6))
        case .widget(let kind):
            l.contents = WidgetRenderer.image(kind, size: f.size); l.contentsGravity = .resize
            l.contentsScale = 2; l.name = "widget:" + kind.rawValue
            l.addSublayer(label(kind.title, width: f.width, y: f.height + 4))
        }
        let badge = CALayer(); badge.frame = CGRect(x: -8, y: -8, width: 24, height: 24); badge.cornerRadius = 12; badge.name = "badge"
        badge.backgroundColor = NSColor(calibratedWhite: 0.25, alpha: 0.95).cgColor; badge.isHidden = !editing
        let minus = CALayer(); minus.frame = CGRect(x: 6, y: 11, width: 12, height: 2); minus.backgroundColor = NSColor.white.cgColor; badge.addSublayer(minus)
        l.addSublayer(badge)
        if editing { wiggle(l) }
        return l
    }

    private func wiggle(_ l: CALayer) {
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = [-0.022, 0.022, -0.022]; a.duration = 0.26; a.repeatCount = .infinity
        a.timeOffset = Double.random(in: 0..<0.26)
        l.add(a, forKey: "wiggle")
    }

    private func rebuildHome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pagesLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        tileLayers = [:]; tileFrames = [:]
        normalize()
        for (p, items) in layout.pages.enumerated() {
            let cells = flow(items, cols: cols, rows: rows).cells
            for (i, item) in items.enumerated() {
                let f = frame(for: item, page: p, cell: cells[i])
                let l = makeTile(item, f)
                pagesLayer.addSublayer(l)
                tileLayers[item.key] = l; tileFrames[item.key] = f
            }
        }
        pageOffset = -CGFloat(page) * W
        applyPageOffset()
        updateDots()
        CATransaction.commit()
    }

    /// Slides tiles to their new homes after a model change, keeping layers (and wiggle) alive.
    private func reflow(except skip: String? = nil) {
        normalize()
        for (p, items) in layout.pages.enumerated() {
            let cells = flow(items, cols: cols, rows: rows).cells
            for (i, item) in items.enumerated() {
                let f = frame(for: item, page: p, cell: cells[i])
                tileFrames[item.key] = f
                guard item.key != skip, let l = tileLayers[item.key] else { continue }
                l.springFrame(f, damping: 24, stiffness: 300)
            }
        }
        updateDots()
    }

    private func applyPageOffset() {
        pagesLayer.setValue(pageOffset, forKeyPath: "sublayerTransform.translation.x")
    }

    private func updateDots() {
        dots.sublayers?.forEach { $0.removeFromSuperlayer() }
        let n = layout.pages.count, gap: CGFloat = 14
        dots.frame = CGRect(x: 0, y: H - dockHeight - 26, width: W, height: 10)
        guard n > 1 else { return }
        var x = (W - CGFloat(n - 1) * gap) / 2 - 3.5
        for i in 0..<n {
            let d = CALayer(); d.frame = CGRect(x: x, y: 0, width: 7, height: 7); d.cornerRadius = 3.5
            d.backgroundColor = NSColor.white.withAlphaComponent(i == page ? 1 : 0.4).cgColor
            dots.addSublayer(d); x += gap
        }
    }

    private func goToPage(_ p: Int) {
        page = max(0, min(layout.pages.count - 1, p))
        pageOffset = -CGFloat(page) * W
        pagesLayer.spring("sublayerTransform.translation.x", to: pageOffset, damping: 30, stiffness: 240)
        updateDots()
    }

    private func item(atPageSpace p: CGPoint) -> HomeItem? {
        layout.pages[page].first { tileFrames[$0.key]?.insetBy(dx: -18, dy: -10).contains(p) ?? false }
    }

    private func pagePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + CGFloat(page) * W, y: p.y) }
    private func screenRect(_ pageRect: CGRect) -> CGRect { pageRect.offsetBy(dx: -CGFloat(page) * W, dy: 0) }

    private func tick() {
        updateWidgets()
        // Nothing left open on the tablet: go back to the home screen on its own.
        if mode == .app, Date() > launchUntil, Windows.onTablet(cgFrame).isEmpty { showHome(animated: true) }
    }

    private func updateWidgets() {
        guard mode == .home else { return }
        let second = Calendar.current.component(.second, from: Date())
        for item in layout.pages[page] {
            guard case .widget(let k) = item, k == .clock || second % 10 == 0,
                  let f = tileFrames[item.key], let l = tileLayers[item.key], item.key != draggingKey else { continue }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            l.contents = WidgetRenderer.image(k, size: f.size)
            CATransaction.commit()
        }
    }

    private func save() { layout.save() }

    // MARK: edit mode

    private func enterEdit() {
        guard !editing else { return }
        editing = true
        for l in tileLayers.values { wiggle(l); l.sublayers?.first { $0.name == "badge" }?.isHidden = false }
        addButton.isHidden = false; doneButton.isHidden = false
    }

    private func exitEdit() {
        guard editing else { return }
        editing = false
        for l in tileLayers.values { l.removeAnimation(forKey: "wiggle"); l.sublayers?.first { $0.name == "badge" }?.isHidden = true }
        addButton.isHidden = true; doneButton.isHidden = true
        closeGallery(); save()
    }

    private var draggingKey: String?

    private func index(of key: String) -> (page: Int, index: Int)? {
        for (p, items) in layout.pages.enumerated() { if let i = items.firstIndex(where: { $0.key == key }) { return (p, i) } }
        return nil
    }

    private func removeItem(_ item: HomeItem) {
        guard let pos = index(of: item.key) else { return }
        layout.pages[pos.page].remove(at: pos.index)
        if case .app(let p) = item { layout.hidden.append(p) }
        if case .folder(let f) = item { layout.pages[pos.page].insert(contentsOf: f.apps.map(HomeItem.app), at: pos.index); rebuildHome(); save(); return }
        let l = tileLayers.removeValue(forKey: item.key)
        CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
        CATransaction.setCompletionBlock { l?.removeFromSuperlayer() }
        l?.opacity = 0; l?.transform = CATransform3DMakeScale(0.3, 0.3, 1)
        CATransaction.commit()
        reflow(); save()
    }

    private func pickUp(_ item: HomeItem) {
        guard let l = tileLayers[item.key], let f = tileFrames[item.key] else { return }
        enterEdit()
        draggingKey = item.key
        let d = CALayer(); d.place(screenRect(f)); d.contents = l.snapshot(); d.contentsGravity = .resize
        d.shadowOpacity = 0.45; d.shadowRadius = 14; d.shadowOffset = CGSize(width: 0, height: 10)
        overlayPanel.orderFrontRegardless()
        overlay.addSublayer(d); dragLayer = d
        d.spring("transform.scale", to: 1.14, damping: 20, stiffness: 400)
        CATransaction.begin(); CATransaction.setDisableActions(true); l.isHidden = true; CATransaction.commit()
        touch = .drag(item); hoverKey = nil; edgeSince = 0
        dragging = true
    }

    private func dragMoved(_ item: HomeItem, _ p: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true); dragLayer?.position = p; CATransaction.commit()
        let now = CFAbsoluteTimeGetCurrent()
        // Near the side edge for a moment: flip the page, bringing the item along.
        if p.x < 34 || p.x > W - 34 {
            if edgeSince == 0 { edgeSince = now }
            if now - edgeSince > 0.65 {
                let dir = p.x < 34 ? -1 : 1
                if dir > 0 && page == layout.pages.count - 1 { layout.pages.append([]) }
                let target = max(0, min(layout.pages.count - 1, page + dir))
                if target != page, let pos = index(of: item.key) {
                    layout.pages[pos.page].remove(at: pos.index)
                    layout.pages[target].append(item)
                    page = target
                    reflow(except: item.key)
                    goToPage(target)
                }
                edgeSince = now
            }
            return
        }
        edgeSince = 0
        let pp = pagePoint(p)
        guard let other = layout.pages[page].first(where: { $0.key != item.key && (tileFrames[$0.key]?.contains(pp) ?? false) }),
              let of = tileFrames[other.key], let pos = index(of: item.key), let opos = index(of: other.key), opos.page == pos.page else {
            setHover(nil); return
        }
        var folderable = false
        if case .app = item { if case .widget = other {} else { folderable = true } }
        let inner = of.insetBy(dx: of.width * 0.22, dy: of.height * 0.22)
        if folderable && inner.contains(pp) {
            if hoverKey != other.key { hoverKey = other.key; hoverSince = now }
            if now - hoverSince > 0.22 { setHover(other.key) }
            return
        }
        setHover(nil)
        // Resting at the side of a tile makes room; passing over it on the way somewhere else doesn't.
        let shiftKey = "shift:" + other.key
        if hoverKey != shiftKey || hypot(p.x - hoverAnchor.x, p.y - hoverAnchor.y) > 6 { hoverKey = shiftKey; hoverSince = now; hoverAnchor = p; return }
        guard now - hoverSince > 0.28 else { return }
        hoverKey = nil
        layout.pages[pos.page].remove(at: pos.index)
        layout.pages[pos.page].insert(item, at: min(opos.index, layout.pages[pos.page].count))
        reflow(except: item.key)
    }

    private var highlighted: String?
    private func setHover(_ key: String?) {
        guard key != highlighted else { return }
        if let h = highlighted, let l = tileLayers[h] { l.spring("transform.scale", to: 1.0, damping: 22, stiffness: 340) }
        highlighted = key
        if let key, let l = tileLayers[key] { l.spring("transform.scale", to: 1.2, damping: 18, stiffness: 340) }
    }

    private func drop(_ item: HomeItem, at p: CGPoint) {
        defer { draggingKey = nil; dragLayer = nil; hoverKey = nil; save() }
        let d = dragLayer
        let key = item.key
        func finish(to rect: CGRect) {
            d?.springFrame(rect, damping: 24, stiffness: 320)
            d?.spring("transform.scale", to: 1.0, damping: 24, stiffness: 320)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                d?.removeFromSuperlayer()
                CATransaction.begin(); CATransaction.setDisableActions(true); self?.tileLayers[key]?.isHidden = false; CATransaction.commit()
            }
        }
        if let target = highlighted, let tpos = index(of: target), let spos = index(of: key), case .app(let path) = item {
            setHover(nil)
            layout.pages[spos.page].remove(at: spos.index)
            let idx = spos.page == tpos.page && spos.index < tpos.index ? tpos.index - 1 : tpos.index
            var result: FolderModel?
            switch layout.pages[tpos.page][idx] {
            case .folder(var f): f.apps.append(path); result = f
            case .app(let other): result = FolderModel(id: UUID().uuidString, name: "Klasör", apps: [other, path])
            case .widget: break
            }
            if let result { layout.pages[tpos.page][idx] = .folder(result) }
            CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
            CATransaction.setCompletionBlock { d?.removeFromSuperlayer() }
            d?.opacity = 0; d?.transform = CATransform3DMakeScale(0.4, 0.4, 1)
            CATransaction.commit()
            tileLayers.removeValue(forKey: key)?.removeFromSuperlayer()
            rebuildHome()
            return
        }
        if p.y > H - dockHeight - 20, case .app(let path) = item, let pos = index(of: key), !layout.dock.contains(path) {
            layout.pages[pos.page].remove(at: pos.index)
            layout.dock.append(path)
            layoutDock()
            let dt = dockTiles.first { $0.path == path }
            let target = dt.map { CGRect(x: dockPanel.frame.minX - screen.frame.minX + dockGlass.frame.minX + $0.frame.minX, y: H - dockHeight + $0.frame.minY, width: $0.frame.width, height: $0.frame.height) }
            finish(to: target ?? d?.frame ?? .zero)
            tileLayers.removeValue(forKey: key)?.removeFromSuperlayer()
            reflow()
            return
        }
        reflow(except: key)
        if let f = tileFrames[key] { tileLayers[key]?.place(f) } // still hidden; it reappears where the drag lands
        finish(to: screenRect(tileFrames[key] ?? .zero))
    }

    // MARK: folders

    private func openFolder(at pos: (page: Int, index: Int), from rect: CGRect) {
        guard case .folder(let f) = layout.pages[pos.page][pos.index] else { return }
        folderPos = pos
        let dim = CALayer(); dim.frame = CGRect(x: 0, y: 0, width: W, height: H); dim.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor; dim.opacity = 0
        overlayPanel.orderFrontRegardless(); overlay.addSublayer(dim); folderDim = dim
        dim.spring("opacity", to: 1, damping: 30, stiffness: 200)

        let perRow = 5, cell: CGFloat = 104, rowsN = max(1, Int(ceil(Double(f.apps.count) / Double(perRow))))
        let target = CGRect(x: (W - CGFloat(perRow) * cell - 48) / 2, y: (H - CGFloat(rowsN) * 112 - 92) / 2, width: CGFloat(perRow) * cell + 48, height: CGFloat(rowsN) * 112 + 92)
        let p = CALayer(); p.place(rect); p.cornerRadius = 30; p.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 0.92).cgColor; p.masksToBounds = true
        overlay.addSublayer(p); folderPanel = p

        let title = text(22, .bold); title.alignmentMode = .center; title.string = f.name
        title.frame = CGRect(x: 0, y: 20, width: target.width, height: 32); p.addSublayer(title); folderTitle = title
        folderTiles = []
        for (i, path) in f.apps.enumerated() {
            let x = 24 + CGFloat(i % perRow) * cell + (cell - 64) / 2, y = 68 + CGFloat(i / perRow) * 112
            let l = CALayer(); l.frame = CGRect(x: x, y: y, width: 64, height: 64); l.contents = apps[path]?.icon; l.contentsGravity = .resizeAspect
            let t = label(apps[path]?.name ?? "", width: 64, y: 68); t.fontSize = 11; l.addSublayer(t)
            if editing {
                let b = CALayer(); b.frame = CGRect(x: -6, y: -6, width: 22, height: 22); b.cornerRadius = 11; b.backgroundColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
                let m = CALayer(); m.frame = CGRect(x: 5, y: 10, width: 12, height: 2); m.backgroundColor = NSColor.white.cgColor; b.addSublayer(m); l.addSublayer(b)
                wiggle(l)
            }
            p.addSublayer(l)
            let local = CGRect(x: x, y: y, width: 64, height: 64)
            folderTiles.append((path, local.offsetBy(dx: target.minX, dy: target.minY), CGRect(x: target.minX + x - 12, y: target.minY + y - 12, width: 30, height: 30)))
        }
        p.springFrame(target, damping: 26, stiffness: 260)
    }

    private func closeFolder() {
        guard let pos = folderPos, let p = folderPanel else { return }
        finishRename()
        let key = layout.pages[safe: pos.page]?[safe: pos.index]?.key
        let rect = key.flatMap { tileFrames[$0] }.map(screenRect) ?? CGRect(x: W / 2 - 38, y: H / 2 - 38, width: 76, height: 76)
        let dim = folderDim
        p.springFrame(rect, damping: 30, stiffness: 320)
        dim?.spring("opacity", to: 0, damping: 30, stiffness: 240)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { p.removeFromSuperlayer(); dim?.removeFromSuperlayer() }
        folderPos = nil; folderPanel = nil; folderDim = nil; folderTitle = nil; folderTiles = []
    }

    private func updateFolder(_ transform: (inout FolderModel) -> Void) {
        guard let pos = folderPos, case .folder(var f) = layout.pages[pos.page][pos.index] else { return }
        transform(&f)
        layout.pages[pos.page][pos.index] = .folder(f)
    }

    private func beginRename() {
        renaming = true
        setKeyboard(true)
        kb.textSink = { [weak self] s in
            guard let self else { return }
            self.updateFolder { f in if let s { f.name += s } else if !f.name.isEmpty { f.name.removeLast() } }
            if let pos = self.folderPos, case .folder(let f) = self.layout.pages[pos.page][pos.index] { self.folderTitle?.string = f.name.isEmpty ? " " : f.name }
        }
    }

    private func finishRename() {
        guard renaming else { return }
        renaming = false
        kb.textSink = nil
        setKeyboard(false)
        updateFolder { f in if f.name.trimmingCharacters(in: .whitespaces).isEmpty { f.name = "Klasör" } }
        rebuildHome(); save()
    }

    // MARK: widget gallery

    private func openGallery() {
        let g = CALayer(); g.frame = CGRect(x: 0, y: 0, width: W, height: H); g.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        overlayPanel.orderFrontRegardless(); overlay.addSublayer(g); gallery = g
        let title = text(26, .bold); title.string = "Widget Ekle"; title.alignmentMode = .center; title.frame = CGRect(x: 0, y: 44, width: W, height: 36); g.addSublayer(title)
        galleryCards = []
        let placed = Set(layout.pages.flatMap { $0 }.map(\.key))
        let kinds = WidgetKind.allCases.filter { !placed.contains(HomeItem.widget($0).key) }
        var x: CGFloat = 40, y: CGFloat = 110
        for k in kinds {
            let size = CGSize(width: CGFloat(k.cells.w) * 110, height: CGFloat(k.cells.h) * 100)
            if x + size.width > W - 40 { x = 40; y += 250 }
            let c = CALayer(); c.frame = CGRect(origin: CGPoint(x: x, y: y), size: size); c.contents = WidgetRenderer.image(k, size: size); c.contentsGravity = .resize
            let t = text(13, .medium); t.alignmentMode = .center; t.string = k.title; t.frame = CGRect(x: 0, y: size.height + 8, width: size.width, height: 20); c.addSublayer(t)
            g.addSublayer(c); galleryCards.append((k, c.frame))
            c.transform = CATransform3DMakeScale(0.8, 0.8, 1); c.spring("transform.scale", to: 1.0, damping: 20, stiffness: 300)
            x += size.width + 34
        }
        if kinds.isEmpty { let e = text(16, .medium); e.string = "Tüm widget'lar ana ekranda"; e.alignmentMode = .center; e.frame = CGRect(x: 0, y: H / 2, width: W, height: 26); g.addSublayer(e) }
    }

    private func closeGallery() { gallery?.removeFromSuperlayer(); gallery = nil; galleryCards = [] }

    private func addWidget(_ k: WidgetKind) {
        layout.pages[page].insert(.widget(k), at: 0)
        closeGallery()
        rebuildHome(); save()
    }

    // MARK: dock

    private func layoutDock() {
        dockRoot.sublayers?.forEach { $0.removeFromSuperlayer() }; dockTiles = []
        let size: CGFloat = 66, gap: CGFloat = 14, maxApps = max(1, Int((W - 180) / (size + gap)) - 1)
        let pinned = Array(layout.dock.prefix(maxApps))
        let recent = recents.filter { !pinned.contains($0) && apps[$0] != nil }.prefix(max(0, min(3, maxApps - pinned.count)))
        let count = CGFloat(pinned.count + recent.count + 1)
        let width = count * (size + gap) + gap + 12 + (recent.isEmpty ? 0 : 14)
        let height = dockHeight - 14
        let f = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY, width: width, height: height + 26)
        dockPanel.setFrame(f, display: true)
        dockPanel.contentView?.frame = CGRect(origin: .zero, size: f.size)
        dockGlass.frame = CGRect(x: 0, y: 14, width: width, height: height)
        dockRoot.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        var x = gap
        func add(_ path: String) {
            let l = CALayer(); l.frame = CGRect(x: x, y: (height - size) / 2, width: size, height: size); l.contents = apps[path]?.icon; l.contentsGravity = .resizeAspect
            dockRoot.addSublayer(l); dockTiles.append(DockTile(path: path, frame: l.frame, layer: l)); x += size + gap
        }
        func separator() {
            let s = CALayer(); s.frame = CGRect(x: x - gap / 2 + 1, y: 16, width: 1, height: height - 32); s.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
            dockRoot.addSublayer(s); x += 8
        }
        pinned.forEach(add)
        if !recent.isEmpty { separator(); recent.forEach(add) }
        separator()
        let kbBtn = CALayer(); kbBtn.frame = CGRect(x: x, y: (height - size) / 2, width: size, height: size); kbBtn.cornerRadius = 15
        kbBtn.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        let glyph = CALayer(); glyph.frame = CGRect(x: 14, y: 18, width: size - 28, height: size - 36); glyph.contentsGravity = .resizeAspect
        glyph.contents = tinted("keyboard", 28); kbBtn.addSublayer(glyph)
        dockRoot.addSublayer(kbBtn); dockTiles.append(DockTile(path: nil, frame: kbBtn.frame, layer: kbBtn))
    }

    private var dockRect: CGRect { CGRect(x: dockPanel.frame.minX - screen.frame.minX + dockGlass.frame.minX, y: H - dockHeight + 0, width: dockGlass.frame.width, height: dockGlass.frame.height) }

    private func setDock(_ on: Bool, animated: Bool = true) {
        let glass = dockGlass.layer!
        if on {
            dockPanel.orderFrontRegardless()
            if animated {
                CATransaction.begin(); CATransaction.setDisableActions(true); glass.setValue(-(dockHeight + 10), forKeyPath: "transform.translation.y"); CATransaction.commit()
                glass.spring("transform.translation.y", to: 0, damping: 22, stiffness: 280)
            } else { glass.setValue(0, forKeyPath: "transform.translation.y") }
        } else if dockPanel.isVisible {
            glass.spring("transform.translation.y", to: -(dockHeight + 10), damping: 30, stiffness: 320)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                guard let self, self._dockRect == nil else { return }
                self.dockPanel.orderOut(nil)
            }
        }
        publish(dock: .some(on ? dockRect : nil), kb: nil, cc: nil)
    }

    // MARK: keyboard

    private func layoutKeyboard() {
        let h = min(250, screen.frame.height * 0.42)
        let f = CGRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: h)
        keyPanel.setFrame(f, display: true)
        kb = KeyboardView(frame: CGRect(origin: .zero, size: f.size))
        kb.onDismiss = { [weak self] in self?.setKeyboard(false) }
        kb.targetPid = { [weak self] in self?.focusPid }
        kb.onSound = { [weak self] k in self?.playSound?(k) }
        keyPanel.contentView = kb
    }

    func setKeyboard(_ on: Bool) {
        let visible = _kbRect != nil
        guard on != visible else { return }
        let h = keyPanel.frame.height
        let l = kb.layer!
        if on {
            kb.refreshLabels()
            keyPanel.orderFrontRegardless()
            CATransaction.begin(); CATransaction.setDisableActions(true); l.setValue(-h, forKeyPath: "transform.translation.y"); CATransaction.commit()
            l.spring("transform.translation.y", to: 0, damping: 34, stiffness: 300)
            let r = CGRect(x: keyPanel.frame.minX - screen.frame.minX, y: screen.frame.maxY - keyPanel.frame.maxY, width: keyPanel.frame.width, height: h)
            publish(dock: nil, kb: .some(r), cc: nil)
        } else {
            l.spring("transform.translation.y", to: -h, damping: 36, stiffness: 320)
            publish(dock: nil, kb: .some(nil), cc: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                guard let self, self._kbRect == nil else { return }
                self.keyPanel.orderOut(nil)
            }
        }
    }

    // MARK: status

    private func updateStatus() {
        let df = DateFormatter(); df.locale = Locale(identifier: "tr_TR"); df.dateFormat = "HH:mm  d MMM EEE"
        clock.string = df.string(from: Date())
        var parts: [String] = []
        if let r = CWWiFiClient.shared().interface()?.rssiValue(), r != 0 { parts.append("Wi-Fi") }
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
        setDock(true, animated: animated); pill.orderOut(nil); setKeyboard(false)
        switcherLayer.isHidden = true; emptyLabel.isHidden = true
        homeLayer.isHidden = false
        main.alphaValue = 1
        main.orderFrontRegardless()
        if animated {
            homeLayer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
            homeLayer.opacity = 0.4
            homeLayer.spring("transform.scale", to: 1.0, damping: 26, stiffness: 240)
            homeLayer.spring("opacity", to: 1.0, damping: 30, stiffness: 240)
        }
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

    // MARK: launching

    private var usableArea: CGRect {
        let f = cgFrame, inset = screen.frame.maxY - screen.visibleFrame.maxY
        return CGRect(x: f.minX, y: f.minY + inset, width: f.width, height: f.height - inset)
    }

    private func launch(_ path: String, from rect: CGRect) {
        guard let a = apps[path] else { return }
        launchUntil = Date().addingTimeInterval(8)
        recents.removeAll { $0 == path }; recents.insert(path, at: 0)
        layoutDock()
        exitEdit(); closeFolder()

        // The icon grows into the full screen; the real window replaces it once it's placed.
        let zoom = CALayer(); zoom.place(rect); zoom.cornerRadius = 18; zoom.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        let glyph = CALayer(); glyph.contents = a.icon; glyph.contentsGravity = .resizeAspect; glyph.place(CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        zoom.addSublayer(glyph)
        overlayPanel.orderFrontRegardless(); overlay.addSublayer(zoom)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        zoom.springFrame(full, damping: 28, stiffness: 200)
        zoom.spring("cornerRadius", to: 0, damping: 28, stiffness: 200)
        glyph.spring("position", to: NSValue(point: CGPoint(x: W / 2, y: H / 2)), damping: 28, stiffness: 200)

        let start = Date()
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false // never pull focus away from what's happening on the Mac
        let display = cgFrame, area = usableArea
        func reveal() {
            let wait = max(0, 0.4 - Date().timeIntervalSince(start))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                self.enterApp()
                CATransaction.begin(); CATransaction.setAnimationDuration(0.22)
                CATransaction.setCompletionBlock { zoom.removeFromSuperlayer() }
                zoom.opacity = 0
                CATransaction.commit()
            }
        }
        NSWorkspace.shared.openApplication(at: a.url, configuration: cfg) { app, err in
            guard let app else {
                Log.write("launch \(a.name) failed: \(String(describing: err))")
                DispatchQueue.main.async { reveal() }
                return
            }
            DispatchQueue.main.async { self.focusPid = app.processIdentifier }
            Windows.adopt(pid: app.processIdentifier, display: display, area: area) { reveal() }
        }
    }

    // MARK: app switcher

    private func showSwitcher() {
        mode = .switcher
        setKeyboard(false); setDock(false); pill.orderOut(nil)
        homeLayer.isHidden = true
        switcherLayer.isHidden = false
        main.alphaValue = 1
        main.orderFrontRegardless()
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
            cards.append(Card(win: w, layer: c, label: label, x: x))
            c.transform = CATransform3DMakeScale(0.82, 0.82, 1)
            c.spring("transform.scale", to: 1.0, damping: 22, stiffness: 240 - CGFloat(min(i, 4)) * 20)
            Task { [weak c] in
                let img = await Windows.thumbnail(w)
                await MainActor.run { c?.contents = img }
            }
        }
        CATransaction.commit()
    }

    private func applyCardOffset() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switcherLayer.bounds.origin.x = switcherOffset
        CATransaction.commit()
    }

    private func raise(_ w: TabletWindow) { focusPid = w.pid; enterApp(); Windows.raise(w) }

    private func cycle(_ dir: Int) {
        let list = Windows.onTablet(cgFrame)
        guard list.count > 1 else { return }
        let w = dir > 0 ? list[1] : list[list.count - 1]
        focusPid = w.pid
        Windows.raise(w)
    }

    // MARK: interactive home gesture

    private func beginLiveCard() {
        guard mode == .app, let w = Windows.onTablet(cgFrame).first else { return }
        liveWin = w; liveShown = false
        let c = CALayer(); c.contentsGravity = .resizeAspect; c.cornerRadius = 0; c.masksToBounds = true
        c.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        let r = local(w.frame)
        c.place(r)
        liveCard = c
        Task { [weak c] in
            let img = await Windows.thumbnail(w)
            await MainActor.run { c?.contents = img }
        }
    }

    private func local(_ g: CGRect) -> CGRect { g.offsetBy(dx: -cgFrame.minX, dy: -cgFrame.minY) }

    private func trackLiveCard(dx: CGFloat, up: CGFloat) {
        guard let c = liveCard, let w = liveWin else { return }
        if !liveShown {
            guard up > 12 else { return }
            liveShown = true
            main.alphaValue = 1
            homeLayer.isHidden = false; switcherLayer.isHidden = true
            main.orderFrontRegardless()
            overlayPanel.orderFrontRegardless()
            overlay.addSublayer(c)
            pill.orderOut(nil)
        }
        let p = min(1, up / (H * 0.6)), scale = 1 - 0.55 * p
        let r = local(w.frame)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        c.position = CGPoint(x: r.midX + dx * 0.6, y: r.midY - up * 0.75)
        c.transform = CATransform3DMakeScale(scale, scale, 1)
        c.cornerRadius = 22 * p / max(scale, 0.1)
        homeLayer.transform = CATransform3DMakeScale(0.92 + 0.08 * p, 0.92 + 0.08 * p, 1)
        CATransaction.commit()
    }

    /// The icon the app came from, so the window shrinks back into it.
    private func iconRect(forApp name: String) -> CGRect {
        for (key, f) in tileFrames where key.hasPrefix("a:") {
            let path = String(key.dropFirst(2))
            if apps[path]?.name == name, let pos = index(of: key), pos.page == page { return screenRect(f) }
        }
        return CGRect(x: W / 2 - 38, y: H - dockHeight - 110, width: 76, height: 76)
    }

    private func finishLiveCard(toHome: Bool) {
        guard let c = liveCard else { return }
        liveCard = nil
        let appName = liveWin?.app ?? ""
        let target = liveWin.map { local($0.frame) } ?? .zero
        guard liveShown else { return }
        if toHome {
            let r = iconRect(forApp: appName)
            c.spring("position", to: NSValue(point: CGPoint(x: r.midX, y: r.midY)), damping: 24, stiffness: 220)
            c.spring("transform.scale", to: r.width / max(target.width, 1), damping: 24, stiffness: 220)
            homeLayer.spring("transform.scale", to: 1.0, damping: 26, stiffness: 240)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
                CATransaction.setCompletionBlock { c.removeFromSuperlayer() }
                c.opacity = 0
                CATransaction.commit()
            }
        } else {
            c.spring("position", to: NSValue(point: CGPoint(x: target.midX, y: target.midY)), damping: 26, stiffness: 280)
            c.spring("transform.scale", to: 1.0, damping: 26, stiffness: 280)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                c.removeFromSuperlayer()
                guard let self, self.mode == .app else { return }
                self.main.orderOut(nil)
                self.pill.orderFrontRegardless()
            }
        }
    }

    // MARK: Control Center

    private struct CCTile { let frame: CGRect; let layer: CALayer; let active: () -> Bool; let action: () -> Void; let toggle: Bool }
    private struct CCSlider { let frame: CGRect; let fill: CALayer; let get: () -> Double; let set: (Double) -> Void }
    private var ccTiles: [CCTile] = [], ccSliders: [CCSlider] = []
    private let ccSize = CGSize(width: 420, height: 400)

    private var ccRest: CGPoint { CGPoint(x: W - ccSize.width / 2 - 16, y: 30 + ccSize.height / 2) }
    private var ccHidden: CGPoint { CGPoint(x: ccRest.x, y: -ccSize.height / 2 - 20) }

    private func tileColor(_ on: Bool) -> CGColor { (on ? NSColor.systemBlue : NSColor(calibratedWhite: 0.3, alpha: 0.9)).cgColor }

    private func buildControlCenter() {
        ccSheet.sublayers?.forEach { $0.removeFromSuperlayer() }; ccTiles = []; ccSliders = []
        ccSheet.bounds = CGRect(origin: .zero, size: ccSize); ccSheet.position = ccHidden
        let bg = CALayer(); bg.frame = ccSheet.bounds; bg.cornerRadius = 28; bg.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.9).cgColor; ccSheet.addSublayer(bg)
        let display = displayID
        func tile(_ f: CGRect, _ symbol: String, _ caption: String, toggle: Bool, active: @escaping () -> Bool, action: @escaping () -> Void) {
            let l = CALayer(); l.frame = f; l.cornerRadius = 18; l.backgroundColor = tileColor(false) // real state is read when the panel opens
            let g = CALayer(); g.frame = CGRect(x: (f.width - 30) / 2, y: 14, width: 30, height: 28); g.contentsGravity = .resizeAspect; g.contents = tinted(symbol, 24); l.addSublayer(g)
            let t = text(11, .medium); t.alignmentMode = .center; t.string = caption; t.frame = CGRect(x: 0, y: f.height - 26, width: f.width, height: 18); t.shadowOpacity = 0; l.addSublayer(t)
            ccSheet.addSublayer(l)
            ccTiles.append(CCTile(frame: f, layer: l, active: active, action: action, toggle: toggle))
        }
        let t: CGFloat = 92, g: CGFloat = 12, x0: CGFloat = 18, y0: CGFloat = 18
        tile(CGRect(x: x0, y: y0, width: t, height: t), "wifi", "Wi-Fi", toggle: true, active: { SystemControls.wifiOn }) { SystemControls.setWifi(!SystemControls.wifiOn) }
        tile(CGRect(x: x0 + t + g, y: y0, width: t, height: t), "dot.radiowaves.left.and.right", "Bluetooth", toggle: true, active: { SystemControls.bluetoothOn }) { SystemControls.setBluetooth(!SystemControls.bluetoothOn) }
        tile(CGRect(x: x0, y: y0 + t + g, width: t, height: t), "moon.fill", "Koyu Mod", toggle: true, active: { SystemControls.darkMode }) { SystemControls.setDarkMode(!SystemControls.darkMode) }
        tile(CGRect(x: x0 + t + g, y: y0 + t + g, width: t, height: t), "camera.viewfinder", "Ekran Resmi", toggle: false, active: { false }) { [weak self] in
            self?.closeControlCenter()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SystemControls.screenshot(displayID: display) }
        }
        let mw = (2 * t + g - 2 * g) / 3, my = y0 + 2 * (t + g), mh: CGFloat = 58
        tile(CGRect(x: x0, y: my, width: mw, height: mh), "backward.fill", "", toggle: false, active: { false }) { SystemControls.press(.previous) }
        tile(CGRect(x: x0 + mw + g, y: my, width: mw, height: mh), "playpause.fill", "", toggle: false, active: { false }) { SystemControls.press(.play) }
        tile(CGRect(x: x0 + 2 * (mw + g), y: my, width: mw, height: mh), "forward.fill", "", toggle: false, active: { false }) { SystemControls.press(.next) }
        tile(CGRect(x: x0, y: my + mh + g, width: 2 * t + g, height: 70), "keyboard", "Klavye", toggle: true, active: { [weak self] in self?._kbRect != nil }) { [weak self] in
            guard let self else { return }
            self.setKeyboard(self._kbRect == nil)
        }
        func slider(_ x: CGFloat, _ symbol: String, get: @escaping () -> Double, set: @escaping (Double) -> Void) {
            let f = CGRect(x: x, y: y0, width: 84, height: ccSize.height - 2 * y0)
            let l = CALayer(); l.frame = f; l.cornerRadius = 22; l.masksToBounds = true; l.backgroundColor = NSColor(calibratedWhite: 0.3, alpha: 0.9).cgColor
            let fill = CALayer(); fill.backgroundColor = NSColor.white.cgColor; l.addSublayer(fill)
            let g = CALayer(); g.frame = CGRect(x: 27, y: f.height - 42, width: 30, height: 28); g.contentsGravity = .resizeAspect; g.contents = tinted(symbol, 22, .darkGray); l.addSublayer(g)
            ccSheet.addSublayer(l)
            ccSliders.append(CCSlider(frame: f, fill: fill, get: get, set: set))
        }
        slider(x0 + 2 * t + g + 18, "speaker.wave.2.fill", get: { Double(SystemControls.volume) }, set: { SystemControls.volume = Float($0) })
        slider(x0 + 2 * t + g + 18 + 84 + 12, "sun.max.fill", get: { [weak self] in self?.tabletBrightness ?? 0.5 }, set: { [weak self] v in
            self?.tabletBrightness = v; SystemControls.setTabletBrightness(v)
        })
    }

    private var tabletBrightness = 0.5

    private func setFill(_ s: CCSlider, _ v: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = s.frame.height * CGFloat(max(0, min(1, v)))
        s.fill.frame = CGRect(x: 0, y: s.frame.height - h, width: s.frame.width, height: h)
        CATransaction.commit()
    }

    private func refreshControlCenter() {
        for t in ccTiles where t.toggle { t.layer.backgroundColor = tileColor(t.active()) }
        for s in ccSliders { setFill(s, s.get()) }
    }

    private func prepareControlCenter() {
        guard !ccPanel.isVisible else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let b = SystemControls.tabletBrightness()
            DispatchQueue.main.async { self?.tabletBrightness = b; self?.refreshControlCenter() }
        }
        refreshControlCenter()
        ccPanel.orderFrontRegardless()
    }

    private func trackControlCenter(_ down: CGFloat) {
        let p = max(0, min(1, down / (ccSize.height * 0.8)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ccSheet.position = CGPoint(x: ccRest.x, y: ccHidden.y + (ccRest.y - ccHidden.y) * p)
        ccDim.opacity = Float(p)
        CATransaction.commit()
    }

    private func openControlCenter() {
        prepareControlCenter()
        ccSheet.spring("position", to: NSValue(point: ccRest), damping: 24, stiffness: 260)
        ccDim.spring("opacity", to: 1, damping: 30, stiffness: 260)
        publish(dock: nil, kb: nil, cc: true)
    }

    private func closeControlCenter() {
        ccSheet.spring("position", to: NSValue(point: ccHidden), damping: 30, stiffness: 300)
        ccDim.spring("opacity", to: 0, damping: 30, stiffness: 300)
        publish(dock: nil, kb: nil, cc: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self._ccOpen else { return }
            self.ccPanel.orderOut(nil)
        }
    }

    private var ccOrigin: CGPoint { CGPoint(x: ccRest.x - ccSize.width / 2, y: ccRest.y - ccSize.height / 2) }

    // MARK: touch routing (coordinates are points from the top-left of the tablet display)

    /// Runs on the gesture queue at the first finger of a sequence: does the shell own it?
    func captures(_ p: CGPoint, height: CGFloat) -> Bool {
        if p.y >= height - edgeHeight { return true }
        stateLock.lock(); defer { stateLock.unlock() }
        if _ccOpen { return true }
        if p.y < topEdge && p.x > cgWidth * 0.55 { return true } // Control Center pull-down
        if _mode != .app { return true }
        if let r = _kbRect, r.contains(p) { return true }
        if _dockRect != nil { return true } // a tap outside dismisses the dock
        return false
    }
    private var cgWidth: CGFloat { CGDisplayBounds(displayID).width }

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
        longPress?.invalidate()
        setPressed(nil)
        switch touch {
        case .home: goToPage(page)
        case .keyboard: kb.touchUp()
        case .edge: finishLiveCard(toHome: false)
        case .topEdge: closeControlCenter()
        case .drag(let item): drop(item, at: lastPoint)
        default: break
        }
        touch = .none
    }

    private func setPressed(_ key: String?) {
        if let old = pressedKey, let l = tileLayers[old] { l.spring("transform.scale", to: 1.0, damping: 18, stiffness: 420) }
        pressedKey = key
        if let key, let l = tileLayers[key] { l.spring("transform.scale", to: 0.88, damping: 26, stiffness: 520) }
    }

    private func began(_ p: CGPoint) {
        downPoint = p; lastPoint = p; downTime = CFAbsoluteTimeGetCurrent(); dragging = false
        longPress?.invalidate()
        stateLock.lock(); let kbR = _kbRect, dockR = _dockRect, ccOpen = _ccOpen; stateLock.unlock()

        if ccOpen {
            let local = CGPoint(x: p.x - ccOrigin.x, y: p.y - ccOrigin.y)
            if let i = ccSliders.firstIndex(where: { $0.frame.contains(local) }) { touch = .ccSlider(i); return }
            touch = .cc
            return
        }
        if p.y < topEdge && p.x > W * 0.55 { touch = .topEdge; prepareControlCenter(); return }
        if folderPos != nil { touch = (folderPanel?.frame.contains(p) ?? false) ? .folder : .folderOutside; return }
        if gallery != nil { touch = .gallery; return }
        if let r = kbR, r.contains(p) {
            kb.touchDown(at: CGPoint(x: p.x - r.minX, y: p.y - r.minY)); touch = .keyboard; return
        }
        if p.y >= H - edgeHeight && dockR?.contains(p) != true { touch = .edge; beginLiveCard(); return }
        if let r = dockR {
            if r.contains(p) {
                let local = CGPoint(x: p.x - r.minX, y: p.y - r.minY)
                let t = dockTiles.first { $0.frame.insetBy(dx: -6, dy: -8).contains(local) }
                pressLayer(t?.layer, true); touch = .dock(t); return
            }
            if mode == .app { setDock(false); touch = .none; return }
        }
        switch mode {
        case .home:
            panBase = pageOffset
            let pp = pagePoint(p)
            touch = .home
            guard let it = item(atPageSpace: pp) else { return }
            setPressed(it.key)
            longPress = Timer.scheduledTimer(withTimeInterval: 0.42, repeats: false) { [weak self] _ in
                guard let self, !self.dragging else { return }
                self.setPressed(nil)
                self.pickUp(it)
            }
        case .switcher:
            let cp = CGPoint(x: p.x + switcherOffset, y: p.y)
            if let i = cards.firstIndex(where: { $0.layer.frame.contains(cp) }) { touch = .card(i) } else { panBase = switcherOffset; touch = .switcherPan }
        case .app: touch = .none
        }
    }

    private func pressLayer(_ l: CALayer?, _ down: Bool) {
        l?.spring("transform.scale", to: down ? 0.86 : 1.0, damping: 24, stiffness: 500)
    }

    private func moved(_ p: CGPoint) {
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        // The bottom key row shares the screen edge: a clear upward pull is the home gesture, not a key.
        if case .keyboard = touch, downPoint.y >= H - edgeHeight, dy < -45 {
            kb.cancelTouch(); touch = .edge; beginLiveCard(); return
        }
        if !dragging && hypot(dx, dy) > 8 {
            dragging = true
            longPress?.invalidate()
            if case .home = touch, editing, let key = pressedKey, let it = layout.pages[page].first(where: { $0.key == key }) {
                setPressed(nil); pickUp(it)
            } else { setPressed(nil) }
        }
        switch touch {
        case .edge where dragging: trackLiveCard(dx: dx, up: -dy)
        case .topEdge: trackControlCenter(dy)
        case .drag(let item): dragMoved(item, p)
        case .ccSlider(let i):
            let s = ccSliders[i], local = p.y - ccOrigin.y - s.frame.minY
            let v = Double(1 - max(0, min(1, local / s.frame.height)))
            setFill(s, v); s.set(v)
        case .home where dragging:
            var x = panBase + dx
            let minX = -CGFloat(layout.pages.count - 1) * W
            if x > 0 { x /= 3 } else if x < minX { x = minX + (x - minX) / 3 } // rubber band at the ends
            pageOffset = x
            CATransaction.begin(); CATransaction.setDisableActions(true); applyPageOffset(); CATransaction.commit()
        case .switcherPan where dragging:
            switcherOffset = max(0, panBase - dx); applyCardOffset()
        case .card(let i) where dragging:
            if abs(dy) > abs(dx), dy < 0 {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                cards[i].layer.setAffineTransform(CGAffineTransform(translationX: 0, y: dy))
                CATransaction.commit()
            } else { touch = .switcherPan; panBase = switcherOffset }
        default: break
        }
    }

    private func ended(_ p: CGPoint) {
        longPress?.invalidate()
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y, dt = CFAbsoluteTimeGetCurrent() - downTime
        defer { touch = .none }
        let key = pressedKey
        setPressed(nil)
        switch touch {
        case .edge: edgeEnded(dx: dx, dy: dy, dt: dt)
        case .topEdge:
            if dy > 70 { openControlCenter() } else if dragging == false && hypot(dx, dy) < 8 {
                closeControlCenter(); if mode == .app { passTap?(downPoint) }
            } else { closeControlCenter() }
        case .keyboard: kb.touchUp()
        case .drag(let item): drop(item, at: p)
        case .cc:
            guard !dragging else { if dy < -40 { closeControlCenter() }; return }
            let local = CGPoint(x: p.x - ccOrigin.x, y: p.y - ccOrigin.y)
            if let t = ccTiles.first(where: { $0.frame.contains(local) }) {
                t.layer.spring("transform.scale", to: 1.0, damping: 16, stiffness: 420)
                t.action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshControlCenter() }
            } else if !CGRect(origin: .zero, size: ccSize).contains(local) { closeControlCenter() }
        case .ccSlider: break
        case .folderOutside: closeFolder()
        case .folder: folderTapped(p)
        case .gallery:
            if let c = galleryCards.first(where: { $0.frame.contains(p) }) { addWidget(c.kind) } else { closeGallery() }
        case .dock(let t):
            pressLayer(t?.layer, false)
            guard let t else { return }
            if editing, dy < -60, let path = t.path, layout.dock.contains(path) {
                layout.dock.removeAll { $0 == path }
                layout.pages[layout.pages.count - 1].append(.app(path))
                layoutDock(); rebuildHome(); save()
                return
            }
            guard !dragging else { return }
            if let path = t.path {
                let r = dockRect
                launch(path, from: CGRect(x: r.minX + t.frame.minX, y: r.minY + t.frame.minY, width: t.frame.width, height: t.frame.height))
            } else { setKeyboard(_kbRect == nil) }
        case .home:
            if dragging { settlePage(dx: dx, dt: dt); return }
            homeTapped(p, pressed: key)
        case .switcherPan: break
        case .card(let i):
            guard i < cards.count else { return }
            let card = cards[i]
            if dragging && dy < -120 {
                Windows.close(card.win)
                CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
                card.layer.setAffineTransform(CGAffineTransform(translationX: 0, y: -H)); card.layer.opacity = 0; card.label.opacity = 0
                CATransaction.commit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.rebuildCards() }
            } else if dragging {
                card.layer.spring("transform", to: NSValue(caTransform3D: CATransform3DIdentity), damping: 22, stiffness: 300)
            } else { raise(card.win) }
        case .none:
            if mode == .switcher, !dragging { showHome(animated: true) }
        }
    }

    private func homeTapped(_ p: CGPoint, pressed key: String?) {
        if editing {
            if doneButton.frame.contains(p) { exitEdit(); return }
            if addButton.frame.contains(p) { openGallery(); return }
            let pp = pagePoint(p)
            // Badges hang off each tile's top-left corner.
            if let it = layout.pages[page].first(where: { i in
                guard let f = tileFrames[i.key] else { return false }
                return CGRect(x: f.minX - 14, y: f.minY - 14, width: 34, height: 34).contains(pp)
            }) { removeItem(it); return }
            if let it = item(atPageSpace: pp), case .folder = it, let pos = index(of: it.key) { openFolder(at: pos, from: screenRect(tileFrames[it.key]!)); return }
            if item(atPageSpace: pp) == nil { exitEdit() }
            return
        }
        guard let key, let it = layout.pages[page].first(where: { $0.key == key }), let f = tileFrames[key] else { return }
        switch it {
        case .app(let path): launch(path, from: screenRect(f))
        case .folder: if let pos = index(of: key) { openFolder(at: pos, from: screenRect(f)) }
        case .widget: break
        }
    }

    private func folderTapped(_ p: CGPoint) {
        if dragging { return }
        guard let pos = folderPos, let panel = folderPanel else { return }
        if p.y - panel.frame.minY < 60 { if editing || renaming { beginRename() }; return }
        if editing, let t = folderTiles.first(where: { $0.badge.contains(p) }) {
            guard case .folder(var f) = layout.pages[pos.page][pos.index] else { return }
            f.apps.removeAll { $0 == t.path }
            let host = pos
            closeFolder()
            layout.pages[host.page].append(.app(t.path))
            if f.apps.count <= 1 {
                layout.pages[host.page].remove(at: host.index)
                layout.pages[host.page].insert(contentsOf: f.apps.map(HomeItem.app), at: host.index)
            } else { layout.pages[host.page][host.index] = .folder(f) }
            rebuildHome(); save()
            return
        }
        if let t = folderTiles.first(where: { $0.frame.contains(p) }) { launch(t.path, from: t.frame) }
    }

    private func settlePage(dx: CGFloat, dt: Double) {
        var target = page
        if abs(dx) > W * 0.18 || (abs(dx) > 40 && dt < 0.25) { target += dx < 0 ? 1 : -1 }
        goToPage(target)
    }

    private func edgeEnded(dx: CGFloat, dy: CGFloat, dt: Double) {
        let up = -dy
        if hypot(dx, dy) < 8 { finishLiveCard(toHome: false); if mode == .app { passTap?(downPoint) }; return } // a plain tap belongs to the app underneath
        if abs(dx) > 90 && abs(dx) > up * 1.5 { finishLiveCard(toHome: false); if mode == .app { cycle(dx < 0 ? 1 : -1) }; return }
        guard up > 26 else { finishLiveCard(toHome: false); return }
        switch mode {
        case .home: if up > 110 { showSwitcher() }
        case .switcher: showHome(animated: true)
        case .app:
            if up < 110 && dt < 0.5 { finishLiveCard(toHome: false); setDock(true) }
            else if dt > 0.55 { finishLiveCard(toHome: false); showSwitcher() }
            else { finishLiveCard(toHome: true); showHome(animated: false) }
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
        DispatchQueue.main.async { self.focusPid = target.pid }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let focused = Windows.textFocused(pid: target.pid)
            DispatchQueue.main.async {
                guard self.mode == .app else { return }
                if focused != (self._kbRect != nil) { self.setKeyboard(focused) }
            }
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
