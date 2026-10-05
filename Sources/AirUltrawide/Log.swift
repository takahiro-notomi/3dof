import Foundation

/// ~/Library/Logs/AirUltrawide.log に追記する簡易ログ
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AirUltrawide.log")
    private static let queue = DispatchQueue(label: "Log")
    private static let handle: FileHandle? = {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        queue.async { handle?.write(Data(line.utf8)) }
    }
}
