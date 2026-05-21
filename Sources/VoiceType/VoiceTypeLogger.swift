import Foundation

enum VoiceTypeLogger {
    private static let queue = DispatchQueue(label: "VoiceType.Logger")
    private static let formatter = ISO8601DateFormatter()

    static var logFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VoiceType/voice-type.log")
    }

    static func log(_ message: String) {
        write(level: "INFO", message: message)
    }

    static func warning(_ message: String) {
        write(level: "WARN", message: message)
    }

    static func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    static func error(_ message: String, error: Error) {
        write(level: "ERROR", message: "\(message) error=\(error.localizedDescription)")
    }

    static func readTail(maxLines: Int = 300) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: logFileURL),
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }

    static func diagnosticsSnapshot(maxLines: Int = 400) -> String {
        let process = ProcessInfo.processInfo
        let header = [
            "VoiceType diagnostics",
            "Generated: \(formatter.string(from: Date()))",
            "Bundle: \(Bundle.main.bundlePath)",
            "Executable: \(Bundle.main.executableURL?.path ?? "nil")",
            "Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
            "Process: pid=\(process.processIdentifier) macOS=\(process.operatingSystemVersionString)",
            "Log: \(logFileURL.path)",
            "---- recent log ----"
        ].joined(separator: "\n")
        let tail = readTail(maxLines: maxLines)
        return tail.isEmpty ? header + "\n<empty>" : header + "\n" + tail
    }

    private static func write(level: String, message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "\(timestamp) [\(level)] \(message)\n"
        NSLog("VoiceType %@", message)
        queue.async {
            do {
                let url = logFileURL
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
            try? FileManager.default.removeItem(at: logFileURL)
        }
    }
}
