import CryptoKit
import Foundation
import Network

/// The shared secret for wireless links. It's created here and handed to the tablet over USB once.
enum Pairing {
    private static var directory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyTablet")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var keyURL: URL { directory.appendingPathComponent("wifi.key") }
    private static var hostURL: URL { directory.appendingPathComponent("wifi.host") }

    static var key: Data? { (try? Data(contentsOf: keyURL)).flatMap { $0.count == 32 ? $0 : nil } }

    static func keyCreatingIfNeeded() -> Data {
        if let k = key { return k }
        let k = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        FileManager.default.createFile(atPath: keyURL.path, contents: k, attributes: [.posixPermissions: 0o600])
        return k
    }

    static var lastHost: String? {
        get { (try? String(contentsOf: hostURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        set { try? newValue?.write(to: hostURL, atomically: true, encoding: .utf8) }
    }
}

/// Finds the paired tablet on the local network, so a changed IP address doesn't break the link.
final class TabletBrowser {
    private let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_mytablet._tcp", domain: nil), using: .tcp)
    private let lock = NSLock()
    private var found: String?
    var host: String? { lock.lock(); defer { lock.unlock() }; return found }

    func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var ip: String?
            for r in results {
                if case .bonjour(let txt) = r.metadata, let v = txt["ip"] { ip = v }
            }
            self.lock.lock(); self.found = ip; self.lock.unlock()
        }
        browser.start(queue: .global(qos: .utility))
    }
}

/// Authenticated encryption for one wireless session. Records are length-prefixed AES-256-GCM.
final class SecureRecords {
    private let key: SymmetricKey
    private var sendCounter: UInt64 = 0, recvCounter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    private func nonce(_ direction: UInt32, _ counter: UInt64) throws -> AES.GCM.Nonce {
        var d = Data()
        withUnsafeBytes(of: direction.bigEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: d)
    }

    /// Returns the record to write: 4-byte length, ciphertext, tag.
    func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce(1, sendCounter))
        sendCounter += 1
        var out = Data(capacity: plain.count + 20)
        withUnsafeBytes(of: UInt32(plain.count + 16).bigEndian) { out.append(contentsOf: $0) }
        out.append(box.ciphertext); out.append(box.tag)
        return out
    }

    func open(_ record: Data) throws -> Data {
        let tagStart = record.count - 16
        let box = try AES.GCM.SealedBox(nonce: nonce(2, recvCounter), ciphertext: record.prefix(tagStart), tag: record.suffix(16))
        recvCounter += 1
        return try AES.GCM.open(box, using: key)
    }

    static func hmac(_ key: Data, _ label: String, _ a: Data, _ b: Data) -> Data {
        var m = HMAC<SHA256>(key: SymmetricKey(data: key))
        m.update(data: Data(label.utf8)); m.update(data: a); m.update(data: b)
        return Data(m.finalize())
    }
}
