import Darwin
import Foundation

struct TouchPoint { let id: Int; let x: Double; let y: Double }
struct TouchEvent { let action: Int; let actionID: Int; let points: [TouchPoint] } // action: 0 down, 1 up, 2 move, 3 cancel

/// One TCP socket through `adb forward`. Video goes down, touch/acks come up.
final class Link {
    private let fd: Int32
    private let sendQ = DispatchQueue(label: "link.send", qos: .userInteractive)
    private let lock = NSLock()
    private var alive = true
    var onTouch: ((TouchEvent) -> Void)?
    var onAck: ((UInt32, UInt64) -> Void)?   // seq, tablet-side rtt echo
    var onPong: ((UInt64) -> Void)?
    var onClosed: (() -> Void)?

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var hello = [UInt8](repeating: 0, count: 1)
        guard recv(fd, &hello, 1, MSG_WAITALL) == 1, hello[0] == 0x4D else { close(fd); return nil }
    }

    func startReading() { Thread.detachNewThread { [self] in readLoop() } }

    func sendVideo(_ f: EncodedFrame, seq: UInt32) {
        if let c = f.config { packet(type: 1, seq: 0, ts: f.captureNs, flags: 1, body: c) }
        packet(type: 1, seq: seq, ts: f.captureNs, flags: f.isKey ? 2 : 0, body: f.data)
    }

    func sendPing(_ ns: UInt64) { packet(type: 2, seq: 0, ts: ns, flags: 0, body: Data()) }

    private func packet(type: UInt8, seq: UInt32, ts: UInt64, flags: UInt8, body: Data) {
        var h = Data(capacity: 18 + body.count)
        h.append(type)
        withUnsafeBytes(of: seq.bigEndian) { h.append(contentsOf: $0) }
        withUnsafeBytes(of: ts.bigEndian) { h.append(contentsOf: $0) }
        h.append(flags)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { h.append(contentsOf: $0) }
        h.append(body)
        sendQ.async { [self] in
            h.withUnsafeBytes { p in
                var off = 0
                while off < p.count {
                    let n = Darwin.send(fd, p.baseAddress! + off, p.count - off, 0)
                    if n <= 0 { shutdownOnce(); return }
                    off += n
                }
            }
        }
    }

    private func readExact(_ n: Int) -> [UInt8]? {
        var b = [UInt8](repeating: 0, count: n)
        var off = 0
        while off < n {
            let r = b.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + off, n - off, 0) }
            if r <= 0 { return nil }
            off += r
        }
        return b
    }

    private func readLoop() {
        Thread.current.qualityOfService = .userInteractive
        func be32(_ b: ArraySlice<UInt8>) -> UInt32 { b.reduce(0) { $0 << 8 | UInt32($1) } }
        func be64(_ b: ArraySlice<UInt8>) -> UInt64 { b.reduce(0) { $0 << 8 | UInt64($1) } }
        while let t = readExact(1) {
            switch t[0] {
            case 1: // touch: action, actionID, count, then (id, xFloat, yFloat)
                guard let h = readExact(3), let body = readExact(Int(h[2]) * 9) else { shutdownOnce(); return }
                var pts: [TouchPoint] = []
                for i in 0..<Int(h[2]) {
                    let o = i * 9
                    let x = Float(bitPattern: be32(body[(o+1)..<(o+5)]))
                    let y = Float(bitPattern: be32(body[(o+5)..<(o+9)]))
                    pts.append(TouchPoint(id: Int(body[o]), x: Double(x), y: Double(y)))
                }
                onTouch?(TouchEvent(action: Int(h[0]), actionID: Int(h[1]), points: pts))
            case 2: // frame ack
                guard let b = readExact(12) else { shutdownOnce(); return }
                onAck?(be32(b[0..<4]), be64(b[4..<12]))
            case 3:
                guard let b = readExact(8) else { shutdownOnce(); return }
                onPong?(be64(b[0..<8]))
            default:
                Log.write("bad packet \(t[0])"); shutdownOnce(); return
            }
        }
        shutdownOnce()
    }

    private func shutdownOnce() {
        lock.lock(); let was = alive; alive = false; lock.unlock()
        guard was else { return }
        Darwin.shutdown(fd, SHUT_RDWR); close(fd)
        onClosed?()
    }

    func close_() { shutdownOnce() }
}
