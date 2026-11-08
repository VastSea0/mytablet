import AppKit
import Carbon
import CoreGraphics

/// Labels for a physical key under the active macOS input source, so the on-screen layout always matches typing.
enum KeyLabels {
    static func label(_ code: CGKeyCode, shift: Bool) -> String {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = unsafeBitCast(ptr, to: CFData.self)
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let ok = UCKeyTranslate(unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self), code,
                                UInt16(kUCKeyActionDisplay), shift ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 4, &len, &chars)
        return ok == noErr ? String(utf16CodeUnits: chars, count: len) : ""
    }
}

struct Key { let code: CGKeyCode; let weight: CGFloat; let fixed: String? }

let keyRows: [[Key]] = {
    func k(_ c: [CGKeyCode]) -> [Key] { c.map { Key(code: $0, weight: 1, fixed: nil) } }
    return [
        k([18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]) + [Key(code: 51, weight: 1.6, fixed: "⌫")],
        [Key(code: 48, weight: 1.4, fixed: "⇥")] + k([12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]),
        [Key(code: 57, weight: 1.7, fixed: "⇪")] + k([0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]) + [Key(code: 36, weight: 1.8, fixed: "return")],
        [Key(code: 56, weight: 2.2, fixed: "⇧")] + k([6, 7, 8, 9, 11, 45, 46, 43, 47, 44]) + [Key(code: 56, weight: 2.2, fixed: "⇧")],
        [Key(code: 59, weight: 1.2, fixed: "⌃"), Key(code: 58, weight: 1.2, fixed: "⌥"), Key(code: 55, weight: 1.5, fixed: "⌘"),
         Key(code: 49, weight: 6.5, fixed: " "), Key(code: 123, weight: 1, fixed: "←"), Key(code: 126, weight: 1, fixed: "↑"),
         Key(code: 125, weight: 1, fixed: "↓"), Key(code: 124, weight: 1, fixed: "→"), Key(code: 0xFFFF, weight: 1.4, fixed: "⌨︎↓")],
    ]
}()

/// Types through real key events. Modifiers latch for the next key, Caps Lock toggles.
final class KeyboardView: NSView {
    private struct Cap { let key: Key; let frame: CGRect; let layer: CALayer; let text: CATextLayer }
    private var caps: [Cap] = []
    private let src = CGEventSource(stateID: .privateState)
    private var flags: CGEventFlags = []
    private var capsOn = false
    private var repeatTimer: Timer?
    var onDismiss: (() -> Void)?
    /// Typing goes to the tablet's focused app, not to whatever is active on the Mac.
    var targetPid: (() -> pid_t?)?
    /// Plays on the tablet's own speaker: 0 letter, 1 delete, 2 modifier.
    var onSound: ((Int) -> Void)?
    /// When set, keys edit shell text (a folder name) instead of going to an app.
    var textSink: ((String?) -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        layer?.isGeometryFlipped = false
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        caps.forEach { $0.layer.removeFromSuperlayer() }; caps = []
        let pad: CGFloat = 6, rowH = (bounds.height - pad) / CGFloat(keyRows.count)
        for (r, row) in keyRows.enumerated() {
            let total = row.reduce(0) { $0 + $1.weight }, unit = (bounds.width - pad) / total
            var x = pad
            for key in row {
                let f = CGRect(x: x, y: pad + CGFloat(r) * rowH, width: key.weight * unit - pad, height: rowH - pad)
                let l = CALayer(); l.frame = f; l.cornerRadius = 12
                l.backgroundColor = capColor(key, false)
                let t = CATextLayer(); t.contentsScale = 2; t.alignmentMode = .center
                t.font = NSFont.systemFont(ofSize: 18); t.fontSize = key.fixed == "return" ? 14 : 18
                t.foregroundColor = NSColor.white.cgColor
                t.frame = CGRect(x: 0, y: (f.height - 24) / 2 - 1, width: f.width, height: 24)
                l.addSublayer(t); layer?.addSublayer(l)
                caps.append(Cap(key: key, frame: f, layer: l, text: t))
                x += key.weight * unit
            }
        }
        refreshLabels()
    }

    private func capColor(_ k: Key, _ down: Bool) -> CGColor {
        if down { return NSColor.white.withAlphaComponent(0.62).cgColor }
        return NSColor.white.withAlphaComponent(k.fixed != nil && k.code != 49 ? 0.12 : 0.24).cgColor
    }

    func refreshLabels() {
        let shifted = flags.contains(.maskShift) != capsOn
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for c in caps {
            if let f = c.key.fixed { c.text.string = f } else {
                let s = KeyLabels.label(c.key.code, shift: shifted)
                c.text.string = shifted ? s.uppercased(with: Locale(identifier: "tr")) : s
            }
            let active = (c.key.code == 56 && flags.contains(.maskShift)) || (c.key.code == 57 && capsOn) ||
                (c.key.code == 59 && flags.contains(.maskControl)) || (c.key.code == 58 && flags.contains(.maskAlternate)) ||
                (c.key.code == 55 && flags.contains(.maskCommand))
            c.layer.backgroundColor = active ? NSColor.white.withAlphaComponent(0.75).cgColor : capColor(c.key, false)
            c.text.foregroundColor = active ? NSColor.black.cgColor : NSColor.white.cgColor
        }
        CATransaction.commit()
    }

    private func post(_ code: CGKeyCode) {
        if let sink = textSink {
            if code == 51 { sink(nil) } else if code == 49 { sink(" ") } else if code != 36 {
                let shifted = flags.contains(.maskShift) != capsOn
                let s = KeyLabels.label(code, shift: shifted)
                sink(shifted ? s.uppercased(with: Locale(identifier: "tr")) : s)
            }
            return
        }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = capsOn ? flags.union(.maskAlphaShift) : flags
            if let pid = targetPid?() { e?.postToPid(pid) } else { e?.post(tap: .cghidEventTap) }
        }
    }

    private var pressed: Cap?

    func touchDown(at p: CGPoint) {
        guard let c = caps.first(where: { $0.frame.insetBy(dx: -3, dy: -3).contains(p) }) else { return }
        pressed = c
        CATransaction.begin(); CATransaction.setDisableActions(true)
        c.layer.backgroundColor = capColor(c.key, true)
        CATransaction.commit()
        onSound?(c.key.code == 51 ? 1 : (c.key.fixed != nil && c.key.code != 49 ? 2 : 0))
        if c.key.code == 51 {
            post(51)
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in self?.post(51) }
            }
        }
    }

    func cancelTouch() { repeatTimer?.invalidate(); repeatTimer = nil; pressed = nil; refreshLabels() }

    func touchUp() {
        repeatTimer?.invalidate(); repeatTimer = nil
        guard let c = pressed else { return }
        pressed = nil
        switch c.key.code {
        case 0xFFFF: onDismiss?()
        case 51: break
        case 56: flags.formSymmetricDifference(.maskShift)
        case 57: capsOn.toggle()
        case 59: flags.formSymmetricDifference(.maskControl)
        case 58: flags.formSymmetricDifference(.maskAlternate)
        case 55: flags.formSymmetricDifference(.maskCommand)
        default:
            post(c.key.code)
            flags = []
        }
        refreshLabels()
    }
}
