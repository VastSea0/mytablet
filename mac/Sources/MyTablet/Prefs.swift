import Foundation

/// Everything the tablet's Settings app can change.
struct ShellPrefs: Codable, Equatable {
    var dockLens = true, controlCenterLens = true, folderLens = true, keyboardLens = true, widgetLens = false
    var iconSize = 1, dockSize = 1
    var labels = true, dockRecents = true, keySounds = true
    var scrollSpeed = 1, longPress = 1
    var independentInput = true
}

enum Prefs {
    private static let lock = NSLock()
    private static let key = "shellPrefs"
    private static var value: ShellPrefs = {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(ShellPrefs.self, from: $0) } ?? ShellPrefs()
    }()
    static var current: ShellPrefs {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set {
            lock.lock(); value = newValue; lock.unlock()
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: key) }
        }
    }
    static func reset() { current = ShellPrefs() }
}
