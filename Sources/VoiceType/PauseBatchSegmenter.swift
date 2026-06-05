import Foundation

final class PauseBatchSegmenter {
    private let llmSettings: LLMSettings
    private let pauseThreshold: TimeInterval
    private let submit: (String, LLMSettings) -> Void

    private var latestTranscript = ""
    private var lastFlushedTranscript = ""
    private var lastVoiceAt = Date()
    private var lastFlushAt = Date.distantPast
    private let voiceThreshold: Float = 0.018
    private let minimumFlushInterval: TimeInterval = 0.35
    private(set) var hasSubmittedBatches = false

    init(llmSettings: LLMSettings, submit: @escaping (String, LLMSettings) -> Void) {
        self.llmSettings = llmSettings
        self.pauseThreshold = max(0.2, min(5.0, llmSettings.activeProfile.pauseThresholdSeconds))
        self.submit = submit
        VoiceTypeLogger.log("pauseBatch.init profile=\(llmSettings.activeProfile.name) threshold=\(pauseThreshold)")
    }

    func updateTranscript(_ transcript: String) {
        latestTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceTypeLogger.log("pauseBatch.transcript chars=\(latestTranscript.count)")
    }

    func updateRMS(_ rms: Float) {
        let now = Date()
        if rms >= voiceThreshold {
            lastVoiceAt = now
            return
        }
        guard now.timeIntervalSince(lastVoiceAt) >= pauseThreshold,
              now.timeIntervalSince(lastFlushAt) >= minimumFlushInterval else {
            return
        }
        VoiceTypeLogger.log("pauseBatch.pauseDetected silence=\(String(format: "%.2f", now.timeIntervalSince(lastVoiceAt))) rms=\(String(format: "%.5f", rms))")
        flush(reason: "pause")
    }

    @discardableResult
    func flushFinal(_ finalTranscript: String) -> Bool {
        VoiceTypeLogger.log("pauseBatch.flushFinal finalChars=\(finalTranscript.count)")
        let trimmed = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            latestTranscript = trimmed
        }
        return flush(reason: "final")
    }

    @discardableResult
    private func flush(reason: String) -> Bool {
        let delta = unflushedDelta().trimmingCharacters(in: .whitespacesAndNewlines)
        guard delta.count >= 2 else {
            VoiceTypeLogger.log("pauseBatch.flush.skip reason=\(reason) deltaChars=\(delta.count) latestChars=\(latestTranscript.count) flushedChars=\(lastFlushedTranscript.count)")
            return false
        }
        lastFlushedTranscript = latestTranscript
        lastFlushAt = Date()
        hasSubmittedBatches = true
        VoiceTypeLogger.log("pauseBatch.flush reason=\(reason) threshold=\(pauseThreshold) chars=\(delta.count) text=\(delta)")
        submit(delta, llmSettings)
        return true
    }

    private func unflushedDelta() -> String {
        let full = latestTranscript
        guard !full.isEmpty else { return "" }
        guard !lastFlushedTranscript.isEmpty else { return full }
        if full.hasPrefix(lastFlushedTranscript) {
            let start = full.index(full.startIndex, offsetBy: lastFlushedTranscript.count)
            return String(full[start...])
        }
        if lastFlushedTranscript.hasPrefix(full) {
            return ""
        }

        let common = commonPrefixLength(full, lastFlushedTranscript)
        let minimumShared = min(full.count, lastFlushedTranscript.count)
        guard minimumShared == 0 || Double(common) / Double(minimumShared) >= 0.7 else {
            VoiceTypeLogger.log("pauseBatch.delta.skipLowCommonPrefix common=\(common) full=\(full.count) flushed=\(lastFlushedTranscript.count)")
            return ""
        }
        let start = full.index(full.startIndex, offsetBy: common)
        return String(full[start...])
    }

    private func commonPrefixLength(_ left: String, _ right: String) -> Int {
        var count = 0
        var leftIndex = left.startIndex
        var rightIndex = right.startIndex
        while leftIndex < left.endIndex && rightIndex < right.endIndex {
            guard left[leftIndex] == right[rightIndex] else { break }
            count += 1
            left.formIndex(after: &leftIndex)
            right.formIndex(after: &rightIndex)
        }
        return count
    }
}
