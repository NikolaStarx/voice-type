import Foundation

enum VoiceTypeLogger {
    private static let queue = DispatchQueue(label: "VoiceType.Logger")

    private static var logURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VoiceType/voice-type.log")
    }

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        NSLog("VoiceType %@", message)
        queue.async {
            do {
                let url = logURL
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                NSLog("VoiceType log write failed: %@", error.localizedDescription)
            }
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }
}
