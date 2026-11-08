import AppKit
import CoreGraphics
import CPrivate
import Foundation

/// Delivers input to one window without the shared pointer or the active app ever changing,
/// which is what lets the Mac and the tablet be used at the same time.
///
/// Field numbers and the focus record follow Cua Driver (MIT, github.com/trycua/cua) and yabai.
enum BackgroundInput {
    private typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetField = @convention(c) (CGEvent, UInt32, Int64) -> Void
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias PostRecord = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafePointer<UInt8>) -> OSStatus
    private typealias SetAuth = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias MakeAuth = @convention(c) (AnyObject, Selector, UnsafeRawPointer, pid_t, UInt32) -> AnyObject?
    private typealias PSNForPid = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(skylight, n).map { unsafeBitCast($0, to: T.self) } }
    private static let postFn = sym("SLEventPostToPid", PostToPid.self)
    private static let fieldFn = sym("SLEventSetIntegerValueField", SetField.self)
    private static let locationFn = sym("CGEventSetWindowLocation", SetWindowLocation.self)
    private static let recordFn = sym("SLPSPostEventRecordTo", PostRecord.self)
    private static let psnFn: PSNForPid? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: PSNForPid.self) }

    static var available: Bool { postFn != nil && fieldFn != nil && locationFn != nil }

    /// `p` is window-local.
    static func send(_ e: CGEvent, to t: InputTarget, at p: CGPoint, fields: [(UInt32, Int64)] = []) {
        guard let postFn, let fieldFn, let locationFn else { return }
        locationFn(e, p)
        for (f, v) in fields { fieldFn(e, f, v) }
        fieldFn(e, 51, Int64(t.window))
        fieldFn(e, 91, Int64(t.window))
        fieldFn(e, 92, Int64(t.window))
        fieldFn(e, 40, Int64(t.pid))
        postFn(t.pid, e)
    }

    /// Sends a key to the app. Chromium ignores unsigned keys, so those carry WindowServer's authentication message.
    static func key(_ e: CGEvent, pid: pid_t) {
        guard let postFn else { e.postToPid(pid); return }
        if isChromium(pid), !e.flags.contains(.maskCommand), let cls = NSClassFromString("SLSEventAuthenticationMessage") as AnyObject?,
           let set = sym("SLEventSetAuthenticationMessage", SetAuth.self) {
            let raw = UnsafeRawPointer(Unmanaged.passUnretained(e).toOpaque())
            let selector = NSSelectorFromString("messageWithEventRecord:pid:version:")
            for off in [24, 32, 16] {
                guard let rec = raw.load(fromByteOffset: off, as: UnsafeRawPointer?.self) else { continue }
                if cls.responds(to: selector) {
                    let imp = unsafeBitCast(cls.method(for: selector), to: MakeAuth.self)
                    if let msg = imp(cls, selector, rec, pid, 0) { set(e, msg) }
                }
                break
            }
        }
        postFn(pid, e)
    }

    private static var chromium: [pid_t: Bool] = [:]
    static func isChromium(_ pid: pid_t) -> Bool {
        if let v = chromium[pid] { return v }
        var found = false
        if let u = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks"),
           let items = try? FileManager.default.contentsOfDirectory(atPath: u.path) {
            found = items.contains { n in ["chrome", "chromium", "electron", "brave", "edge"].contains { n.lowercased().contains($0) } }
        }
        chromium[pid] = found
        return found
    }

    /// Makes a window key inside its own app only; the app the Mac is using is not told anything.
    static func makeKey(_ t: InputTarget) {
        guard let recordFn, let psnFn else { return }
        var psn = ProcessSerialNumber()
        guard psnFn(t.pid, &psn) == noErr else { return }
        var r = [UInt8](repeating: 0, count: 0xF8)
        r[0x04] = 0xF8
        withUnsafeBytes(of: t.window.littleEndian) { r.replaceSubrange(0x3C..<0x40, with: $0) }
        r[0x08] = 0x0D; r[0x8A] = 0x01
        _ = recordFn(&psn, r)
        r[0x8A] = 0
        r[0x3A] = 0x10
        for i in 0x20..<0x30 { r[i] = 0xFF }
        for kind: UInt8 in [0x01, 0x02] { r[0x08] = kind; _ = recordFn(&psn, r) }
    }
}
