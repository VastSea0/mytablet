import CryptoKit
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
    var onBrightness: ((Int) -> Void)?
    var onClosed: (() -> Void)?

    private var secure: SecureRecords?
    private var rx = Data()
    let isWireless: Bool

    /// Connects straight to the tablet over the network, or through the adb tunnel when `psk` is nil.
    init?(host: String = "127.0.0.1", port: UInt16, psk: Data? = nil) {
        isWireless = psk != nil
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr(host)
        guard Self.connect(fd, &a, timeoutMs: psk == nil ? 2000 : 2500) else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if let psk {
            guard handshake(psk) else { close(fd); return nil }
        }
        guard let hello = readExact(1), hello[0] == 0x4D else { close(fd); return nil }
        tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func connect(_ fd: Int32, _ a: inout sockaddr_in, timeoutMs: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&p, 1, timeoutMs) == 1 else { return false }
        var err: Int32 = 0; var n = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &n)
        return err == 0
    }

    private func rawExact(_ n: Int) -> Data? {
        var b = Data(count: n), off = 0
        while off < n {
            let r = b.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + off, n - off, 0) }
            if r <= 0 { return nil }
            off += r
        }
        return b
    }

    private func rawSend(_ d: Data) -> Bool {
        d.withUnsafeBytes { p in
            var off = 0
            while off < p.count {
                let n = Darwin.send(fd, p.baseAddress! + off, p.count - off, 0)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    /// Both ends prove they hold the pairing key, then derive a key used only for this session.
    private func handshake(_ psk: Data) -> Bool {
        guard let nr = rawExact(16) else { return false }
        let nm = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        guard rawSend(nm + SecureRecords.hmac(psk, "mytablet-client", nr, nm)),
              let proof = rawExact(32), proof == SecureRecords.hmac(psk, "mytablet-server", nr, nm) else { return false }
        secure = SecureRecords(key: SymmetricKey(data: SecureRecords.hmac(psk, "mytablet-session", nr, nm)))
        return true
    }

    func startReading() { Thread.detachNewThread { [self] in readLoop() } }

    func sendVideo(_ f: EncodedFrame, seq: UInt32) {
        if let c = f.config { packet(type: 1, seq: 0, ts: f.captureNs, flags: 1, body: c) }
        packet(type: 1, seq: seq, ts: f.captureNs, flags: f.isKey ? 2 : 0, body: f.data)
    }

    func sendBrightness(_ v: Int) { packet(type: 4, seq: UInt32(v), ts: 0, flags: 0, body: Data()) }
    func sendPairingKey(_ key: Data) { packet(type: 5, seq: 0, ts: 0, flags: 0, body: key) }

    func sendSound(_ kind: Int) { packet(type: 3, seq: UInt32(kind), ts: 0, flags: 0, body: Data()) }

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
            guard let wire = secure == nil ? h : try? secure!.seal(h), rawSend(wire) else { shutdownOnce(); return }
        }
    }

    private func readExact(_ n: Int) -> [UInt8]? {
        guard let secure else { return rawExact(n).map { [UInt8]($0) } }
        while rx.count < n {
            guard let h = rawExact(4) else { return nil }
            let len = Int(h.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard len >= 16, len < 1 << 24, let rec = rawExact(len), let plain = try? secure.open(rec) else { return nil }
            rx.append(plain)
        }
        let out = [UInt8](rx.prefix(n))
        rx.removeFirst(n)
        if rx.isEmpty { rx = Data() }
        return out
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
            case 4:
                guard let b = readExact(4) else { shutdownOnce(); return }
                onBrightness?(Int(be32(b[0..<4])))
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
