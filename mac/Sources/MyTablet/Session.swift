import CoreMedia
import Foundation

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
    private let maxInFlight = 2
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

    func stop() {
        running = false
        link?.close_()
        Task { await capturer.stop() }
        statsTimer?.cancel(); pingTimer?.cancel(); refineTimer?.cancel()
    }

    // MARK: connection

    private func connectLoop() {
        while running {
            if !Adb.connected { onState?("Tablet bekleniyor…"); Thread.sleep(forTimeInterval: 1); continue }
            Adb.ensureInstalled()
            Adb.launchReceiver(port: port)
            var l: Link?
            for _ in 0..<40 where running && l == nil {
                l = Link(port: port)
                if l == nil { Thread.sleep(forTimeInterval: 0.25) }
            }
            guard let l else { continue }
            let done = DispatchSemaphore(value: 0)
            l.onTouch = { [weak self] e in self?.gestures.handle(e) }
            l.onAck = { [weak self] s, _ in self?.q.async { self?.acked(s) } }
            l.onPong = { [weak self] t in self?.q.async { self?.rtt = Double(Clock.now() &- t) / 1e6 } }
            l.onClosed = { done.signal() }
            q.sync { attach(l) }
            l.startReading()
            onState?("Bağlı")
            let watchdog = keepReceiverInFront()
            done.wait()
            watchdog.cancel()
            q.sync { detach() }
            onState?("Bağlantı kesildi")
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func playSound(_ kind: Int) { q.async { self.link?.sendSound(kind) } }

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
        do {
            let e = try Encoder(width: Self.width, height: Self.height, bitrate: bitrate)
            e.onFrame = { [weak self] f in self?.q.async { self?.encoded(f) } }
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

    private func acked(_ s: UInt32) {
        inFlight = max(0, inFlight - 1)
        if let t = sentAt.removeValue(forKey: s) {
            // Frame age when the tablet decoder finished, minus half the transport RTT for the ack's trip back.
            latencySum += Double(Clock.now() &- t) / 1e6 - rtt / 2; latencyN += 1
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
            self.submit(latest, Clock.now())
        }
        t.resume(); refineTimer = t
    }

    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let s = Stats(fps: frames, kbps: bytes * 8 / 1000, skipped: skipped,
                          latencyMs: latencyN > 0 ? latencySum / Double(latencyN) : 0, rttMs: rtt)
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
