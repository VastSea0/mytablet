import CoreGraphics
import AppKit
import Foundation

/// Turns raw multitouch into the same semantics macOS uses for direct touch:
/// tap = click, immediate pan = trackpad scroll with momentum, hold+move = drag,
/// long press = secondary click, two fingers = scroll / pinch / rotate.
final class GestureEngine {
    private enum Mode { case idle, pending, windowDrag, scrolling, dragging, consumed, twoPending, twoScroll, pinch, rotate, system }
    private let q = DispatchQueue(label: "gesture", qos: .userInteractive)
    private let inject = Injector()
    private var mode = Mode.idle
    private var frame = CGRect.zero

    private var start = CGPoint.zero, last = CGPoint.zero, startTime = 0.0, lastMoveTime = 0.0
    private var hasHeld = false
    private var velocity = CGVector.zero
    private var holdTimer: DispatchSourceTimer?
    private var momentum: DispatchSourceTimer?

    private var lastTapTime = 0.0, lastTapPoint = CGPoint.zero, tapCount = 0

    private var twoStartDist = 0.0, twoStartAngle = 0.0, twoLastDist = 0.0, twoLastAngle = 0.0
    private var twoStartCentroid = CGPoint.zero, twoLastCentroid = CGPoint.zero, twoStartTime = 0.0, twoMaxCount = 0

    private var windowOrigin = CGPoint.zero, windowEl: InputTarget?
    /// The tablet's own focus, independent of the Mac's active app.
    private(set) var focused: InputTarget?

    var onSystemGesture: ((SystemGesture) -> Void)?
    /// Tablet shell hooks: `shellCaptures` claims a touch sequence at its first finger.
    var shellCaptures: ((CGPoint, CGFloat) -> Bool)?
    var shellHandle: ((TouchEvent) -> Void)?
    var onTap: ((InputTarget?) -> Void)?
    private var shellOwns = false

    enum SystemGesture { case up, down, left, right }

    private let slop = 6.0           // points
    private let holdDrag = 0.22      // seconds before a move means drag instead of scroll
    private let longPress = 0.55

    func setFrame(_ r: CGRect) { q.async { self.frame = r; self.inject.tabletFrame = r } }
    /// Display arrangement can change at any time, so bounds are re-read at the start of each touch.
    var boundsProvider: (() -> CGRect)?

    func handle(_ e: TouchEvent) { q.async { self.process(e) } }

    private func pt(_ p: TouchPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * frame.width, y: frame.minY + p.y * frame.height) }
    private var now: Double { CFAbsoluteTimeGetCurrent() }

    private func process(_ e: TouchEvent) {
        if e.action == 0 && e.points.count == 1, let b = boundsProvider?() { frame = b; inject.tabletFrame = b }
        if e.action == 0 && e.points.count == 1, let c = shellCaptures {
            shellOwns = c(CGPoint(x: e.points[0].x * frame.width, y: e.points[0].y * frame.height), frame.height)
        }
        if shellOwns {
            shellHandle?(e)
            if e.action == 3 || (e.action == 1 && e.points.count == 1) { shellOwns = false }
            return
        }
        let count = e.points.count
        switch e.action {
        case 3: cancel()
        case 0 where count == 1: fingerDown(pt(e.points[0]))
        case 0 where count == 2: secondFinger(e)
        case 0 where count >= 3: threeFingers(e)
        case 2: moved(e)
        case 1: lifted(e)
        default: break
        }
    }

    // MARK: one finger

    /// Where scroll events are addressed; pid-targeted events carry their own location.
    private var scrollPoint = CGPoint.zero
    /// Remembers what the Mac is doing so a tablet tap can't take its focus away.
    private func keepMacFocus(_ action: () -> Void) {
        let macApp = NSWorkspace.shared.frontmostApplication
        let target = inject_target
        // macOS swallows the first click on an inactive app, so the target goes active for the click itself.
        if let target, macApp?.processIdentifier != target.pid,
           let app = NSRunningApplication(processIdentifier: target.pid) {
            app.activate()
            for _ in 0..<12 where !app.isActive { usleep(5000) }
        }
        action()
        focused = target ?? focused
        // Only someone actually working on the Mac gets focus back. Otherwise the tapped app stays
        // active, which popovers, sheets and text fields depend on.
        guard MacActivity.isBusy else { return }
        q.asyncAfter(deadline: .now() + 0.08) {
            guard let macApp, let target, macApp.processIdentifier != target.pid,
                  !HitTest.hasOpenMenu(pid: target.pid) else { return }
            macApp.activate()
        }
    }
    private var inject_target: InputTarget?
    private var exclusiveMacApp: NSRunningApplication?

    /// Pinches and drags only reach an active app, so the target is active for just that gesture.
    private func beginExclusive() {
        guard let t = inject_target, let app = NSRunningApplication(processIdentifier: t.pid) else { return }
        let mac = NSWorkspace.shared.frontmostApplication
        if mac?.processIdentifier != t.pid { exclusiveMacApp = mac; app.activate() }
        focused = t
    }
    private func endExclusive() {
        guard let mac = exclusiveMacApp else { return }
        exclusiveMacApp = nil
        guard MacActivity.isBusy else { return }
        q.asyncAfter(deadline: .now() + 0.08) { mac.activate() }
    }

    private func fingerDown(_ p: CGPoint) {
        stopMomentum(sendEnd: true)
        mode = .pending; start = p; last = p; startTime = now; lastMoveTime = now; hasHeld = false; velocity = .zero; twoMaxCount = 1
        scrollPoint = p
        inject_target = HitTest.target(at: p)
        if inject_target == nil && HitTest.onlyOwner != nil { mode = .consumed; return } // replay never touches anything else
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + longPress)
        t.setEventHandler { [weak self] in self?.longPressFired() }
        t.resume(); holdTimer = t
    }

    private func longPressFired() {
        guard mode == .pending else { return }
        focused = inject_target ?? focused
        inject.click(start, button: .right)
        mode = .consumed
    }

    private func cancelHold() { holdTimer?.cancel(); holdTimer = nil }

    private func moved(_ e: TouchEvent) {
        if e.points.count == 1 {
            let p = pt(e.points[0])
            switch mode {
            case .pending:
                if hypot(p.x - start.x, p.y - start.y) < slop { return }
                cancelHold()
                let held = now - startTime >= holdDrag
                let kind = HitTest.dragKind(at: start)
                if kind == .moveWindow, let t = inject_target, let origin = Windows.origin(t) {
                    // Moving a window through Accessibility leaves the pointer free.
                    mode = .windowDrag; windowOrigin = origin; windowEl = t; last = p
                    return
                }
                if held || kind == .control {
                    focused = inject_target ?? focused
                    beginExclusive()
                    inject.hold(at: start)
                    mode = .dragging
                    inject.mouse(.leftMouseDown, start)
                    inject.mouse(.leftMouseDragged, p)
                } else {
                    mode = .scrolling
                    inject.scroll(at: scrollPoint, dx: 0, dy: 0, phase: .began)
                    trackScroll(p)
                }
                last = p
            case .scrolling: trackScroll(p)
            case .dragging:
                inject.mouse(.leftMouseDragged, p); last = p
            case .windowDrag:
                if let t = windowEl { Windows.move(t, to: CGPoint(x: windowOrigin.x + p.x - start.x, y: windowOrigin.y + p.y - start.y)) }
            default: break
            }
        } else if e.points.count == 2 {
            twoMoved(e)
        } else if mode == .system {
            systemMoved(e)
        }
    }

    private func trackScroll(_ p: CGPoint) {
        let t = now, dt = max(t - lastMoveTime, 0.001)
        let dx = p.x - last.x, dy = p.y - last.y
        inject.scroll(at: scrollPoint, dx: dx, dy: dy, phase: .changed)
        velocity = CGVector(dx: velocity.dx * 0.6 + dx / dt * 0.4, dy: velocity.dy * 0.6 + dy / dt * 0.4)
        last = p; lastMoveTime = t
    }

    private func lifted(_ e: TouchEvent) {
        cancelHold()
        switch mode {
        case .pending where e.points.count == 1:
            tap(at: start)
            mode = .idle
        case .scrolling:
            finishScroll()
        case .dragging:
            inject.mouse(.leftMouseUp, last); inject.release(); endExclusive(); mode = .idle
        case .windowDrag:
            mode = .idle
        case .twoPending, .twoScroll, .pinch, .rotate:
            twoLifted(e)
        case .system:
            systemLifted(e)
        default:
            if e.points.count == 1 { mode = .idle }
        }
    }

    /// A tap the shell looked at and handed back (point is local to the display).
    func forwardTap(_ local: CGPoint) {
        q.async { [self] in
            let g = CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
            inject_target = HitTest.target(at: g)
            tap(at: g)
        }
    }

    private func tap(at p: CGPoint) {
        if HitTest.onlyOwner != nil && inject_target == nil { return } // test mode never reaches real apps
        let t = now
        tapCount = (t - lastTapTime < 0.35 && hypot(p.x - lastTapPoint.x, p.y - lastTapPoint.y) < 24) ? tapCount + 1 : 1
        lastTapTime = t; lastTapPoint = p
        keepMacFocus { inject.click(p, clicks: tapCount) }
        onTap?(inject_target)
    }

    private func finishScroll() {
        inject.scroll(at: scrollPoint, dx: 0, dy: 0, phase: .ended)
        mode = .idle
        let stale = now - lastMoveTime > 0.08
        if stale || hypot(velocity.dx, velocity.dy) < 60 { return }
        startMomentum()
    }

    private func startMomentum() {
        var v = velocity, first = true
        let tick = 1.0 / 120.0
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + tick, repeating: tick)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // UIScrollView's normal deceleration: 0.998 per millisecond.
            let k = pow(0.998, tick * 1000)
            v = CGVector(dx: v.dx * k, dy: v.dy * k)
            if hypot(v.dx, v.dy) < 12 { self.stopMomentum(sendEnd: true); return }
            self.inject.scroll(at: self.scrollPoint, dx: v.dx * tick, dy: v.dy * tick, phase: .none, momentum: first ? .begin : .cont)
            first = false
        }
        t.resume(); momentum = t
    }

    private func stopMomentum(sendEnd: Bool) {
        guard let m = momentum else { return }
        m.cancel(); momentum = nil
        if sendEnd { inject.scroll(at: scrollPoint, dx: 0, dy: 0, phase: .none, momentum: .end) }
    }

    private func cancel() {
        cancelHold()
        switch mode {
        case .dragging: inject.mouse(.leftMouseUp, last); inject.release(); endExclusive()
        case .scrolling, .twoScroll: inject.scroll(at: scrollPoint, dx: 0, dy: 0, phase: .ended)
        case .pinch: inject.magnify(at: twoLastCentroid, delta: 0, phase: 8); inject.release(); endExclusive()
        case .rotate: inject.rotate(at: twoLastCentroid, degrees: 0, phase: 8); inject.release(); endExclusive()
        default: break
        }
        mode = .idle
    }

    // MARK: two fingers

    private func metrics(_ e: TouchEvent) -> (CGPoint, Double, Double) {
        let a = pt(e.points[0]), b = pt(e.points[1])
        return (CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), hypot(a.x - b.x, a.y - b.y), atan2(b.y - a.y, b.x - a.x))
    }

    private func secondFinger(_ e: TouchEvent) {
        cancelHold()
        if mode == .dragging { return } // second finger during a drag is ignored
        guard mode == .pending || mode == .idle else { return }
        let (c, d, a) = metrics(e)
        mode = .twoPending; twoMaxCount = 2
        twoStartCentroid = c; twoLastCentroid = c; twoStartDist = d; twoLastDist = d; twoStartAngle = a; twoLastAngle = a; twoStartTime = now
        lastMoveTime = now; velocity = .zero
        scrollPoint = c
    }

    private func angleDelta(_ a: Double, _ b: Double) -> Double {
        var d = a - b
        while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
        return d
    }

    private func twoMoved(_ e: TouchEvent) {
        let (c, d, a) = metrics(e)
        switch mode {
        case .twoPending:
            let pinch = abs(d - twoStartDist), turn = abs(angleDelta(a, twoStartAngle)) * 180 / .pi
            let pan = hypot(c.x - twoStartCentroid.x, c.y - twoStartCentroid.y)
            if pinch > 12 && pinch > pan {
                mode = .pinch; twoLastDist = d
                beginExclusive()
                inject.hold(at: c)
                inject.magnify(at: c, delta: 0, phase: 1)
            } else if turn > 14 && pan < 20 {
                mode = .rotate; twoLastAngle = a
                beginExclusive()
                inject.hold(at: c)
                inject.rotate(at: c, degrees: 0, phase: 1)
            } else if pan > slop {
                mode = .twoScroll; twoLastCentroid = c; lastMoveTime = now
                inject.scroll(at: scrollPoint, dx: 0, dy: 0, phase: .began)
            }
        case .twoScroll:
            let t = now, dt = max(t - lastMoveTime, 0.001)
            let dx = c.x - twoLastCentroid.x, dy = c.y - twoLastCentroid.y
            inject.scroll(at: scrollPoint, dx: dx, dy: dy, phase: .changed)
            velocity = CGVector(dx: velocity.dx * 0.6 + dx / dt * 0.4, dy: velocity.dy * 0.6 + dy / dt * 0.4)
            twoLastCentroid = c; lastMoveTime = t
        case .pinch:
            inject.magnify(at: twoStartCentroid, delta: (d - twoLastDist) / max(twoLastDist, 1), phase: 2)
            twoLastDist = d
        case .rotate:
            // Trackpad rotation is positive counter-clockwise; screen angles grow clockwise.
            inject.rotate(at: twoStartCentroid, degrees: -angleDelta(a, twoLastAngle) * 180 / .pi, phase: 2)
            twoLastAngle = a
        default: break
        }
    }

    private func twoLifted(_ e: TouchEvent) {
        switch mode {
        case .twoPending:
            if now - twoStartTime < 0.3 {
                inject.click(twoStartCentroid, button: .right)
            }
            mode = .consumed
        case .twoScroll:
            inject.scroll(at: scrollPoint, dx: 0, dy: 0, phase: .ended)
            if now - lastMoveTime <= 0.08 && hypot(velocity.dx, velocity.dy) >= 60 { startMomentum() }
            mode = .consumed
        case .pinch:
            inject.magnify(at: twoStartCentroid, delta: 0, phase: 4); inject.release(); endExclusive(); mode = .consumed
        case .rotate:
            inject.rotate(at: twoStartCentroid, degrees: 0, phase: 4); inject.release(); endExclusive(); mode = .consumed
        default: break
        }
        if e.points.count == 1 { mode = .idle }
    }

    // MARK: three+ fingers

    private var sysStart = CGPoint.zero, sysLast = CGPoint.zero

    private func centroid(_ e: TouchEvent) -> CGPoint {
        let ps = e.points.map(pt)
        return CGPoint(x: ps.map(\.x).reduce(0, +) / Double(ps.count), y: ps.map(\.y).reduce(0, +) / Double(ps.count))
    }

    private func threeFingers(_ e: TouchEvent) {
        cancelHold()
        switch mode {
        case .twoScroll: inject.scroll(at: scrollPoint, dx: 0, dy: 0, phase: .ended)
        case .pinch: inject.magnify(at: twoStartCentroid, delta: 0, phase: 8); inject.release(); endExclusive()
        case .rotate: inject.rotate(at: twoStartCentroid, degrees: 0, phase: 8); inject.release(); endExclusive()
        default: break
        }
        mode = .system; sysStart = centroid(e); sysLast = sysStart
    }

    private func systemMoved(_ e: TouchEvent) { sysLast = centroid(e) }

    private func systemLifted(_ e: TouchEvent) {
        let dx = sysLast.x - sysStart.x, dy = sysLast.y - sysStart.y
        if max(abs(dx), abs(dy)) > 40 {
            onSystemGesture?(abs(dy) > abs(dx) ? (dy < 0 ? .up : .down) : (dx < 0 ? .left : .right))
        }
        mode = .consumed
        if e.points.count == 1 { mode = .idle }
    }
}
