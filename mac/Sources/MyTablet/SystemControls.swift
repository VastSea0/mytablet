import AppKit
import AudioToolbox
import CoreAudio
import CoreWLAN

/// Real system switches behind Control Center.
enum SystemControls {
    // MARK: Wi-Fi
    static var wifiOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }
    static func setWifi(_ on: Bool) { try? CWWiFiClient.shared().interface()?.setPower(on) }

    // MARK: Bluetooth (IOBluetooth SPI; there is no public setter)
    private static let bt = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    private typealias GetFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32) -> Void
    static var bluetoothOn: Bool {
        guard let s = dlsym(bt, "IOBluetoothPreferenceGetControllerPowerState") else { return false }
        return unsafeBitCast(s, to: GetFn.self)() != 0
    }
    static func setBluetooth(_ on: Bool) {
        guard let s = dlsym(bt, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(s, to: SetFn.self)(on ? 1 : 0)
    }

    // MARK: Appearance
    static var darkMode: Bool { UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark" }
    static func setDarkMode(_ on: Bool) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"]
        try? p.run()
    }

    // MARK: Media keys
    enum MediaKey: Int32 { case play = 16, next = 17, previous = 18 }
    static func press(_ key: MediaKey) {
        for down in [true, false] {
            let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Volume
    private static var outputDevice: AudioDeviceID {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }
    private static var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    static var volume: Float {
        get {
            var v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(outputDevice, &volumeAddress, 0, nil, &size, &v)
            return v
        }
        set {
            var v = max(0, min(1, newValue))
            AudioObjectSetPropertyData(outputDevice, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    // MARK: Tablet brightness (travels over the stream link, so it works without a cable)
    static var sendTabletBrightness: ((Int) -> Void)?
    private static var lastBrightness = 128
    static func reportTabletBrightness(_ v: Int) { lastBrightness = v }
    static func setTabletBrightness(_ v: Double) {
        lastBrightness = Int(max(1, min(255, v * 255)))
        sendTabletBrightness?(lastBrightness)
    }
    static func tabletBrightness() -> Double { Double(lastBrightness) / 255 }

    static func screenshot(displayID: CGDirectDisplayID) {
        var n: UInt32 = 0; var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &n)
        guard let index = ids.prefix(Int(n)).firstIndex(of: displayID) else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let path = NSHomeDirectory() + "/Desktop/Tablet \(df.string(from: Date())).png"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-D", "\(index + 1)", path]
        try? p.run()
    }
}
