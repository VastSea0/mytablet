import AppKit
import EventKit
import IOKit.ps

/// Every widget shows live data from this Mac; nothing here is placeholder content.
enum WidgetRenderer {
    static func image(_ kind: WidgetKind, size: CGSize) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        defer { NSGraphicsContext.restoreGraphicsState() }
        let rect = CGRect(origin: .zero, size: size)
        NSColor(calibratedWhite: 0.1, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill()
        switch kind {
        case .clock: clock(rect)
        case .calendar: calendar(rect)
        case .events: events(rect)
        case .battery: battery(rect)
        case .system: system(rect)
        }
        return ctx.makeImage()
    }

    private static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .white, width: CGFloat? = nil, align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle(); p.alignment = align; p.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
        (s as NSString).draw(in: CGRect(x: x, y: y, width: width ?? 400, height: size * 1.4), withAttributes: a)
    }

    private static func clock(_ r: CGRect) {
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2 - 16
        NSColor.white.setFill(); NSBezierPath(ovalIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)).fill()
        NSColor.black.setStroke()
        for i in 0..<12 {
            let a = CGFloat(i) * .pi / 6, l: CGFloat = i % 3 == 0 ? 9 : 5
            let p = NSBezierPath(); p.lineWidth = i % 3 == 0 ? 2.2 : 1
            p.move(to: CGPoint(x: c.x + sin(a) * (R - 3), y: c.y + cos(a) * (R - 3)))
            p.line(to: CGPoint(x: c.x + sin(a) * (R - 3 - l), y: c.y + cos(a) * (R - 3 - l))); p.stroke()
        }
        let d = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let s = CGFloat(d.second ?? 0), m = CGFloat(d.minute ?? 0) + s / 60, h = CGFloat((d.hour ?? 0) % 12) + m / 60
        func hand(_ a: CGFloat, _ l: CGFloat, _ w: CGFloat, _ col: NSColor) {
            col.setStroke(); let p = NSBezierPath(); p.lineWidth = w; p.lineCapStyle = .round
            p.move(to: c); p.line(to: CGPoint(x: c.x + sin(a) * l, y: c.y + cos(a) * l)); p.stroke()
        }
        hand(h * .pi / 6, R * 0.5, 4, .black); hand(m * .pi / 30, R * 0.78, 3, .black); hand(s * .pi / 30, R * 0.85, 1, .systemOrange)
        NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)).fill()
    }

    private static func calendar(_ r: CGRect) {
        var cal = Calendar.current; cal.locale = Locale(identifier: "tr_TR"); cal.firstWeekday = 2
        let now = Date()
        let df = DateFormatter(); df.locale = cal.locale; df.dateFormat = "LLLL"
        text(df.string(from: now).uppercased(with: cal.locale), 16, r.height - 30, 12, .bold, .systemRed)
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: now)), let days = cal.range(of: .day, in: .month, for: now) else { return }
        let today = cal.component(.day, from: now), offset = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let cw = (r.width - 24) / 7, top = r.height - 52, ch = (top - 8) / 6
        for (i, n) in ["P", "S", "Ç", "P", "C", "C", "P"].enumerated() { text(n, 12 + CGFloat(i) * cw, top, 9, .semibold, .secondaryLabelColor, width: cw, align: .center) }
        for d in days {
            let idx = d - 1 + offset, col = idx % 7, row = idx / 7
            let x = 12 + CGFloat(col) * cw, y = top - CGFloat(row + 1) * ch
            if d == today {
                NSColor.systemRed.setFill(); NSBezierPath(ovalIn: CGRect(x: x + cw / 2 - 9, y: y - 2, width: 18, height: 18)).fill()
            }
            text("\(d)", x, y, 10, d == today ? .bold : .regular, .white, width: cw, align: .center)
        }
    }

    private static let store = EKEventStore()
    private static var calendarAsked = false

    private static func events(_ r: CGRect) {
        text("YAKLAŞAN", 16, r.height - 30, 12, .bold, .systemRed)
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            if !calendarAsked { calendarAsked = true; store.requestFullAccessToEvents { _, _ in } }
            text("Takvim izni gerekli", 16, r.height - 56, 13, .regular, .secondaryLabelColor)
            return
        }
        let now = Date(), end = now.addingTimeInterval(7 * 86400)
        let list = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }
        if list.isEmpty { text("Önümüzdeki 7 günde etkinlik yok", 16, r.height - 56, 13, .regular, .secondaryLabelColor); return }
        let df = DateFormatter(); df.locale = Locale(identifier: "tr_TR"); df.dateFormat = "d MMM HH:mm"
        for (i, e) in list.prefix(4).enumerated() {
            let y = r.height - 56 - CGFloat(i) * 30
            NSColor(cgColor: e.calendar.cgColor)?.setFill(); NSBezierPath(roundedRect: CGRect(x: 16, y: y, width: 3, height: 22), xRadius: 1.5, yRadius: 1.5).fill()
            text(e.title ?? "", 26, y + 8, 12, .semibold, .white, width: r.width - 130)
            text(df.string(from: e.startDate), r.width - 104, y + 8, 11, .regular, .secondaryLabelColor, width: 90, align: .right)
        }
    }

    private static func battery(_ r: CGRect) {
        var pct = 0, charging = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef], let s = list.first,
           let d = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any] {
            pct = d[kIOPSCurrentCapacityKey] as? Int ?? 0; charging = d[kIOPSIsChargingKey] as? Bool ?? false
        }
        let c = CGPoint(x: r.midX, y: r.midY + 10), R: CGFloat = 46
        let track = NSBezierPath(); track.appendArc(withCenter: c, radius: R, startAngle: 0, endAngle: 360); track.lineWidth = 10
        NSColor.white.withAlphaComponent(0.18).setStroke(); track.stroke()
        let arc = NSBezierPath(); arc.appendArc(withCenter: c, radius: R, startAngle: 90, endAngle: 90 - CGFloat(pct) * 3.6, clockwise: true)
        arc.lineWidth = 10; arc.lineCapStyle = .round
        (pct <= 20 && !charging ? NSColor.systemRed : .systemGreen).setStroke(); arc.stroke()
        text("%\(pct)", 0, c.y - 12, 20, .bold, .white, width: r.width, align: .center)
        text(charging ? "Şarj oluyor" : "MacBook", 0, 12, 12, .medium, .secondaryLabelColor, width: r.width, align: .center)
    }

    private static var lastCPU: host_cpu_load_info?

    private static func cpuUsage() -> Double {
        var info = host_cpu_load_info(), n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) } }
        guard ok == KERN_SUCCESS else { return 0 }
        defer { lastCPU = info }
        guard let l = lastCPU else { return 0 }
        let user = Double(info.cpu_ticks.0 &- l.cpu_ticks.0), sys = Double(info.cpu_ticks.1 &- l.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- l.cpu_ticks.2), nice = Double(info.cpu_ticks.3 &- l.cpu_ticks.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total : 0
    }

    private static func memoryUsage() -> Double {
        var s = vm_statistics64(), n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) } }
        guard ok == KERN_SUCCESS else { return 0 }
        let used = UInt64(s.active_count + s.wire_count + s.compressor_page_count) * UInt64(vm_kernel_page_size)
        return Double(used) / Double(ProcessInfo.processInfo.physicalMemory)
    }

    private static func system(_ r: CGRect) {
        text("SİSTEM", 16, r.height - 30, 12, .bold, .systemBlue)
        func bar(_ label: String, _ v: Double, _ y: CGFloat, _ col: NSColor) {
            text(label, 16, y + 12, 12, .medium)
            text("%\(Int(v * 100))", r.width - 66, y + 12, 12, .semibold, .white, width: 50, align: .right)
            let w = r.width - 32
            NSColor.white.withAlphaComponent(0.18).setFill(); NSBezierPath(roundedRect: CGRect(x: 16, y: y, width: w, height: 7), xRadius: 3.5, yRadius: 3.5).fill()
            col.setFill(); NSBezierPath(roundedRect: CGRect(x: 16, y: y, width: max(7, w * v), height: 7), xRadius: 3.5, yRadius: 3.5).fill()
        }
        bar("CPU", cpuUsage(), r.height - 80, .systemBlue)
        bar("Bellek", memoryUsage(), r.height - 132, .systemPurple)
    }
}
