import AppKit
import QuartzCore

/// The tablet's Settings app. Rows bind directly to `Prefs` and take effect as soon as they're touched.
final class SettingsPanel {
    enum Row {
        case header(String)
        case segmented(String, [String], get: () -> Int, set: (Int) -> Void)
        case toggle(String, get: () -> Bool, set: (Bool) -> Void)
        case button(String, destructive: Bool, action: () -> Void)
        case note(String)
    }

    private struct Placed {
        let frame: CGRect
        let row: Row
        var pill: CALayer?, labels: [CATextLayer] = [], track: CALayer?, knob: CALayer?, segmentW: CGFloat = 0
    }

    let frame: CGRect
    private let list = CALayer(), clip = CALayer()
    private var placed: [Placed] = []
    private var contentHeight: CGFloat = 0, offset: CGFloat = 0, base: CGFloat = 0
    private var down = CGPoint.zero, moved = false
    private var velocity: CGFloat = 0, lastY: CGFloat = 0, lastT = 0.0
    var onDone: (() -> Void)?

    private let width: CGFloat
    private let titleH: CGFloat = 58, margin: CGFloat = 20, rowH: CGFloat = 48
    private let doneRect: CGRect

    init(frame: CGRect, content: CALayer, rows: [Row]) {
        self.frame = frame
        width = frame.width
        doneRect = CGRect(x: frame.width - 86, y: 12, width: 70, height: 34)
        let title = Self.text("Ayarlar", 22, .bold); title.frame = CGRect(x: margin + 6, y: 15, width: 300, height: 30); content.addSublayer(title)
        let done = CALayer(); done.frame = doneRect; done.cornerRadius = 17; done.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        let dt = Self.text("Bitti", 14, .semibold); dt.alignmentMode = .center; dt.frame = CGRect(x: 0, y: 8, width: doneRect.width, height: 20); done.addSublayer(dt); content.addSublayer(done)
        clip.frame = CGRect(x: 0, y: titleH, width: frame.width, height: frame.height - titleH); clip.masksToBounds = true; content.addSublayer(clip)
        list.frame = clip.bounds; clip.addSublayer(list)
        build(rows)
    }

    private static func text(_ s: String, _ size: CGFloat, _ w: NSFont.Weight, alpha: CGFloat = 1) -> CATextLayer {
        let t = CATextLayer(); t.contentsScale = 2; t.string = s; t.font = NSFont.systemFont(ofSize: size, weight: w); t.fontSize = size
        t.foregroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        return t
    }

    private func build(_ rows: [Row]) {
        var y: CGFloat = 4, card: CALayer?, cardTop: CGFloat = 0
        func closeCard() { if let c = card { c.frame = CGRect(x: margin, y: cardTop, width: width - 2 * margin, height: y - cardTop) }; card = nil }
        func openCard() {
            guard card == nil else { return }
            let c = CALayer(); c.cornerRadius = 18; c.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
            list.addSublayer(c); card = c; cardTop = y
        }
        for row in rows {
            switch row {
            case .header(let s):
                closeCard(); y += 10
                let t = Self.text(s, 12, .semibold, alpha: 0.65); t.frame = CGRect(x: margin + 12, y: y, width: 400, height: 16); list.addSublayer(t)
                y += 24
            case .note(let s):
                closeCard()
                let t = Self.text(s, 12, .regular, alpha: 0.6); t.isWrapped = true; t.frame = CGRect(x: margin + 12, y: y + 6, width: width - 2 * margin - 24, height: 34); list.addSublayer(t)
                y += 42
            case .segmented(let title, let options, let get, _):
                openCard()
                var p = Placed(frame: CGRect(x: margin, y: y, width: width - 2 * margin, height: rowH), row: row)
                addTitle(title, y)
                let w: CGFloat = min(300, CGFloat(options.count) * 88), x = width - margin - 14 - w
                let track = CALayer(); track.frame = CGRect(x: x, y: y + 9, width: w, height: 30); track.cornerRadius = 15; track.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor; list.addSublayer(track)
                let seg = w / CGFloat(options.count)
                let pill = CALayer(); pill.bounds = CGRect(x: 0, y: 0, width: seg - 4, height: 26); pill.cornerRadius = 13; pill.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
                pill.position = CGPoint(x: seg * (CGFloat(get()) + 0.5), y: 15); track.addSublayer(pill)
                for (i, o) in options.enumerated() {
                    let t = Self.text(o, 13, .medium); t.alignmentMode = .center; t.truncationMode = .end; t.frame = CGRect(x: CGFloat(i) * seg, y: 6, width: seg, height: 18); track.addSublayer(t); p.labels.append(t)
                }
                p.track = track; p.pill = pill; p.segmentW = seg
                placed.append(p); colorLabels(p, get()); y += rowH
            case .toggle(let title, let get, _):
                openCard()
                var p = Placed(frame: CGRect(x: margin, y: y, width: width - 2 * margin, height: rowH), row: row)
                addTitle(title, y)
                let track = CALayer(); track.frame = CGRect(x: width - margin - 14 - 52, y: y + 9, width: 52, height: 30); track.cornerRadius = 15
                let knob = CALayer(); knob.bounds = CGRect(x: 0, y: 0, width: 26, height: 26); knob.cornerRadius = 13; knob.backgroundColor = NSColor.white.cgColor; track.addSublayer(knob)
                list.addSublayer(track); p.track = track; p.knob = knob
                placed.append(p); setToggle(p, get(), animated: false); y += rowH
            case .button(let title, let destructive, _):
                openCard()
                let t = Self.text(title, 15, .medium); t.foregroundColor = (destructive ? NSColor.systemRed : .systemBlue).cgColor; t.frame = CGRect(x: margin + 16, y: y + 14, width: 500, height: 20); list.addSublayer(t)
                placed.append(Placed(frame: CGRect(x: margin, y: y, width: width - 2 * margin, height: rowH), row: row)); y += rowH
            }
        }
        closeCard()
        contentHeight = y + 24
    }

    private func addTitle(_ s: String, _ y: CGFloat) {
        let t = Self.text(s, 15, .regular); t.frame = CGRect(x: margin + 16, y: y + 14, width: 280, height: 20); list.addSublayer(t)
    }

    private func colorLabels(_ p: Placed, _ sel: Int) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in p.labels.enumerated() { l.foregroundColor = (i == sel ? NSColor.black : .white).cgColor }
        CATransaction.commit()
    }

    private func setToggle(_ p: Placed, _ on: Bool, animated: Bool) {
        let pos = NSValue(point: CGPoint(x: on ? 37 : 15, y: 15))
        if animated { p.knob?.spring("position", to: pos, damping: 22, stiffness: 420) }
        else { CATransaction.begin(); CATransaction.setDisableActions(true); p.knob?.position = pos.pointValue; CATransaction.commit() }
        CATransaction.begin(); CATransaction.setAnimationDuration(animated ? 0.18 : 0)
        p.track?.backgroundColor = (on ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.2)).cgColor
        CATransaction.commit()
    }

    // MARK: touch (points are panel-local)

    private var maxOffset: CGFloat { max(0, contentHeight - clip.bounds.height) }

    private func apply(_ o: CGFloat, spring: Bool = false) {
        offset = o
        if spring { list.spring("sublayerTransform.translation.y", to: -o, damping: 30, stiffness: 240) }
        else { CATransaction.begin(); CATransaction.setDisableActions(true); list.setValue(-o, forKeyPath: "sublayerTransform.translation.y"); CATransaction.commit() }
    }

    func began(_ p: CGPoint) { down = p; base = offset; moved = false; velocity = 0; lastY = p.y; lastT = CFAbsoluteTimeGetCurrent() }

    func moved(_ p: CGPoint) {
        if !moved && abs(p.y - down.y) > 8 { moved = true }
        guard moved else { return }
        let t = CFAbsoluteTimeGetCurrent(), dt = max(t - lastT, 0.001)
        velocity = velocity * 0.6 + (lastY - p.y) / CGFloat(dt) * 0.4
        lastY = p.y; lastT = t
        var o = base + down.y - p.y
        if o < 0 { o /= 3 } else if o > maxOffset { o = maxOffset + (o - maxOffset) / 3 }
        apply(o)
    }

    func ended(_ p: CGPoint) {
        if moved { apply(max(0, min(maxOffset, offset + velocity * 0.22)), spring: true); return }
        if doneRect.insetBy(dx: -8, dy: -6).contains(p) { onDone?(); return }
        guard p.y > titleH else { return }
        let lp = CGPoint(x: p.x, y: p.y - titleH + offset)
        guard let i = placed.firstIndex(where: { $0.frame.contains(lp) }) else { return }
        let r = placed[i]
        switch r.row {
        case .segmented(_, let options, _, let set):
            guard let track = r.track, r.segmentW > 0, track.frame.insetBy(dx: -4, dy: -6).contains(lp) else { return }
            let sel = max(0, min(options.count - 1, Int((lp.x - track.frame.minX) / r.segmentW)))
            r.pill?.spring("position", to: NSValue(point: CGPoint(x: r.segmentW * (CGFloat(sel) + 0.5), y: 15)), damping: 24, stiffness: 380)
            colorLabels(r, sel); set(sel)
        case .toggle(_, let get, let set):
            let v = !get(); setToggle(r, v, animated: true); set(v)
        case .button(_, _, let action): action()
        default: break
        }
    }
}
