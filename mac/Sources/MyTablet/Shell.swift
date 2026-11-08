import AppKit
import CoreWLAN
import IOKit.ps
import QuartzCore
import ScreenCaptureKit
import CoreImage

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

/// Apple's real Liquid Glass, with a top-left-origin layer inside for content.
/// AppKit's public styles only offer the frosted look. The clear, edge-refracting material the system Dock
/// uses is one of the view's internal variants, so it's set when available and falls back to `.clear`.
let lensGlassVariant = 11
/// `lens` is the clear system-Dock look; otherwise the standard frosted glass.
func configureGlass(_ g: NSGlassEffectView, lens: Bool) {
    guard g.responds(to: Selector(("set_variant:"))) else { g.style = lens ? .clear : .regular; return }
    g.setValue(lens ? lensGlassVariant : 0, forKey: "_variant")
}

private func makeGlass(_ frame: CGRect, radius: CGFloat, lens: Bool) -> (view: NSGlassEffectView, content: CALayer) {
    let g = NSGlassEffectView(frame: frame)
    configureGlass(g, lens: lens)
    g.wantsLayer = true
    g.cornerRadius = radius
    let host = NSView(frame: CGRect(origin: .zero, size: frame.size)); host.wantsLayer = true
    host.autoresizingMask = [.width, .height]
    g.contentView = host
    let c = CALayer(); c.isGeometryFlipped = true; c.frame = host.bounds
    host.layer!.addSublayer(c)
    return (g, c)
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

    private var main: ShellPanel!, dockPanel: ShellPanel!, keyPanel: ShellPanel!, pill: ShellPanel!, ccPanel: ShellPanel!, overlayPanel: ShellPanel!, statusPanel: ShellPanel!
    private var root: CALayer!, wallpaper: CALayer!, homeLayer: CALayer!, pagesLayer: CALayer!, dots: CALayer!, switcherLayer: CALayer!
    private var overlay: CALayer!, statusWall: CALayer!, ccSheet: NSView!
    private var glassHost: NSView!
    private var dockWall: CALayer!, ccWall: CALayer!, keyWall: CALayer!
    private var fullscreenWindow = false
    private var folderGlass: [String: NSGlassEffectView] = [:]
    private var widgetLayers: [String: CALayer] = [:]
    private var clock: CATextLayer!, statusRight: CATextLayer!, emptyLabel: CATextLayer!, doneButton: CALayer!, addButton: CALayer!
    private var dockGlass: NSGlassEffectView!, dockRoot: CALayer!
    private var wifiGlyph: CALayer!, batteryGlyph: CALayer!
    private var menuInset: CGFloat { screen.frame.maxY - screen.visibleFrame.maxY }
    private var menuShown = false, menuTimer: Timer?
    private var kb: KeyboardView!

    // Read by the gesture queue at touch-down.
    private let stateLock = NSLock()
    private var _mode = Mode.home, _dockRect: CGRect?, _kbRect: CGRect?, _ccOpen = false, _fullscreen = false
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
    private var tileLayers: [String: CALayer] = [:]
    private var tileFrames: [String: CGRect] = [:]     // page-space frames
    private var icon: CGFloat { [64, 76, 90][Prefs.current.iconSize] }
    private var cellW: CGFloat { icon + 56 }
    private var cellH: CGFloat { icon + 46 }
    private let gridTop: CGFloat = 52
    private var dockIcon: CGFloat { [50, 60, 70][Prefs.current.dockSize] }
    private var dockHeight: CGFloat { dockIcon + 36 }
    private var shownRecents: [String] { Prefs.current.dockRecents ? (layout.recents ?? []) : [] }
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
    private var folderDim: CALayer?, folderPanel: NSGlassEffectView?, folderRect = CGRect.zero, folderTitle: CATextLayer?
    private var folderTiles: [(path: String, frame: CGRect, badge: CGRect)] = []
    private var renaming = false

    // Widget gallery
    private var gallery: CALayer?
    private var galleryCards: [(title: String, frame: CGRect)] = []
    private var liveWidgets: [String: SCWindow] = [:]
    private var widgetImages: [String: CGImage] = [:]

    private enum Touch {
        case none, edge, topEdge, menuEdge, home, dock(DockTile?), keyboard, switcherPan, card(Int)
        case drag(HomeItem), settings, settingsOutside, folder, folderOutside, gallery, cc, ccSlider(Int)
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
    // In full screen the app owns the display, so only a thin strip is kept for the system gestures.
    private func topZone(_ fullscreen: Bool) -> CGFloat { fullscreen ? 10 : menuInset }
    private func bottomZone(_ fullscreen: Bool) -> CGFloat { fullscreen ? 12 : 20 }

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    // MARK: lifecycle

    func start() {
        build()
        reloadApps()
        layoutAll()
        showHome(animated: false)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.updateStatus() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refreshWidgets() }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.syncWithWindows() }
        updateStatus()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layoutAll()
        }
    }

    private func reloadApps() {
        var list = AppCatalog.installed()
        if let e = settingsEntry() { list.insert(e, at: 0) }
        apps = Dictionary(list.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })
        let dockDefault = AppCatalog.dockApps().map(\.url.path).filter { apps[$0] != nil }
        layout = HomeLayout.load() ?? HomeLayout()
        layout.reconcile(installed: list.map(\.url.path), dockDefault: dockDefault)
        if !UserDefaults.standard.bool(forKey: "settingsPlacedV2"), let pos = index(of: "a:" + settingsPath) {
            // First run: Settings starts on the first page, right after the widgets.
            let item = layout.pages[pos.page].remove(at: pos.index)
            let after = layout.pages[0].prefix { if case .widget = $0 { return true }; return false }.count
            layout.pages[0].insert(item, at: after)
            UserDefaults.standard.set(true, forKey: "settingsPlacedV2")
            layout.save()
        }
    }

    func resetLayout() {
        HomeLayout.reset()
        UserDefaults.standard.set(false, forKey: "settingsPlacedV2")
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
        emptyLabel = text(18, .medium); emptyLabel.alignmentMode = .center; emptyLabel.string = "Açık uygulama yok"; emptyLabel.isHidden = true
        root.addSublayer(emptyLabel)
        glassHost = NSView(); glassHost.wantsLayer = true; host.addSubview(glassHost)
        addButton = pillButton("+"); doneButton = pillButton("Bitti")
        addButton.isHidden = true; doneButton.isHidden = true
        root.addSublayer(addButton); root.addSublayer(doneButton)

        dockPanel = panel(.statusBar + 1)
        let dockHost = NSView(); dockHost.wantsLayer = true
        dockPanel.contentView = dockHost
        let dg = makeGlass(CGRect(x: 0, y: 0, width: 400, height: 80), radius: 30, lens: true)
        dockGlass = dg.view; dockRoot = dg.content
        dockWall = CALayer(); dockWall.contentsGravity = .resize
        dockHost.layer!.addSublayer(dockWall)
        dockHost.addSubview(dockGlass)

        // Sits over the Mac's menu bar on this display only, showing what iPadOS shows there.
        statusPanel = panel(.statusBar + 5) // stays above Control Center, like the real status bar
        let sh = NSView(); sh.wantsLayer = true; statusPanel.contentView = sh
        let sr = CALayer(); sr.isGeometryFlipped = true; sr.masksToBounds = true; sr.name = "root"; sh.layer!.addSublayer(sr)
        statusWall = CALayer(); statusWall.contentsGravity = .resizeAspectFill; sr.addSublayer(statusWall)
        clock = statusText(13, .semibold); statusRight = statusText(13, .semibold); statusRight.alignmentMode = .right
        wifiGlyph = CALayer(); wifiGlyph.contentsGravity = .resizeAspect
        batteryGlyph = CALayer(); batteryGlyph.contentsGravity = .resizeAspect
        for l in [clock!, statusRight!, wifiGlyph!, batteryGlyph!] { sr.addSublayer(l) }

        keyPanel = panel(.statusBar + 2)
        pill = panel(.statusBar)
        let pv = NSView(); pv.wantsLayer = true; pv.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor; pv.layer?.cornerRadius = 3
        pill.contentView = pv

        ccPanel = panel(.statusBar + 3)
        let ccHost = NSView(); ccHost.wantsLayer = true; ccPanel.contentView = ccHost
        ccWall = CALayer(); ccWall.contentsGravity = .resize; ccWall.opacity = 0; ccHost.layer!.addSublayer(ccWall)
        ccSheet = NSView(); ccSheet.wantsLayer = true; ccHost.addSubview(ccSheet)

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

    private func statusText(_ size: CGFloat, _ weight: NSFont.Weight) -> CATextLayer {
        let t = CATextLayer(); t.contentsScale = 2; t.font = NSFont.systemFont(ofSize: size, weight: weight); t.fontSize = size
        t.foregroundColor = NSColor.white.cgColor
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
        glassHost.frame = CGRect(origin: .zero, size: CGSize(width: size.width * 40, height: size.height))
        ccWall.frame = CGRect(origin: .zero, size: size)
        root.frame = CGRect(origin: .zero, size: size)
        wallpaper.frame = root.frame; homeLayer.frame = root.frame; pagesLayer.frame = root.frame; overlay.frame = root.frame
        loadWallpaper()
        layoutStatus()
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

    /// What's on screen beneath the shell. Liquid Glass only refracts content in its own window, so
    /// each glass surface gets this as a layer behind it.
    private func withBackdrop(_ done: @escaping (CGImage?) -> Void) {
        if mode != .app { done(root.snapshot()); return }
        let id = displayID
        Task {
            guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let d = c.displays.first(where: { $0.displayID == id }) else { await MainActor.run { done(nil) }; return }
            let me = c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let cfg = SCStreamConfiguration(); cfg.width = d.width * 2; cfg.height = d.height * 2; cfg.showsCursor = false
            let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), configuration: cfg)
            await MainActor.run { done(img) }
        }
    }

    /// Softens a backdrop just enough to read over; heavy blur would hide the glass doing its work.
    private func softened(_ img: CGImage?) -> CGImage? {
        guard let img else { return nil }
        let ci = CIImage(cgImage: img).clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: CIImage(cgImage: img).extent)
        return Self.ciContext.createCGImage(ci, from: ci.extent)
    }
    private static let ciContext = CIContext()

    private func layoutStatus() {
        let f = screen.frame, h = menuInset
        statusPanel.setFrame(CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true)
        statusPanel.contentView?.frame = CGRect(origin: .zero, size: CGSize(width: f.width, height: h))
        let sr = statusPanel.contentView!.layer!.sublayers!.first { $0.name == "root" }!
        sr.frame = CGRect(x: 0, y: 0, width: f.width, height: h)
        statusWall.frame = CGRect(origin: .zero, size: f.size)
        clock.frame = CGRect(x: 18, y: (h - 16) / 2, width: 300, height: 18)
        batteryGlyph.frame = CGRect(x: f.width - 44, y: (h - 16) / 2, width: 28, height: 16)
        statusRight.frame = CGRect(x: f.width - 130, y: (h - 16) / 2, width: 82, height: 18)
        wifiGlyph.frame = CGRect(x: f.width - 156, y: (h - 14) / 2, width: 20, height: 14)
        statusPanel.orderFrontRegardless()
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
            await MainActor.run {
                guard let self else { return }
                self.wallpaper.contents = img; self.statusWall.contents = img
                if self.mode != .app { self.withBackdrop { self.setDockBackdrop($0) } } // the Dock's glass refracts this
            }
        }
    }

    // MARK: home grid

    private var gridLeft: CGFloat { (W - CGFloat(cols) * cellW) / 2 }

    private func normalize() {
        var i = 0
        while i < layout.pages.count {
            let over = flow(layout.pages[i], cols: cols, rows: rows).overflow
            if !over.isEmpty {
                let moved = Set(over.map(\.key))
                layout.pages[i].removeAll { moved.contains($0.key) }
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
            // The glass itself lives in `glassHost`, above the page layers; this holds the mini icons.
            let g = makeGlass(glassRect(f), radius: 20, lens: Prefs.current.folderLens)
            glassHost.addSubview(g.view); folderGlass[item.key] = g.view
            let mini = (f.width - 20) / 3
            for (i, p) in folder.apps.prefix(9).enumerated() {
                let m = CALayer(); m.frame = CGRect(x: 7 + CGFloat(i % 3) * (mini + 3), y: 7 + CGFloat(i / 3) * (mini + 3), width: mini, height: mini)
                m.contents = apps[p]?.icon; m.contentsGravity = .resizeAspect; g.content.addSublayer(m)
            }
            l.addSublayer(label(folder.name, width: f.width, y: f.height + 6))
        case .widget(let title, _, _):
            // macOS draws the widget's content; the glass behind it is Apple's. The capture's black backing
            // is removed in RealWidgets, which keeps the text and graphics macOS rendered.
            let size = liveWidgets[title]?.frame.size ?? f.size
            let k = min(f.width / size.width, f.height / size.height)
            let fit = CGRect(x: f.midX - size.width * k / 2, y: f.midY - size.height * k / 2, width: size.width * k, height: size.height * k)
            let g = makeGlass(glassRect(fit), radius: 24 * k, lens: Prefs.current.widgetLens)
            glassHost.addSubview(g.view); folderGlass[item.key] = g.view
            let c = CALayer(); c.frame = g.content.bounds; c.contents = widgetImages[title]; c.contentsGravity = .resizeAspect
            g.content.addSublayer(c); widgetLayers[item.key] = c
            l.shadowOpacity = 0
            l.addSublayer(label(RealWidgets.displayName(title), width: f.width, y: f.height + 4))
        }
        let badge = CALayer(); badge.frame = CGRect(x: -8, y: -8, width: 24, height: 24); badge.cornerRadius = 12; badge.name = "badge"
        badge.backgroundColor = NSColor(calibratedWhite: 0.25, alpha: 0.95).cgColor; badge.isHidden = !editing
        let minus = CALayer(); minus.frame = CGRect(x: 6, y: 11, width: 12, height: 2); minus.backgroundColor = NSColor.white.cgColor; badge.addSublayer(minus)
        l.addSublayer(badge)
        if editing { wiggle(l) }
        if !Prefs.current.labels { l.sublayers?.filter { $0 is CATextLayer }.forEach { $0.isHidden = true } }
        return l
    }

    /// AppKit coordinates of a page-space rect inside `glassHost`, which pans with the pages.
    private func glassRect(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: H - f.maxY, width: f.width, height: f.height) }

    private func wiggle(_ l: CALayer) {
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = [-0.022, 0.022, -0.022]; a.duration = 0.26; a.repeatCount = .infinity
        a.timeOffset = Double.random(in: 0..<0.26)
        l.add(a, forKey: "wiggle")
    }

    private func rebuildHome() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pagesLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        folderGlass.values.forEach { $0.removeFromSuperview() }; folderGlass = [:]; widgetLayers = [:]
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
                folderGlass[item.key]?.frame = glassRect(f)
            }
        }
        updateDots()
    }

    private func applyPageOffset() {
        pagesLayer.setValue(pageOffset, forKeyPath: "sublayerTransform.translation.x")
        glassHost.layer?.setValue(pageOffset, forKeyPath: "sublayerTransform.translation.x")
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
        glassHost.layer?.spring("sublayerTransform.translation.x", to: pageOffset, damping: 30, stiffness: 240)
        updateDots()
    }

    private func item(atPageSpace p: CGPoint) -> HomeItem? {
        layout.pages[page].first { tileFrames[$0.key]?.insetBy(dx: -18, dy: -10).contains(p) ?? false }
    }

    private func pagePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + CGFloat(page) * W, y: p.y) }
    private func screenRect(_ pageRect: CGRect) -> CGRect { pageRect.offsetBy(dx: -CGFloat(page) * W, dy: 0) }

    /// Keeps the shell in step with the real windows. The window list is read off the main thread.
    private func syncWithWindows() {
        guard mode == .app else { return }
        let display = cgFrame
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let list = Windows.onTablet(display)
            DispatchQueue.main.async {
                guard let self, self.mode == .app else { return }
                if Date() > self.launchUntil, list.isEmpty { self.showHome(animated: true); return }
                // A full-screen window owns the whole display, including the status bar area.
                let full = list.first.map { $0.frame.minY <= display.minY + 1 && $0.frame.height >= display.height - 2 } ?? false
                guard full != self.fullscreenWindow else { return }
                self.setFullscreen(full)
            }
        }
    }

    private func setFullscreen(_ on: Bool) {
        fullscreenWindow = on
        stateLock.lock(); _fullscreen = on; stateLock.unlock()
        if on { statusPanel.orderOut(nil); pill.orderOut(nil) } else if !menuShown { statusPanel.orderFrontRegardless(); pill.orderFrontRegardless() }
    }

    /// Re-reads macOS's real widgets. They're drawn by macOS, so this only ever mirrors them.
    private func refreshWidgets() {
        guard mode == .home else { return }
        Task { [weak self] in
            let list = await RealWidgets.windows()
            var images: [String: CGImage] = [:]
            for w in list { if let t = w.title, let i = await RealWidgets.image(w) { images[t] = i } }
            await MainActor.run { self?.applyWidgets(list, images) }
        }
    }

    private func applyWidgets(_ list: [SCWindow], _ images: [String: CGImage]) {
        liveWidgets = Dictionary(list.compactMap { w in w.title.map { ($0, w) } }, uniquingKeysWith: { a, _ in a })
        widgetImages = images
        let specs = list.compactMap { w -> (title: String, w: Int, h: Int)? in
            guard let t = w.title else { return nil }
            return (t, max(2, Int((w.frame.width / 110).rounded())), max(2, Int((w.frame.height / 100).rounded())))
        }
        let before = layout.pages.flatMap { $0 }.map(\.key)
        layout.sync(widgets: specs)
        if layout.pages.flatMap({ $0 }).map(\.key) != before { rebuildHome(); save(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for item in layout.pages.flatMap({ $0 }) { // every page: a widget on another page must not be blank when you reach it
            if case .widget(let t, _, _) = item { widgetLayers[item.key]?.contents = images[t] }
        }
        CATransaction.commit()
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
        if case .widget(let t, _, _) = item { layout.hiddenWidgets.append(t) }
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
        let dim = CALayer(); dim.frame = CGRect(x: 0, y: 0, width: W, height: H); dim.opacity = 0; dim.contentsGravity = .resize
        dim.contents = softened(root.snapshot())
        overlayPanel.orderFrontRegardless(); overlay.addSublayer(dim); folderDim = dim
        dim.spring("opacity", to: 1, damping: 30, stiffness: 200)

        let perRow = 5, cell: CGFloat = 104, rowsN = max(1, Int(ceil(Double(f.apps.count) / Double(perRow))))
        let target = CGRect(x: (W - CGFloat(perRow) * cell - 48) / 2, y: (H - CGFloat(rowsN) * 112 - 92) / 2, width: CGFloat(perRow) * cell + 48, height: CGFloat(rowsN) * 112 + 92)
        // Real glass grows out of the folder icon.
        let g = makeGlass(glassRect(target).offsetBy(dx: 0, dy: 0), radius: 38, lens: Prefs.current.folderLens)
        overlayPanel.contentView?.addSubview(g.view); folderPanel = g.view; folderRect = target
        let p = g.content
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
        let gl = g.view.layer!
        gl.setValue(rect.width / target.width, forKeyPath: "transform.scale")
        gl.spring("transform.scale", to: 1.0, damping: 26, stiffness: 260)
    }

    private func closeFolder() {
        guard let pos = folderPos, let p = folderPanel else { return }
        finishRename()
        let key = layout.pages[safe: pos.page]?[safe: pos.index]?.key
        let rect = key.flatMap { tileFrames[$0] }.map(screenRect) ?? CGRect(x: W / 2 - 38, y: H / 2 - 38, width: 76, height: 76)
        let dim = folderDim
        p.layer?.spring("transform.scale", to: rect.width / folderRect.width, damping: 30, stiffness: 320)
        dim?.spring("opacity", to: 0, damping: 30, stiffness: 240)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { p.removeFromSuperview(); dim?.removeFromSuperlayer() }
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
        let title = text(26, .bold); title.string = "macOS Widget'ları"; title.alignmentMode = .center; title.frame = CGRect(x: 0, y: 44, width: W, height: 36); g.addSublayer(title)
        galleryCards = []
        var x: CGFloat = 40
        for t in layout.hiddenWidgets where liveWidgets[t] != nil {
            let f = liveWidgets[t]!.frame
            let c = CALayer(); c.frame = CGRect(x: x, y: 120, width: f.width, height: f.height); c.contents = widgetImages[t]; c.contentsGravity = .resizeAspect
            g.addSublayer(c); galleryCards.append((t, c.frame)); x += f.width + 30
        }
        if galleryCards.isEmpty {
            let e = text(16, .medium); e.string = "Yeni widget için macOS masaüstünde \"Widget'ları Düzenle\"yi kullan"; e.alignmentMode = .center; e.frame = CGRect(x: 0, y: H / 2, width: W, height: 26); g.addSublayer(e)
        }
    }

    private func closeGallery() { gallery?.removeFromSuperlayer(); gallery = nil; galleryCards = [] }

    private func addWidget(_ title: String) {
        layout.hiddenWidgets.removeAll { $0 == title }
        closeGallery()
        refreshWidgetsNow()
    }

    private func refreshWidgetsNow() {
        let m = mode; mode = .home; refreshWidgets(); mode = m
    }

    // MARK: Settings app

    /// Hooks into the Mac side of the app; set by AppController.
    var layoutIndex: (() -> Int)?
    var setLayoutIndex: ((Int) -> Void)?
    var setLinkMode: ((Session.LinkMode) -> Void)?

    private let settingsPath = "/MyTablet/Ayarlar.app"
    private var settingsPanel: SettingsPanel?, settingsGlass: NSGlassEffectView?, settingsDim: CALayer?

    private func settingsEntry() -> AppEntry? {
        let size = NSSize(width: 256, height: 256)
        let img = NSImage(size: size, flipped: false) { r in
            NSGradient(starting: NSColor(calibratedWhite: 0.62, alpha: 1), ending: NSColor(calibratedWhite: 0.38, alpha: 1))?
                .draw(in: NSBezierPath(roundedRect: r.insetBy(dx: 14, dy: 14), xRadius: 52, yRadius: 52), angle: -90)
            if let sym = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 120, weight: .semibold)) {
                let tinted = NSImage(size: sym.size, flipped: false) { q in sym.draw(in: q); NSColor.white.set(); q.fill(using: .sourceIn); return true }
                tinted.draw(in: CGRect(x: (r.width - sym.size.width) / 2, y: (r.height - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
            }
            return true
        }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return AppEntry(name: "Ayarlar", url: URL(fileURLWithPath: settingsPath), icon: cg)
    }

    private func prefSeg(_ title: String, _ options: [String], _ key: WritableKeyPath<ShellPrefs, Int>) -> SettingsPanel.Row {
        .segmented(title, options, get: { Prefs.current[keyPath: key] }, set: { [weak self] v in Prefs.current[keyPath: key] = v; self?.prefsChanged() })
    }
    private func prefGlass(_ title: String, _ key: WritableKeyPath<ShellPrefs, Bool>) -> SettingsPanel.Row {
        .segmented(title, ["Net", "Buzlu"], get: { Prefs.current[keyPath: key] ? 0 : 1 }, set: { [weak self] v in Prefs.current[keyPath: key] = v == 0; self?.prefsChanged() })
    }
    private func prefToggle(_ title: String, _ key: WritableKeyPath<ShellPrefs, Bool>) -> SettingsPanel.Row {
        .toggle(title, get: { Prefs.current[keyPath: key] }, set: { [weak self] v in Prefs.current[keyPath: key] = v; self?.prefsChanged() })
    }

    private func settingsRows() -> [SettingsPanel.Row] {
        let sizes = ["Küçük", "Orta", "Büyük"]
        let links: [Session.LinkMode] = [.auto, .usb, .wifi]
        return [
            .header("LIQUID GLASS"),
            prefGlass("Dock", \.dockLens), prefGlass("Kontrol Merkezi", \.controlCenterLens), prefGlass("Klasörler", \.folderLens),
            prefGlass("Klavye", \.keyboardLens), prefGlass("Widget'lar", \.widgetLens),
            .header("ANA EKRAN"),
            prefSeg("Simge Boyutu", sizes, \.iconSize), prefToggle("Simge Adları", \.labels),
            prefSeg("Dock Boyutu", sizes, \.dockSize), prefToggle("Dock'ta Son Uygulamalar", \.dockRecents),
            .header("DOKUNMA VE SES"),
            prefSeg("Kaydırma Hızı", ["Yavaş", "Normal", "Hızlı"], \.scrollSpeed), prefSeg("Uzun Basma", ["Kısa", "Normal", "Uzun"], \.longPress), prefToggle("Klavye Sesleri", \.keySounds),
            .header("MAC İLE BİRLİKTE KULLANIM"),
            prefToggle("Bağımsız Kullanım", \.independentInput),
            .note("Açıkken tablet, Mac'in imlecine ve aktif uygulamasına dokunmaz. Bir uygulama dokunmalara tepki vermezse kapatmayı dene."),
            .header("EKRAN VE BAĞLANTI"),
            .segmented("Ekran Alanı", ["Keskin", "Dengeli", "Geniş"], get: { [weak self] in self?.layoutIndex?() ?? 0 }, set: { [weak self] v in
                self?.closeSettings(); self?.setLayoutIndex?(v)
            }),
            .segmented("Bağlantı", ["Otomatik", "USB", "Wi-Fi"], get: { links.firstIndex(of: Session.linkMode) ?? 0 }, set: { [weak self] v in self?.setLinkMode?(links[v]) }),
            .header("SIFIRLA"),
            .button("Ana Ekran Düzenini Sıfırla", destructive: true) { [weak self] in self?.closeSettings(); self?.resetLayout() },
            .button("Ayarları Varsayılana Döndür", destructive: true) { [weak self] in Prefs.reset(); self?.closeSettings(); self?.prefsChanged() },
        ]
    }

    /// Several quick taps cost one rebuild, and the expensive backdrop blur stays off the main thread.
    private var prefsWork: DispatchWorkItem?
    private func prefsChanged() {
        prefsWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            self.layoutAll()
            self.withBackdrop { [weak self] in self?.setDockBackdrop($0) }
            guard self.settingsDim != nil else { return }
            let snap = self.root.snapshot()
            Log.write("prefs applied in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let blurred = self?.softened(snap)
                DispatchQueue.main.async {
                    CATransaction.begin(); CATransaction.setDisableActions(true); self?.settingsDim?.contents = blurred; CATransaction.commit()
                }
            }
        }
        prefsWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
    }

    private func openSettings() {
        guard settingsPanel == nil else { return }
        let dim = CALayer(); dim.frame = CGRect(x: 0, y: 0, width: W, height: H); dim.contentsGravity = .resize; dim.contents = softened(root.snapshot()); dim.opacity = 0
        overlayPanel.orderFrontRegardless(); overlay.addSublayer(dim); settingsDim = dim
        dim.spring("opacity", to: 1, damping: 30, stiffness: 240)
        let w = min(690, W - 80), h = H - menuInset - 34
        let f = CGRect(x: (W - w) / 2, y: menuInset + 14, width: w, height: h)
        let g = makeGlass(glassRect(f), radius: 34, lens: false)
        overlayPanel.contentView?.addSubview(g.view); settingsGlass = g.view
        let sp = SettingsPanel(frame: f, content: g.content, rows: settingsRows())
        sp.onDone = { [weak self] in self?.closeSettings() }
        settingsPanel = sp
        let l = g.view.layer!
        l.setValue(0.9, forKeyPath: "transform.scale")
        l.spring("transform.scale", to: 1.0, damping: 24, stiffness: 300)
    }

    private func closeSettings() {
        guard let g = settingsGlass else { return }
        let dim = settingsDim
        g.layer?.spring("transform.scale", to: 0.92, damping: 30, stiffness: 340)
        dim?.spring("opacity", to: 0, damping: 30, stiffness: 300)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; g.animator().alphaValue = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { g.removeFromSuperview(); dim?.removeFromSuperlayer() }
        settingsPanel = nil; settingsGlass = nil; settingsDim = nil
    }

    // MARK: dock

    /// Follows Apple's iPadOS 26 Dock: a compact floating glass capsule that fits only its icons.
    private func layoutDock() {
        dockRoot.sublayers?.forEach { $0.removeFromSuperlayer() }; dockTiles = []
        configureGlass(dockGlass, lens: Prefs.current.dockLens)
        let size = dockIcon, gap: CGFloat = 12, pad: CGFloat = 15, maxApps = max(1, Int((W - 120) / (size + gap)))
        // Recent apps always keep their section, even when the pinned row could fill the Dock.
        let hasRecents = shownRecents.contains { !layout.dock.contains($0) && apps[$0] != nil }
        let pinned = Array(layout.dock.prefix(hasRecents ? max(1, maxApps - 3) : maxApps))
        let recent = shownRecents.filter { !pinned.contains($0) && apps[$0] != nil }.prefix(max(0, min(3, maxApps - pinned.count)))
        let count = CGFloat(pinned.count + recent.count)
        let width = count * size + max(0, count - 1) * gap + 2 * pad + (recent.isEmpty ? 0 : 18)
        let height = size + 2 * pad
        let f = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.minY, width: width, height: height + 22)
        dockPanel.setFrame(f, display: true)
        dockPanel.contentView?.frame = CGRect(origin: .zero, size: f.size)
        dockGlass.frame = CGRect(x: 0, y: 12, width: width, height: height)
        dockRoot.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        var x = pad
        func add(_ path: String) {
            let l = CALayer(); l.frame = CGRect(x: x, y: pad, width: size, height: size); l.contents = apps[path]?.icon; l.contentsGravity = .resizeAspect
            dockRoot.addSublayer(l); dockTiles.append(DockTile(path: path, frame: l.frame, layer: l)); x += size + gap
        }
        pinned.forEach(add)
        if !recent.isEmpty {
            x += 4
            let s = CALayer(); s.frame = CGRect(x: x - gap / 2 - 1, y: 18, width: 1, height: height - 36); s.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
            dockRoot.addSublayer(s); x += 12
            recent.forEach(add)
        }
    }

    private var dockRect: CGRect { CGRect(x: dockPanel.frame.minX - screen.frame.minX + dockGlass.frame.minX, y: H - dockGlass.frame.maxY, width: dockGlass.frame.width, height: dockGlass.frame.height) }

    private func setDockBackdrop(_ img: CGImage?) {
        guard let img else { return }
        let k = CGFloat(img.width) / W
        let f = dockPanel.frame, y = screen.frame.maxY - f.maxY
        let crop = CGRect(x: (f.minX - screen.frame.minX) * k, y: y * k, width: f.width * k, height: f.height * k)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dockWall.frame = CGRect(origin: .zero, size: f.size); dockWall.contents = img.cropping(to: crop)
        CATransaction.commit()
    }

    private func setDock(_ on: Bool, animated: Bool = true) {
        let glass = dockGlass.layer!
        let show: () -> Void = { [self] in
            dockPanel.orderFrontRegardless()
            if animated {
                CATransaction.begin(); CATransaction.setDisableActions(true); glass.setValue(-(dockHeight + 10), forKeyPath: "transform.translation.y"); CATransaction.commit()
                glass.spring("transform.translation.y", to: 0, damping: 26, stiffness: 300)
            } else { glass.setValue(0, forKeyPath: "transform.translation.y") }
        }
        if on {
            withBackdrop { [weak self] img in self?.setDockBackdrop(img); show() }
        } else if dockPanel.isVisible {
            if animated {
                glass.spring("transform.translation.y", to: -(dockHeight + 10), damping: 30, stiffness: 320)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
                    guard let self, self._dockRect == nil else { return }
                    self.dockPanel.orderOut(nil)
                }
            } else { dockPanel.orderOut(nil) }
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
        kb.onSound = { [weak self] k in if Prefs.current.keySounds { self?.playSound?(k) } }
        let host = NSView(frame: CGRect(origin: .zero, size: f.size)); host.wantsLayer = true
        keyWall = CALayer(); keyWall.frame = host.bounds; keyWall.contentsGravity = .resize; host.layer!.addSublayer(keyWall)
        let glass = NSGlassEffectView(frame: host.bounds)
        glass.wantsLayer = true; glass.cornerRadius = 0; configureGlass(glass, lens: Prefs.current.keyboardLens)
        glass.contentView = kb
        host.addSubview(glass)
        keyPanel.contentView = host
    }

    func setKeyboard(_ on: Bool) {
        let visible = _kbRect != nil
        guard on != visible else { return }
        let h = keyPanel.frame.height
        let l = keyPanel.contentView!.layer!
        if on {
            kb.refreshLabels()
            withBackdrop { [weak self] img in
                guard let self, let img else { return }
                let k = CGFloat(img.width) / self.W
                CATransaction.begin(); CATransaction.setDisableActions(true)
                self.keyWall.contents = self.softened(img)?.cropping(to: CGRect(x: 0, y: (self.H - h) * k, width: self.W * k, height: h * k))
                CATransaction.commit()
            }
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
        wifiGlyph.contents = CWWiFiClient.shared().interface()?.rssiValue() != 0 ? tinted("wifi", 13) : nil
        var pct = 100, charging = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef], let s = list.first,
           let d = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any] {
            pct = d[kIOPSCurrentCapacityKey] as? Int ?? pct; charging = d[kIOPSIsChargingKey] as? Bool ?? false
        }
        statusRight.string = "%\(pct)"
        let level = pct > 87 ? "100" : pct > 62 ? "75" : pct > 37 ? "50" : pct > 12 ? "25" : "0"
        batteryGlyph.contents = tinted(charging ? "battery.100percent.bolt" : "battery.\(level)percent", 14)
    }

    /// iPadOS 26: pull down from the top to get the real menu bar for a moment.
    private func revealMenuBar() {
        menuShown = true
        statusPanel.orderOut(nil)
        menuTimer?.invalidate()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.hideMenuBar() }
    }

    private func hideMenuBar() {
        menuTimer?.invalidate()
        menuShown = false
        if !fullscreenWindow { statusPanel.orderFrontRegardless() }
    }

    /// Icons live in a layer and glass in views above it; they always appear and disappear together.
    private func setHomeVisible(_ on: Bool) { homeLayer.isHidden = !on; glassHost.isHidden = !on }

    private let desktopLevel = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    /// Home covers the windows; lowering it leaves just the wallpaper behind them.
    private func raiseHome() { main.level = .statusBar; main.alphaValue = 1; main.orderFrontRegardless(); statusPanel.orderFrontRegardless() }
    private func lowerHome() { main.level = desktopLevel; main.alphaValue = 1; setHomeVisible(false); main.orderFrontRegardless() }

    // MARK: mode transitions

    private func showHome(animated: Bool) {
        mode = .home
        hideMenuBar()
        setDock(true, animated: animated); pill.orderOut(nil); setKeyboard(false)
        switcherLayer.isHidden = true; emptyLabel.isHidden = true
        setHomeVisible(true)
        raiseHome()
        refreshWidgets()
        if animated {
            homeLayer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
            homeLayer.opacity = 0.4
            homeLayer.spring("transform.scale", to: 1.0, damping: 26, stiffness: 240)
            homeLayer.spring("opacity", to: 1.0, damping: 30, stiffness: 240)
        }
    }

    /// Switches straight to the windowed desktop. Callers run this while something covers the change.
    private func enterApp() {
        mode = .app
        setDock(false, animated: false)
        if !fullscreenWindow { pill.orderFrontRegardless() }
        lowerHome()
        CATransaction.begin(); CATransaction.setDisableActions(true); homeLayer.opacity = 1; CATransaction.commit()
    }

    // MARK: launching

    private var usableArea: CGRect {
        let f = cgFrame, inset = menuInset
        return CGRect(x: f.minX, y: f.minY + inset, width: f.width, height: f.height - inset)
    }

    private func openWindow(for a: AppEntry) -> TabletWindow? {
        let id = Bundle(url: a.url)?.bundleIdentifier
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == id && id != nil }.map(\.processIdentifier))
        return Windows.onTablet(cgFrame).first { pids.contains($0.pid) }
    }

    private func launch(_ path: String, from rect: CGRect) {
        if path == settingsPath { exitEdit(); closeFolder(); openSettings(); return }
        guard let a = apps[path] else { return }
        launchUntil = Date().addingTimeInterval(5)
        exitEdit(); closeFolder()
        layout.recents = Array(([path] + (layout.recents ?? []).filter { $0 != path }).prefix(6)); save()
        // Already open on the tablet: just bring it forward, no splash.
        if let w = openWindow(for: a) { focusPid = w.pid; enterApp(); Windows.raise(w); layoutDock(); return }

        // The icon grows into the full screen; the real window replaces it once it's placed.
        let zoom = CALayer(); zoom.place(rect); zoom.cornerRadius = 18; zoom.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
        let glyph = CALayer(); glyph.contents = a.icon; glyph.contentsGravity = .resizeAspect; glyph.place(CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        zoom.addSublayer(glyph)
        overlayPanel.orderFrontRegardless(); overlay.addSublayer(zoom)
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        zoom.springFrame(full, damping: 28, stiffness: 200)
        zoom.spring("cornerRadius", to: 0, damping: 28, stiffness: 200)
        glyph.spring("position", to: NSValue(point: CGPoint(x: W / 2, y: H / 2)), damping: 28, stiffness: 200)

        // One timeline: the splash covers the screen, the desktop changes underneath it,
        // the window is placed underneath it, and only then does the splash fade once.
        var covered = false, placed = false
        func finish() {
            guard covered && placed else { return }
            launchUntil = .distantPast
            CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
            CATransaction.setCompletionBlock { zoom.removeFromSuperlayer() }
            zoom.opacity = 0
            CATransaction.commit()
            layoutDock()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            self?.enterApp(); covered = true; finish()
        }
        let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = !Prefs.current.independentInput && !MacActivity.isBusy
        let display = cgFrame, area = usableArea
        NSWorkspace.shared.openApplication(at: a.url, configuration: cfg) { app, err in
            guard let app else {
                Log.write("launch \(a.name) failed: \(String(describing: err))")
                DispatchQueue.main.async { placed = true; finish() }
                return
            }
            DispatchQueue.main.async { self.focusPid = app.processIdentifier }
            let cascade = Windows.onTablet(display).count
            Windows.adopt(pid: app.processIdentifier, display: display, area: area, cascade: cascade) { placed = true; finish() }
        }
    }

    // MARK: app switcher

    private func showSwitcher() {
        exitEdit()
        mode = .switcher
        setKeyboard(false); setDock(true); pill.orderOut(nil)
        setHomeVisible(false)
        switcherLayer.isHidden = false
        raiseHome()
        rebuildCards()
    }

    /// Exposé: every window on the wallpaper in a grid, with the Dock still there.
    private func rebuildCards() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        switcherLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        switcherLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
        cards = []
        switcherOffset = 0
        let list = Windows.onTablet(cgFrame)
        emptyLabel.isHidden = !list.isEmpty
        let n = max(1, list.count), perRow = min(3, n), rowsN = Int(ceil(Double(n) / 3))
        let areaW = W - 120, areaH = H - menuInset - dockHeight - 60
        let cellW = areaW / CGFloat(perRow), cellH = areaH / CGFloat(rowsN)
        for (i, w) in list.enumerated() {
            let s = min((cellW - 28) / w.frame.width, (cellH - 28) / w.frame.height, 0.75)
            let cw = w.frame.width * s, ch = w.frame.height * s
            let cx = 60 + (CGFloat(i % 3) + 0.5) * cellW, cy = menuInset + 24 + (CGFloat(i / 3) + 0.5) * cellH
            let c = CALayer(); c.frame = CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch); c.cornerRadius = 14; c.masksToBounds = true
            c.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 1).cgColor; c.contentsGravity = .resizeAspect
            let label = CALayer(); label.frame = .zero
            switcherLayer.addSublayer(c)
            cards.append(Card(win: w, layer: c, label: label, x: c.frame.minX))
            c.transform = CATransform3DMakeScale(0.86, 0.86, 1)
            c.spring("transform.scale", to: 1.0, damping: 24, stiffness: 260 - CGFloat(min(i, 4)) * 20)
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
            setHomeVisible(true); switcherLayer.isHidden = true
            raiseHome()
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
                self.lowerHome()
                self.pill.orderFrontRegardless()
            }
        }
    }

    // MARK: Control Center

    private struct CCTile { let frame: CGRect; let badge: CALayer; let subtitle: CATextLayer?; let color: NSColor; let active: () -> Bool; let action: () -> Void; let toggle: Bool }
    private struct CCSlider { let frame: CGRect; let fill: CALayer; let get: () -> Double; let set: (Double) -> Void }
    private var ccTiles: [CCTile] = [], ccSliders: [CCSlider] = []
    private let ccSize = CGSize(width: 452, height: 448)

    private var ccLeft: CGFloat { W - ccSize.width - 20 }
    private var ccTop: CGFloat { menuInset + 14 }

    private func badgeColor(_ t: CCTile) -> CGColor { (t.toggle && !t.active() ? NSColor.white.withAlphaComponent(0.22) : t.color).cgColor }

    /// Modules follow iOS/iPadOS 26: glass tiles with a coloured round badge and a title and state beneath.
    private func buildControlCenter() {
        ccSheet.subviews.forEach { $0.removeFromSuperview() }; ccTiles = []; ccSliders = []
        ccSheet.frame = CGRect(x: ccLeft, y: H - ccTop - ccSize.height, width: ccSize.width, height: ccSize.height)
        let display = displayID
        func flip(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: ccSize.height - f.maxY, width: f.width, height: f.height) }
        func tile(_ f: CGRect, _ symbol: String, _ caption: String, _ color: NSColor, toggle: Bool, state: Bool, active: @escaping () -> Bool, action: @escaping () -> Void) {
            let g = makeGlass(flip(f), radius: min(34, f.height / 2.4), lens: Prefs.current.controlCenterLens); ccSheet.addSubview(g.view)
            let big = f.height >= 120
            let d: CGFloat = big ? 44 : 40
            let badge = CALayer(); badge.frame = CGRect(x: big ? 16 : (f.width - d) / 2, y: big ? 16 : (f.height - d) / 2, width: d, height: d); badge.cornerRadius = d / 2
            let glyph = CALayer(); glyph.frame = badge.bounds.insetBy(dx: 10, dy: 10); glyph.contentsGravity = .resizeAspect; glyph.contents = tinted(symbol, 18); badge.addSublayer(glyph)
            g.content.addSublayer(badge)
            var sub: CATextLayer?
            if big {
                let t = statusText(14, .semibold); t.string = caption; t.frame = CGRect(x: 16, y: f.height - 52, width: f.width - 24, height: 18); g.content.addSublayer(t)
                if state { let s = statusText(12, .regular); s.opacity = 0.75; s.frame = CGRect(x: 16, y: f.height - 32, width: f.width - 24, height: 16); g.content.addSublayer(s); sub = s }
            }
            ccTiles.append(CCTile(frame: f, badge: badge, subtitle: sub, color: color, active: active, action: action, toggle: toggle))
        }
        let t: CGFloat = 140, g: CGFloat = 12
        tile(CGRect(x: 0, y: 0, width: t, height: t), "wifi", "Wi-Fi", .systemBlue, toggle: true, state: true, active: { SystemControls.wifiOn }) { SystemControls.setWifi(!SystemControls.wifiOn) }
        tile(CGRect(x: t + g, y: 0, width: t, height: t), "dot.radiowaves.left.and.right", "Bluetooth", .systemBlue, toggle: true, state: true, active: { SystemControls.bluetoothOn }) { SystemControls.setBluetooth(!SystemControls.bluetoothOn) }
        tile(CGRect(x: 0, y: t + g, width: t, height: t), "moon.fill", "Koyu Görünüm", .systemIndigo, toggle: true, state: true, active: { SystemControls.darkMode }) { SystemControls.setDarkMode(!SystemControls.darkMode) }
        tile(CGRect(x: t + g, y: t + g, width: t, height: t), "keyboard", "Klavye", .systemGray, toggle: true, state: true, active: { [weak self] in self?._kbRect != nil }) { [weak self] in
            guard let self else { return }
            self.setKeyboard(self._kbRect == nil)
        }
        let my = 2 * (t + g), mw = (2 * t + g - 2 * g) / 3
        tile(CGRect(x: 0, y: my, width: mw, height: 72), "backward.fill", "", .clear, toggle: false, state: false, active: { false }) { SystemControls.press(.previous) }
        tile(CGRect(x: mw + g, y: my, width: mw, height: 72), "playpause.fill", "", .clear, toggle: false, state: false, active: { false }) { SystemControls.press(.play) }
        tile(CGRect(x: 2 * (mw + g), y: my, width: mw, height: 72), "forward.fill", "", .clear, toggle: false, state: false, active: { false }) { SystemControls.press(.next) }
        tile(CGRect(x: 0, y: my + 72 + g, width: 2 * t + g, height: 72), "camera.viewfinder", "Ekran Resmi", .systemGray, toggle: false, state: false, active: { false }) { [weak self] in
            self?.closeControlCenter()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SystemControls.screenshot(displayID: display) }
        }
        func slider(_ x: CGFloat, _ symbol: String, get: @escaping () -> Double, set: @escaping (Double) -> Void) {
            let f = CGRect(x: x, y: 0, width: 66, height: ccSize.height)
            let gv = makeGlass(flip(f), radius: 33, lens: Prefs.current.controlCenterLens); ccSheet.addSubview(gv.view)
            let fill = CALayer(); fill.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
            let clip = CALayer(); clip.frame = CGRect(origin: .zero, size: f.size); clip.cornerRadius = 33; clip.masksToBounds = true; clip.addSublayer(fill); gv.content.addSublayer(clip)
            let glyph = CALayer(); glyph.frame = CGRect(x: 19, y: f.height - 44, width: 28, height: 26); glyph.contentsGravity = .resizeAspect; glyph.contents = tinted(symbol, 20, .darkGray); gv.content.addSublayer(glyph)
            ccSliders.append(CCSlider(frame: f, fill: fill, get: get, set: set))
        }
        slider(2 * t + g + 16, "speaker.wave.2.fill", get: { Double(SystemControls.volume) }, set: { SystemControls.volume = Float($0) })
        slider(2 * t + g + 16 + 66 + 12, "sun.max.fill", get: { [weak self] in self?.tabletBrightness ?? 0.5 }, set: { [weak self] v in
            self?.tabletBrightness = v; SystemControls.setTabletBrightness(v)
        })
        ccSheet.layer?.setValue(ccHiddenOffset, forKeyPath: "transform.translation.y")
    }

    private var ccHiddenOffset: CGFloat { ccSize.height + ccTop + 30 }
    private var tabletBrightness = 0.5

    private func setFill(_ s: CCSlider, _ v: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = s.frame.height * CGFloat(max(0, min(1, v)))
        s.fill.frame = CGRect(x: 0, y: s.frame.height - h, width: s.frame.width, height: h)
        CATransaction.commit()
    }

    private func refreshControlCenter() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for t in ccTiles where t.toggle { t.badge.backgroundColor = badgeColor(t); t.subtitle?.string = t.active() ? "Açık" : "Kapalı" }
        CATransaction.commit()
        for s in ccSliders { setFill(s, s.get()) }
    }

    private func prepareControlCenter() {
        guard !ccPanel.isVisible else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let b = SystemControls.tabletBrightness()
            DispatchQueue.main.async { self?.tabletBrightness = b; self?.refreshControlCenter() }
        }
        refreshControlCenter()
        withBackdrop { [weak self] img in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true); self.ccWall.contents = self.softened(img); CATransaction.commit()
        }
        ccPanel.orderFrontRegardless()
    }

    private func trackControlCenter(_ down: CGFloat) {
        let p = max(0, min(1, down / (ccSize.height * 0.8)))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ccSheet.layer?.setValue(ccHiddenOffset * (1 - p), forKeyPath: "transform.translation.y")
        ccWall.opacity = Float(p)
        CATransaction.commit()
    }

    private func openControlCenter() {
        prepareControlCenter()
        ccSheet.layer?.spring("transform.translation.y", to: 0, damping: 24, stiffness: 260)
        ccWall.spring("opacity", to: 1, damping: 30, stiffness: 260)
        publish(dock: nil, kb: nil, cc: true)
    }

    private func closeControlCenter() {
        ccSheet.layer?.spring("transform.translation.y", to: ccHiddenOffset, damping: 30, stiffness: 300)
        ccWall.spring("opacity", to: 0, damping: 30, stiffness: 300)
        publish(dock: nil, kb: nil, cc: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self._ccOpen else { return }
            self.ccPanel.orderOut(nil)
        }
    }

    private var ccOrigin: CGPoint { CGPoint(x: ccLeft, y: ccTop) }

    // MARK: touch routing (coordinates are points from the top-left of the tablet display)

    /// Runs on the gesture queue at the first finger of a sequence: does the shell own it?
    func captures(_ p: CGPoint, height: CGFloat) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if p.y >= height - bottomZone(_fullscreen) { return true }
        if _ccOpen { return true }
        if p.y < topZone(_fullscreen) && !menuShownSafe && (!_fullscreen || p.x > cgWidth * 0.55) { return true } // status bar: Control Center on the right, menu bar on the left
        if _mode != .app { return true }
        if let r = _kbRect, r.contains(p) { return true }
        if _dockRect != nil { return true } // a tap outside dismisses the dock
        // Windows float over the wallpaper: only touches on a real window go to an app.
        let b = CGDisplayBounds(displayID)
        return HitTest.target(at: CGPoint(x: b.minX + p.x, y: b.minY + p.y)) == nil
    }
    private var menuShownSafe: Bool { menuShown }
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
        if p.y < topZone(fullscreenWindow) && !menuShown && (!fullscreenWindow || p.x > W * 0.55) { if p.x > W * 0.55 { touch = .topEdge; prepareControlCenter() } else { touch = .menuEdge }; return }
        if let sp = settingsPanel {
            if sp.frame.contains(p) { sp.began(CGPoint(x: p.x - sp.frame.minX, y: p.y - sp.frame.minY)); touch = .settings } else { touch = .settingsOutside }
            return
        }
        if folderPos != nil { touch = folderRect.contains(p) ? .folder : .folderOutside; return }
        if gallery != nil { touch = .gallery; return }
        if let r = kbR, r.contains(p) {
            kb.touchDown(at: CGPoint(x: p.x - r.minX, y: p.y - r.minY)); touch = .keyboard; return
        }
        if p.y >= H - bottomZone(fullscreenWindow) && dockR?.contains(p) != true { touch = .edge; beginLiveCard(); return }
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
        if case .keyboard = touch, downPoint.y >= H - bottomZone(fullscreenWindow), dy < -45 {
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
        case .settings: if let sp = settingsPanel { sp.moved(CGPoint(x: p.x - sp.frame.minX, y: p.y - sp.frame.minY)) }
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
            if dy > 70 { openControlCenter() } else {
                closeControlCenter()
                if !dragging, mode == .app, downPoint.y >= menuInset { passTap?(downPoint) }
            }
        case .menuEdge:
            if dy > 40 { if mode == .app { revealMenuBar() } } else if !dragging, mode == .app, downPoint.y >= menuInset { passTap?(downPoint) }
        case .keyboard: kb.touchUp()
        case .drag(let item): drop(item, at: p)
        case .cc:
            guard !dragging else { if dy < -40 { closeControlCenter() }; return }
            let local = CGPoint(x: p.x - ccOrigin.x, y: p.y - ccOrigin.y)
            if let t = ccTiles.first(where: { $0.frame.contains(local) }) {
                t.action()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshControlCenter() }
            } else if !CGRect(origin: .zero, size: ccSize).contains(local) { closeControlCenter() }
        case .ccSlider: break
        case .folderOutside: closeFolder()
        case .settings: if let sp = settingsPanel { sp.ended(CGPoint(x: p.x - sp.frame.minX, y: p.y - sp.frame.minY)) }
        case .settingsOutside: closeSettings()
        case .folder: folderTapped(p)
        case .gallery:
            if let c = galleryCards.first(where: { $0.frame.contains(p) }) { addWidget(c.title) } else { closeGallery() }
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
            }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    if Windows.onTablet(self.cgFrame).isEmpty { self.showHome(animated: true) } else { self.rebuildCards() }
                }
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
        case .widget(let t, _, _): if let p = RealWidgets.appPath(t), apps[p] != nil { launch(p, from: screenRect(f)) }
        }
    }

    private func folderTapped(_ p: CGPoint) {
        if dragging { return }
        guard let pos = folderPos else { return }
        if p.y - folderRect.minY < 60 { if editing || renaming { beginRename() }; return }
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

    /// iPadOS keyboard behaviour: it appears when you tap an editable field and goes when focus leaves one.
    /// Tapping elsewhere while a field keeps focus must not bring back a keyboard the user dismissed.
    func tappedInApp(_ target: InputTarget?, at point: CGPoint) {
        guard let target else { return }
        DispatchQueue.main.async { self.focusPid = target.pid }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let focused = Windows.textFocused(pid: target.pid)
            let onField = HitTest.isEditable(at: point)
            DispatchQueue.main.async {
                guard self.mode == .app else { return }
                if !focused { self.setKeyboard(false) } else if onField { self.setKeyboard(true) }
            }
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
