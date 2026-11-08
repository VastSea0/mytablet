import Foundation

enum WidgetKind: String, Codable, CaseIterable {
    case clock, calendar, events, battery, system
    var cells: (w: Int, h: Int) { self == .events ? (4, 2) : (2, 2) }
    var title: String {
        switch self {
        case .clock: return "Saat"
        case .calendar: return "Takvim"
        case .events: return "Yaklaşan Etkinlikler"
        case .battery: return "Pil"
        case .system: return "Sistem"
        }
    }
}

struct FolderModel: Codable, Equatable { var id: String; var name: String; var apps: [String] }

enum HomeItem: Codable, Equatable {
    case app(String), folder(FolderModel), widget(WidgetKind)
    var key: String {
        switch self {
        case .app(let p): return "a:" + p
        case .folder(let f): return "f:" + f.id
        case .widget(let w): return "w:" + w.rawValue
        }
    }
    var cells: (w: Int, h: Int) { if case .widget(let w) = self { return w.cells }; return (1, 1) }
}

struct HomeLayout: Codable {
    var pages: [[HomeItem]] = []
    var dock: [String] = []
    var hidden: [String] = []

    private static var url: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyTablet")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("layout.json")
    }

    static func load() -> HomeLayout? { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(HomeLayout.self, from: $0) } }
    func save() { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url, options: .atomic) } }
    static func reset() { try? FileManager.default.removeItem(at: url) }

    /// Drops apps that were uninstalled and appends newly installed ones.
    mutating func reconcile(installed: [String], dockDefault: [String]) {
        let have = Set(installed)
        if pages.isEmpty {
            pages = [[.widget(.clock), .widget(.calendar), .widget(.battery)]]
            dock = dockDefault
        }
        pages = pages.map { $0.compactMap { item in
            switch item {
            case .app(let p): return have.contains(p) ? item : nil
            case .folder(var f):
                f.apps = f.apps.filter(have.contains)
                return f.apps.isEmpty ? nil : .folder(f)
            case .widget: return item
            }
        } }
        dock = dock.filter(have.contains)
        var placed = Set(hidden)
        for item in pages.flatMap({ $0 }) {
            switch item {
            case .app(let p): placed.insert(p)
            case .folder(let f): placed.formUnion(f.apps)
            case .widget: break
            }
        }
        let missing = installed.filter { !placed.contains($0) }
        if pages.isEmpty { pages = [[]] }
        pages[pages.count - 1] += missing.map(HomeItem.app)
    }
}

/// Places items into a page grid in reading order; returns each item's origin cell and whatever didn't fit.
func flow(_ items: [HomeItem], cols: Int, rows: Int) -> (cells: [(c: Int, r: Int)], overflow: [HomeItem]) {
    var used = Array(repeating: Array(repeating: false, count: cols), count: rows)
    var out: [(c: Int, r: Int)] = [], overflow: [HomeItem] = []
    for item in items {
        let (w, h) = item.cells
        var spot: (Int, Int)?
        search: for r in 0..<rows where r + h <= rows {
            for c in 0..<cols where c + w <= cols {
                if (r..<(r + h)).allSatisfy({ y in (c..<(c + w)).allSatisfy { !used[y][$0] } }) { spot = (c, r); break search }
            }
        }
        guard let s = spot, overflow.isEmpty else { overflow.append(item); continue }
        for y in s.1..<(s.1 + h) { for x in s.0..<(s.0 + w) { used[y][x] = true } }
        out.append((s.0, s.1))
    }
    return (out, overflow)
}
