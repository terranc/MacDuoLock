import Foundation
import os.log

enum MacLockLog {
    static let subsystem = "app.maclock"
    static let session = Logger(subsystem: subsystem, category: "session")
    static let presence = Logger(subsystem: subsystem, category: "presence")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let authtap = Logger(subsystem: subsystem, category: "authtap")

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MacLock.log")
    }()

    static func file(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        session.info("\(message, privacy: .public)")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
}
