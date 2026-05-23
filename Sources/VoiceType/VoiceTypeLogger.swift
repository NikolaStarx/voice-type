import Foundation

enum VoiceTypeLogger {
    private static let queue = DispatchQueue(label: "VoiceType.Logger")
    private static var lastCompactionAt: Date?
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let legacyFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

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

    static func flush() {
        queue.sync {}
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

    static func compactOldLogsIfNeeded() {
        queue.async {
            let now = Date()
            if let lastCompactionAt,
               now.timeIntervalSince(lastCompactionAt) < 24 * 60 * 60 {
                return
            }
            compactOldLogsLocked(now: now)
        }
    }

    static func compactOldLogsNow() {
        queue.async {
            compactOldLogsLocked(now: Date())
        }
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
                compactOldLogsIfNeededLocked(now: Date())
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

    private static func compactOldLogsIfNeededLocked(now: Date) {
        if let lastCompactionAt,
           now.timeIntervalSince(lastCompactionAt) < 24 * 60 * 60 {
            return
        }
        compactOldLogsLocked(now: now)
    }

    private static func compactOldLogsLocked(now: Date) {
        lastCompactionAt = now
        let url = logFileURL
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var selectedDayForBucket: [String: String] = [:]
        let kept = lines.filter { line in
            shouldKeep(line: line, now: now, selectedDayForBucket: &selectedDayForBucket)
        }
        guard kept.count < lines.count else { return }

        do {
            let compacted = kept.joined(separator: "\n")
            try compacted.write(to: url, atomically: true, encoding: .utf8)
            appendLocked(
                level: "INFO",
                message: "log.compact kept=\(kept.count) removed=\(lines.count - kept.count) policy=7d_all_30d_3day_180d_week_older_month"
            )
        } catch {
            NSLog("VoiceType log compaction failed: %@", error.localizedDescription)
        }
    }

    private static func shouldKeep(
        line: String,
        now: Date,
        selectedDayForBucket: inout [String: String]
    ) -> Bool {
        guard let date = date(from: line) else { return true }
        let calendar = Calendar(identifier: .gregorian)
        let dayStart = calendar.startOfDay(for: date)
        let nowStart = calendar.startOfDay(for: now)
        let ageDays = calendar.dateComponents([.day], from: dayStart, to: nowStart).day ?? 0
        if ageDays <= 7 { return true }

        let dayKey = dateKey(for: date, calendar: calendar)
        let bucket: String
        if ageDays <= 30 {
            bucket = "3d-\(Int(dayStart.timeIntervalSince1970 / (3 * 24 * 60 * 60)))"
        } else if ageDays <= 180 {
            let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            bucket = "week-\(week.yearForWeekOfYear ?? 0)-\(week.weekOfYear ?? 0)"
        } else {
            let month = calendar.dateComponents([.year, .month], from: date)
            bucket = "month-\(month.year ?? 0)-\(month.month ?? 0)"
        }

        if let selectedDay = selectedDayForBucket[bucket] {
            return selectedDay == dayKey
        }
        selectedDayForBucket[bucket] = dayKey
        return true
    }

    private static func date(from line: String) -> Date? {
        guard let timestamp = line.split(separator: " ", maxSplits: 1).first else {
            return nil
        }
        let raw = String(timestamp)
        return formatter.date(from: raw) ?? legacyFormatter.date(from: raw)
    }

    private static func dateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func appendLocked(level: String, message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        NSLog("VoiceType %@", message)
        let url = logFileURL
        do {
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
