import CoreMedia
import Foundation
import IOKit.pwr_mgt

struct Stats {
    var fps = 0, kbps = 0, skipped = 0
    var latencyMs = 0.0, rttMs = 0.0
}

/// Pipeline: capture -> credit gate -> encoder -> socket; tablet acks return credits.
final class Session {
    private let layout: DisplayLayout
    private let port: UInt16 = 27183
    private let capturer = Capturer()
    private var encoder: Encoder?
    private var link: Link?
    let gestures = GestureEngine()

    private let q = DispatchQueue(label: "session", qos: .userInteractive)
    /// Enough frames to cover the round trip: 2 suits USB, Wi-Fi's longer path would cap the frame rate.
    private var maxInFlight: Int { wireless ? 5 : 2 }
    private var lastAck = 0.0
    private var inFlight = 0, seq: UInt32 = 0
    private var pending: (CVPixelBuffer, UInt64)?
    private var latest: CVPixelBuffer?
    private var refine = 0
    private var refineTimer: DispatchSourceTimer?

    private var sentAt = [UInt32: UInt64]()
    private var frames = 0, bytes = 0, skipped = 0, latencySum = 0.0, latencyN = 0, rtt = 0.0
    private var statsTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    var onStats: ((Stats) -> Void)?
    var onState: ((String) -> Void)?
    private var running = true

    private let bitrate = 40_000_000
    private var wireless = false, currentBitrate = 40_000_000
    private var minRtt = Double.infinity
    private static let width = 1920, height = 1200

    init(layout: DisplayLayout) { self.layout = layout }

    func start(display: VirtualDisplay) {
        gestures.setFrame(display.bounds)
        gestures.boundsProvider = { [weak display] in display?.bounds ?? .zero }
        capturer.onFrame = { [weak self] pb, t in self?.q.async { self?.captured(pb, t) } }
        capturer.onIdle = { [weak self] in self?.q.async { self?.idle() } }
        Task {
            do { try await capturer.start(displayID: display.id, width: Self.width, height: Self.height) }
            catch { Log.write("capture start failed: \(error)"); onState?("Ekran kaydı izni gerekli") }
        }
        startStats()
        Thread.detachNewThread { [weak self] in self?.connectLoop() }
    }

    /// Drops the link; the connect loop picks the route again.
    func reconnect() { link?.close_() }

    func stop() {
        running = false
        link?.close_()
        Task { await capturer.stop() }
        statsTimer?.cancel(); pingTimer?.cancel(); refineTimer?.cancel()
    }

    // MARK: connection

    enum LinkMode: String { case auto, usb, wifi }

    static var linkMode: LinkMode {
        get {
            let v = ProcessInfo.processInfo.environment["MYTABLET_LINK"] ?? UserDefaults.standard.string(forKey: "linkMode") ?? ""
            return LinkMode(rawValue: v) ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "linkMode") }
    }

    private let browser = TabletBrowser()

    private func connectLoop() {
        browser.start()
        while running {
            let mode = Self.linkMode
            if mode != .wifi, Adb.connected {
                if let l = connectUSB() { run(l, label: "USB") }
                continue
            }
            if mode != .usb, let psk = Pairing.key, let l = connectWireless(psk) {
                run(l, label: "Wi-Fi")
                continue
            }
            onState?(Pairing.key == nil && mode != .usb ? "Wi-Fi için bir kez USB ile bağla" : "Tablet bekleniyor…")
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func connectUSB() -> Link? {
        Adb.ensureInstalled()
        Adb.launchReceiver(port: port)
        var l: Link?
        for _ in 0..<40 where running && l == nil {
            l = Link(port: port)
            if l == nil { Thread.sleep(forTimeInterval: 0.25) }
        }
        guard let l else { return nil }
        // USB is the trusted channel, so the wireless key travels here and nowhere else.
        l.sendPairingKey(Pairing.keyCreatingIfNeeded())
        if let ip = Adb.wifiAddress() { Pairing.lastHost = ip }
        return l
    }

    private func connectWireless(_ psk: Data) -> Link? {
        for host in [browser.host, Pairing.lastHost].compactMap({ $0 }) {
            if let l = Link(host: host, port: port, psk: psk) { Pairing.lastHost = host; return l }
        }
        return nil
    }

    private func run(_ l: Link, label: String) {
        let done = DispatchSemaphore(value: 0)
        l.onTouch = { [weak self] e in self?.gestures.handle(e) }
        l.onAck = { [weak self] s, _ in self?.q.async { self?.acked(s) } }
        l.onPong = { [weak self] t in self?.q.async { guard let self else { return }; self.rtt = Double(Clock.now() &- t) / 1e6; self.minRtt = min(self.minRtt * 1.02, self.rtt) } }
        l.onBrightness = { v in SystemControls.reportTabletBrightness(v) }
        l.onClosed = { done.signal() }
        SystemControls.sendTabletBrightness = { [weak l] v in l?.sendBrightness(v) }
        q.sync { attach(l) }
        l.startReading()
        onState?("Bağlı · \(label)")
        Log.write("link up: \(label)")
        var sleep: IOPMAssertionID = 0
        // The stream dies if the Mac's displays sleep, which matters most when nobody is touching the Mac.
        IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "MyTablet streaming" as CFString, &sleep)
        let watchdog = l.isWireless ? nil : keepReceiverInFront()
        let upgrade = l.isWireless ? switchToUSBWhenPlugged(l) : nil
        done.wait()
        watchdog?.cancel(); upgrade?.cancel()
        IOPMAssertionRelease(sleep)
        q.sync { detach() }
        onState?("Bağlantı kesildi")
        Log.write("link down: \(label)")
        Thread.sleep(forTimeInterval: 0.5)
    }

    func playSound(_ kind: Int) { q.async { self.link?.sendSound(kind) } }

    /// A cable beats the air: plugging in during a Wi-Fi session moves the stream to USB.
    private func switchToUSBWhenPlugged(_ l: Link) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak l] in if Self.linkMode == .auto, Adb.connected { l?.close_() } }
        t.resume()
        return t
    }

    /// The tablet always comes back to the desktop: anything that takes the receiver off screen is undone.
    private func keepReceiverInFront() -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 3, repeating: 2)
        t.setEventHandler {
            let top = Adb.run(["shell", "dumpsys activity activities | grep -m1 topResumedActivity"]).1
            let awake = Adb.run(["shell", "dumpsys power | grep -m1 mWakefulness="]).1.contains("Awake")
            if !awake || !top.contains("dev.mytablet") {
                Log.write("receiver off screen, restoring (\(awake ? top : "asleep"))")
                Adb.run(["shell", "input keyevent KEYCODE_WAKEUP; am start -n dev.mytablet/.MainActivity"])
            }
        }
        t.resume()
        return t
    }

    private func attach(_ l: Link) {
        link = l; inFlight = 0; seq = 0; sentAt.removeAll()
        wireless = l.isWireless
        currentBitrate = wireless ? 12_000_000 : bitrate
        do {
            let e = try Encoder(width: Self.width, height: Self.height, bitrate: currentBitrate)
            e.onFrame = { [weak self] f in self?.q.async { self?.encoded(f) } }
            e.onDropped = { [weak self] in self?.q.async { self?.frameDropped() } }
            encoder = e
        } catch { Log.write("encoder: \(error)") }
        if let latest { submit(latest, Clock.now()) }
    }

    private func detach() { link = nil; encoder = nil; pending = nil; refineTimer?.cancel(); refineTimer = nil }

    // MARK: pipeline

    private func captured(_ pb: CVPixelBuffer, _ t: UInt64) {
        latest = pb; refine = 0
        refineTimer?.cancel(); refineTimer = nil
        submit(pb, t)
    }

    private func submit(_ pb: CVPixelBuffer, _ t: UInt64) {
        guard encoder != nil else { return }
        if inFlight >= maxInFlight {
            if pending != nil { skipped += 1 }
            pending = (pb, t)
            return
        }
        inFlight += 1
        encoder?.encode(pb, captureNs: t)
    }

    private func encoded(_ f: EncodedFrame) {
        seq &+= 1
        sentAt[seq] = f.captureNs
        link?.sendVideo(f, seq: seq)
        frames += 1; bytes += f.data.count
    }

    private func frameDropped() {
        inFlight = max(0, inFlight - 1)
        if let (pb, t) = pending { pending = nil; submit(pb, t) }
    }

    private func acked(_ s: UInt32) {
        lastAck = CFAbsoluteTimeGetCurrent()
        inFlight = max(0, inFlight - 1)
        if let t = sentAt.removeValue(forKey: s) {
            // Frame age when the tablet decoder finished, minus half the transport RTT for the ack's trip back.
            // Uses the best recent round trip: one slow ping must not make every frame look early.
            latencySum += max(0, Double(Clock.now() &- t) / 1e6 - min(rtt, minRtt) / 2); latencyN += 1
        }
        if let (pb, t) = pending { pending = nil; submit(pb, t) }
    }

    /// Screen went still: re-encode the last image a few times so rate control settles text to full sharpness.
    private func idle() {
        guard refineTimer == nil, let latest, refine == 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.06, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.refine += 1
            if self.refine > 5 { self.refineTimer?.cancel(); self.refineTimer = nil; return }
            // The first settle frame is a keyframe: a clean picture that can't carry ghosts of earlier motion.
            if self.refine == 1 { self.encoder?.requestKeyFrame() }
            self.submit(latest, Clock.now())
        }
        t.resume(); refineTimer = t
    }

    /// Wi-Fi capacity moves around constantly: back off as soon as frames queue, creep up while they don't.
    private func adaptBitrate(latency: Double, skipped: Int, fps: Int) {
        guard wireless, fps > 0 else { return }
        // Only delay says the air is full. Skipped frames just mean the screen changes faster than the path clears.
        if latency > 110 {
            currentBitrate = max(4_000_000, currentBitrate * 3 / 4)
        } else if latency < 70 {
            currentBitrate = min(30_000_000, currentBitrate * 27 / 25)
        } else { return }
        encoder?.setBitrate(currentBitrate)
        Log.write("wifi bitrate \(currentBitrate / 1_000_000) Mb/s (latency \(Int(latency)) ms, skipped \(skipped))")
    }

    /// Last resort: if frames are waiting and acks have stopped, a credit went missing. Never freeze over it.
    private func recoverIfStalled() {
        guard link != nil, inFlight > 0, CFAbsoluteTimeGetCurrent() - lastAck > 1.5 else { return }
        Log.write("stall recovered (inFlight \(inFlight))")
        inFlight = 0
        lastAck = CFAbsoluteTimeGetCurrent()
        encoder?.requestKeyFrame()
        if let latest { submit(latest, Clock.now()) }
    }

    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let s = Stats(fps: frames, kbps: bytes * 8 / 1000, skipped: skipped,
                          latencyMs: latencyN > 0 ? latencySum / Double(latencyN) : 0, rttMs: rtt)
            adaptBitrate(latency: s.latencyMs, skipped: s.skipped, fps: s.fps)
            recoverIfStalled()
            frames = 0; bytes = 0; skipped = 0; latencySum = 0; latencyN = 0
            onStats?(s)
        }
        t.resume(); statsTimer = t
        let p = DispatchSource.makeTimerSource(queue: q)
        p.schedule(deadline: .now() + 0.5, repeating: 0.5)
        p.setEventHandler { [weak self] in self?.link?.sendPing(Clock.now()) }
        p.resume(); pingTimer = p
    }
}
