import AppKit

struct AppEntry { let name: String; let url: URL; let icon: CGImage }

/// The apps actually installed on this Mac, plus the user's real Dock order.
enum AppCatalog {
    static func entry(_ url: URL) -> AppEntry? {
        // Resolve first: e.g. /Applications/Safari.app is a symlink and would get an alias badge.
        let icon = NSWorkspace.shared.icon(forFile: url.resolvingSymlinksInPath().path)
        var rect = CGRect(x: 0, y: 0, width: 256, height: 256)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return AppEntry(name: name, url: url, icon: cg)
    }

    static func installed() -> [AppEntry] {
        let fm = FileManager.default
        var dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        dirs += (try? fm.contentsOfDirectory(atPath: "/Applications"))?.filter { !$0.hasSuffix(".app") }.map { "/Applications/" + $0 } ?? []
        var seen = Set<String>(), out: [AppEntry] = []
        for d in dirs {
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".app") {
                let u = URL(fileURLWithPath: d).appendingPathComponent(f)
                let id = Bundle(url: u)?.bundleIdentifier ?? f
                if id == "dev.mytablet.host" || !seen.insert(id).inserted { continue }
                if let e = entry(u) { out.append(e) }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func dockApps() -> [AppEntry] {
        guard let items = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let td = item["tile-data"] as? [String: Any], let fd = td["file-data"] as? [String: Any],
                  let s = fd["_CFURLString"] as? String, let u = URL(string: s), u.pathExtension == "app",
                  FileManager.default.fileExists(atPath: u.path) else { return nil }
            return entry(u)
        }
    }
}
