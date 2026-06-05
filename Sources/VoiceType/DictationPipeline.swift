import Foundation

final class DictationPipeline {
    private let settings = SettingsStore.shared
    private let localAI: LocalAIManager
    private let cloudSTT = CloudSTTTranscriber()
    private let llmRefiner = LLMRefiner()
    private let injectionScheduler: InjectionScheduler
    private let stateQueue = DispatchQueue(label: "VoiceType.DictationPipeline.state")

    private var nextSequence = 1

    init(localAI: LocalAIManager, injector: TextInjector) {
        self.localAI = localAI
        self.injectionScheduler = InjectionScheduler(injector: injector)
    }

    func setRecordingActive(_ active: Bool) {
        VoiceTypeLogger.log("pipeline.recordingActive=\(active)")
        injectionScheduler.setRecordingActive(active)
    }

    func submit(appleText: String, audioURL: URL?, backend: SpeechBackend, language: LanguageOption) {
        let sequence = reserveSequence()
        VoiceTypeLogger.log("pipeline.submit sequence=\(sequence) backend=\(backend.rawValue) appleChars=\(appleText.count) audio=\(audioURL?.path ?? "nil")")
        if backend != .appleSpeech {
            postStatus(.queued)
        }
        let job = DictationJob(
            sequence: sequence,
            backend: backend,
            language: language,
            llmSettings: settings.llm,
            cloudSettings: settings.cloudSTT,
            appleText: appleText,
            audioURL: audioURL,
            segmentationMode: .profile
        )
        injectionScheduler.registerJob(sequence: sequence)
        resolveSTT(for: job)
    }

    func submitTextBatch(_ text: String, llmSettings: LLMSettings, presegmented: Bool) {
        let sequence = reserveSequence()
        VoiceTypeLogger.log("pipeline.submitTextBatch sequence=\(sequence) chars=\(text.count) presegmented=\(presegmented)")
        let job = DictationJob(
            sequence: sequence,
            backend: .appleSpeech,
            language: SettingsStore.shared.language,
            llmSettings: llmSettings,
            cloudSettings: settings.cloudSTT,
            appleText: text,
            audioURL: nil,
            segmentationMode: presegmented ? .presegmentedBatch : .profile
        )
        injectionScheduler.registerJob(sequence: sequence)
        handleTranscript(text, for: job)
    }

    func injectImmediate(_ text: String) {
        submitTextBatch(text, llmSettings: settings.llm, presegmented: true)
    }

    private func reserveSequence() -> Int {
        stateQueue.sync {
            let value = nextSequence
            nextSequence += 1
            return value
        }
    }

    private func resolveSTT(for job: DictationJob) {
        VoiceTypeLogger.log("pipeline.resolveSTT sequence=\(job.sequence) backend=\(job.backend.rawValue)")
        switch job.backend {
        case .appleSpeech:
            postStatus(.transcribing("Finalizing..."))
            let trimmedAppleText = job.appleText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAppleText.isEmpty {
                handleTranscript(trimmedAppleText, for: job)
                return
            }
            guard let audioURL = job.audioURL else {
                VoiceTypeLogger.warning("pipeline.appleSpeech.empty.noAudio sequence=\(job.sequence)")
                handleTranscript("", for: job)
                return
            }
            let fallbackModel = LocalASRModel.qwen06
            VoiceTypeLogger.warning("pipeline.appleSpeech.empty.fallbackLocal sequence=\(job.sequence) model=\(fallbackModel.repoID) audio=\(audioURL.path)")
            postStatus(.transcribing("Transcribing locally..."))
            localAI.transcribe(audioURL: audioURL, model: fallbackModel, language: job.language) { [weak self] result in
                switch result {
                case .success(let text):
                    VoiceTypeLogger.log("pipeline.appleSpeech.fallbackLocal.success sequence=\(job.sequence) chars=\(text.count)")
                    self?.handleTranscript(text, for: job)
                case .failure(let error):
                    VoiceTypeLogger.error("pipeline.appleSpeech.fallbackLocal.failure sequence=\(job.sequence)", error: error)
                    self?.postStatus(.failed("No speech detected"))
                    self?.injectionScheduler.finishJob(sequence: job.sequence)
                }
            }
        case .localQwen06, .localQwen17:
            guard let model = job.backend.localModel, let audioURL = job.audioURL else {
                VoiceTypeLogger.warning("pipeline.localSTT.noAudio sequence=\(job.sequence)")
                postStatus(.failed("No speech detected"))
                injectionScheduler.finishJob(sequence: job.sequence)
                return
            }
            postStatus(.transcribing("Transcribing locally..."))
            localAI.transcribe(audioURL: audioURL, model: model, language: job.language) { [weak self] result in
                switch result {
                case .success(let text):
                    VoiceTypeLogger.log("pipeline.localSTT.success sequence=\(job.sequence) chars=\(text.count)")
                    self?.postStatus(.transcribing("Local transcription ready"))
                    self?.handleTranscript(text, for: job)
                case .failure:
                    VoiceTypeLogger.error("pipeline.localSTT.failure sequence=\(job.sequence)")
                    self?.postStatus(.failed("Local STT failed. Open Diagnostics."))
                    self?.injectionScheduler.finishJob(sequence: job.sequence)
                }
            }
        case .cloud:
            guard let audioURL = job.audioURL else {
                VoiceTypeLogger.warning("pipeline.cloudSTT.noAudio sequence=\(job.sequence)")
                postStatus(.failed("No speech detected"))
                injectionScheduler.finishJob(sequence: job.sequence)
                return
            }
            postStatus(.transcribing("Uploading audio..."))
            cloudSTT.transcribe(audioURL: audioURL, language: job.language, settings: job.cloudSettings) { [weak self] result in
                switch result {
                case .success(let text):
                    VoiceTypeLogger.log("pipeline.cloudSTT.success sequence=\(job.sequence) chars=\(text.count)")
                    self?.postStatus(.transcribing("Cloud transcription ready"))
                    self?.handleTranscript(text, for: job)
                case .failure:
                    VoiceTypeLogger.error("pipeline.cloudSTT.failure sequence=\(job.sequence)")
                    self?.postStatus(.failed("Cloud STT failed. Open Diagnostics."))
                    self?.injectionScheduler.finishJob(sequence: job.sequence)
                }
            }
        }
    }

    private func handleTranscript(_ text: String, for job: DictationJob) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            VoiceTypeLogger.warning("pipeline.emptyTranscript sequence=\(job.sequence)")
            postStatus(.failed("No transcript captured"))
            injectionScheduler.finishJob(sequence: job.sequence)
            return
        }

        let segments = segments(for: trimmed, job: job)
        VoiceTypeLogger.log("pipeline.handleTranscript sequence=\(job.sequence) chars=\(trimmed.count) segments=\(segments.count) text=\(trimmed)")
        guard !segments.isEmpty else {
            postStatus(.failed("No transcript segments"))
            injectionScheduler.finishJob(sequence: job.sequence)
            return
        }

        guard shouldRefine(job.llmSettings) else {
            postStatus(.inserting)
            for (index, segment) in segments.enumerated() {
                injectionScheduler.enqueue(
                    text: segment.text + segment.suffix,
                    sequence: job.sequence,
                    segmentIndex: index,
                    segmentCount: segments.count
                )
            }
            return
        }

        postStatus(.refining)
        refineSegments(segments, for: job)
    }

    private func refineSegments(_ segments: [TranscriptSegment], for job: DictationJob) {
        let settings = job.llmSettings
        let maxConcurrent = maxConcurrentRefinements(for: settings.activeProfile.reasoningEffort)
        VoiceTypeLogger.log("pipeline.refine.start sequence=\(job.sequence) segments=\(segments.count) profile=\(settings.activeProfile.name) effort=\(settings.activeProfile.reasoningEffort.rawValue) maxConcurrent=\(maxConcurrent)")
        let coordinationQueue = DispatchQueue(label: "VoiceType.DictationPipeline.refine.\(job.sequence)")
        var nextIndex = 0
        var running = 0
        var completed = Set<Int>()

        func startMore() {
            coordinationQueue.async {
                while running < maxConcurrent && nextIndex < segments.count {
                    let index = nextIndex
                    let segment = segments[index]
                    nextIndex += 1
                    running += 1
                    VoiceTypeLogger.log("pipeline.refine.request sequence=\(job.sequence) segment=\(index)/\(segments.count) chars=\(segment.text.count) text=\(segment.text)")

                    func completeOnQueue(with text: String) {
                        guard !completed.contains(index) else { return }
                        completed.insert(index)
                        VoiceTypeLogger.log("pipeline.refine.complete sequence=\(job.sequence) segment=\(index) chars=\(text.count)")
                        self.postStatus(.inserting)
                        self.injectionScheduler.enqueue(
                            text: text + segment.suffix,
                            sequence: job.sequence,
                            segmentIndex: index,
                            segmentCount: segments.count
                        )
                        running -= 1
                        if nextIndex < segments.count {
                            startMore()
                        }
                    }

                    var task: URLSessionDataTask?
                    task = self.llmRefiner.refine(text: segment.text, settings: settings) { result in
                        coordinationQueue.async {
                            guard !completed.contains(index) else { return }
                            let refined: String
                            switch result {
                            case .success(let value):
                                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                refined = clean.isEmpty ? segment.text : clean
                            case .failure(let error):
                                VoiceTypeLogger.error("pipeline.refine.failure sequence=\(job.sequence) segment=\(index)", error: error)
                                refined = segment.text
                            }
                            completeOnQueue(with: refined)
                        }
                    }

                    let timeout = self.softTimeout(for: settings.activeProfile.reasoningEffort, text: segment.text)
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                        coordinationQueue.async {
                            guard !completed.contains(index) else { return }
                            VoiceTypeLogger.warning("pipeline.refine.timeout sequence=\(job.sequence) segment=\(index) timeout=\(timeout)")
                            task?.cancel()
                            completeOnQueue(with: segment.text)
                        }
                    }
                }
            }
        }

        startMore()
    }

    private func postStatus(_ status: VoiceTypePipelineStatus) {
        VoiceTypeLogger.log("pipeline.status \(status.title)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voiceTypePipelineStatusChanged, object: status)
        }
    }

    private func shouldRefine(_ settings: LLMSettings) -> Bool {
        settings.enabled &&
        !settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func segments(for text: String, job: DictationJob) -> [TranscriptSegment] {
        switch job.segmentationMode {
        case .presegmentedBatch:
            return [TranscriptSegment(text: text, suffix: "")]
        case .profile:
            let strategy = job.llmSettings.activeProfile.segmentationStrategy
            switch strategy {
            case .wholeUtterance:
                return [TranscriptSegment(text: text, suffix: "")]
            case .smartSentences:
                return TranscriptSegmenter.segments(from: text)
            case .pauseBatches:
                return TranscriptSegmenter.segments(from: text)
            }
        }
    }

    private func maxConcurrentRefinements(for effort: ReasoningEffort) -> Int {
        switch effort {
        case .minimal, .low: return 4
        case .medium: return 3
        case .high: return 2
        }
    }

    private func softTimeout(for effort: ReasoningEffort, text: String) -> TimeInterval {
        let lengthBonus = min(4.0, Double(text.count) / 120.0)
        switch effort {
        case .minimal: return 3.0 + lengthBonus
        case .low: return 4.5 + lengthBonus
        case .medium: return 7.0 + lengthBonus
        case .high: return 12.0 + lengthBonus
        }
    }
}

private struct DictationJob {
    var sequence: Int
    var backend: SpeechBackend
    var language: LanguageOption
    var llmSettings: LLMSettings
    var cloudSettings: CloudSTTSettings
    var appleText: String
    var audioURL: URL?
    var segmentationMode: SegmentationMode
}

private enum SegmentationMode {
    case profile
    case presegmentedBatch
}

private struct TranscriptSegment {
    var text: String
    var suffix: String
}

private enum TranscriptSegmenter {
    private static let hardLimit = 260
    private static let softLimit = 180
    private static let terminators = Set("。！？!?；;\n")

    static func segments(from text: String) -> [TranscriptSegment] {
        let sentences = splitSentences(text)
        let chunks = chunk(sentences)
        return chunks.enumerated().map { index, chunk in
            let next = index + 1 < chunks.count ? chunks[index + 1] : nil
            return TranscriptSegment(text: chunk, suffix: suffix(after: chunk, before: next))
        }
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if terminators.contains(character) {
                appendCurrent(&current, to: &result)
            } else if current.count >= hardLimit, character.isWhitespace {
                appendCurrent(&current, to: &result)
            }
        }
        appendCurrent(&current, to: &result)
        return result
    }

    private static func chunk(_ sentences: [String]) -> [String] {
        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count <= softLimit {
                current += sentence
            } else {
                appendCurrent(&current, to: &chunks)
                current = sentence
            }
        }
        appendCurrent(&current, to: &chunks)
        return chunks
    }

    private static func appendCurrent(_ current: inout String, to result: inout [String]) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }
        current.removeAll(keepingCapacity: true)
    }

    private static func suffix(after current: String, before next: String?) -> String {
        guard let next, let last = current.last, let first = next.first else { return "" }
        if last.isWhitespace { return "" }
        if isCJK(first) || isCJK(last) { return "" }
        if "。！？；，、".contains(last) { return "" }
        return " "
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
            (0x3040...0x30FF).contains(Int(scalar.value)) ||
            (0xAC00...0xD7AF).contains(Int(scalar.value))
        }
    }
}

private final class InjectionScheduler {
    private let queue = DispatchQueue(label: "VoiceType.InjectionScheduler")
    private let injector: TextInjector

    private var segmentCounts: [Int: Int] = [:]
    private var pendingSegments: [Int: [Int: String]] = [:]
    private var expectedSequence = 1
    private var expectedSegmentIndex = 0
    private var recordingActive = false
    private var injecting = false

    init(injector: TextInjector) {
        self.injector = injector
    }

    func setRecordingActive(_ active: Bool) {
        queue.async {
            self.recordingActive = active
            VoiceTypeLogger.log("injectorScheduler.recordingActive=\(active)")
            self.drain()
        }
    }

    func registerJob(sequence: Int) {
        queue.async {
            VoiceTypeLogger.log("injectorScheduler.registerJob sequence=\(sequence) expectedSequence=\(self.expectedSequence)")
            if self.expectedSequence == 1 && sequence < self.expectedSequence {
                self.expectedSequence = sequence
            }
        }
    }

    func finishJob(sequence: Int) {
        queue.async {
            VoiceTypeLogger.log("injectorScheduler.finishJob sequence=\(sequence)")
            self.segmentCounts[sequence] = 0
            self.pendingSegments[sequence] = [:]
            self.drain()
        }
    }

    func enqueue(text: String, sequence: Int, segmentIndex: Int, segmentCount: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            self.segmentCounts[sequence] = segmentCount
            guard !trimmed.isEmpty else {
                self.drain()
                return
            }
            var segments = self.pendingSegments[sequence] ?? [:]
            segments[segmentIndex] = text
            self.pendingSegments[sequence] = segments
            VoiceTypeLogger.log("injectorScheduler.enqueue sequence=\(sequence) segment=\(segmentIndex)/\(segmentCount) chars=\(text.count) text=\(text)")
            self.drain()
        }
    }

    private func drain() {
        guard !recordingActive else {
            VoiceTypeLogger.log("injectorScheduler.drain.blocked recordingActive=true expectedSequence=\(expectedSequence) expectedSegment=\(expectedSegmentIndex)")
            return
        }
        guard !injecting else {
            VoiceTypeLogger.log("injectorScheduler.drain.blocked injecting=true expectedSequence=\(expectedSequence) expectedSegment=\(expectedSegmentIndex)")
            return
        }

        while segmentCounts[expectedSequence] == 0 {
            VoiceTypeLogger.log("injectorScheduler.drain.skipEmpty sequence=\(expectedSequence)")
            segmentCounts.removeValue(forKey: expectedSequence)
            pendingSegments.removeValue(forKey: expectedSequence)
            expectedSequence += 1
            expectedSegmentIndex = 0
        }

        guard let segmentCount = segmentCounts[expectedSequence], segmentCount > 0 else {
            VoiceTypeLogger.log("injectorScheduler.drain.waitingForJob expectedSequence=\(expectedSequence)")
            return
        }
        guard let text = pendingSegments[expectedSequence]?[expectedSegmentIndex] else {
            let available = pendingSegments[expectedSequence]?.keys.sorted().map(String.init).joined(separator: ",") ?? ""
            VoiceTypeLogger.log("injectorScheduler.drain.waitingForSegment sequence=\(expectedSequence) expectedSegment=\(expectedSegmentIndex) available=[\(available)]")
            return
        }

        pendingSegments[expectedSequence]?[expectedSegmentIndex] = nil
        injecting = true
        VoiceTypeLogger.log("injectorScheduler.inject sequence=\(expectedSequence) segment=\(expectedSegmentIndex) chars=\(text.count)")
        DispatchQueue.main.async {
            self.injector.inject(text: text) { success in
                self.queue.async {
                    VoiceTypeLogger.log("injectorScheduler.inject.complete success=\(success)")
                    self.injecting = false
                    self.expectedSegmentIndex += 1
                    if self.expectedSegmentIndex >= segmentCount {
                        self.segmentCounts.removeValue(forKey: self.expectedSequence)
                        self.pendingSegments.removeValue(forKey: self.expectedSequence)
                        self.expectedSequence += 1
                        self.expectedSegmentIndex = 0
                    }
                    if success && self.isIdle {
                        self.postStatus(.done)
                    } else if !success {
                        self.postStatus(.failed("Text injection failed"))
                    }
                    self.drain()
                }
            }
        }
    }

    private var isIdle: Bool {
        !recordingActive &&
        !injecting &&
        segmentCounts.isEmpty &&
        pendingSegments.isEmpty
    }

    private func postStatus(_ status: VoiceTypePipelineStatus) {
        VoiceTypeLogger.log("injectorScheduler.status \(status.title)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voiceTypePipelineStatusChanged, object: status)
        }
    }
}

private extension Character {
    var isWhitespace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
