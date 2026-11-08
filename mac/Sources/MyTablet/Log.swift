import Foundation
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MyTablet.log")
    private static let q = DispatchQueue(label: "log")
    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    static func write(_ s: String) {
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        q.async { handle?.write(Data(line.utf8)); FileHandle.standardError.write(Data(line.utf8)) }
    }
}
