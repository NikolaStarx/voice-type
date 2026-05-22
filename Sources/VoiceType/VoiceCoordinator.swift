import AppKit
import Foundation

final class VoiceCoordinator {
    private let settings = SettingsStore.shared
    private let floatingPanel: FloatingPanelController
    private let localAI: LocalAIManager
    private let injector = TextInjector()
    private lazy var pipeline = DictationPipeline(localAI: localAI, injector: injector)

    private var session: SpeechCaptureSession?
    private var isRecording = false
    private var lastHoldStartedAt: Date?
    private var activeSessionID: UUID?
    private var activeBackend: SpeechBackend?
    private var pauseBatcher: PauseBatchSegmenter?
    private var retiredSessions: [ObjectIdentifier: SpeechCaptureSession] = [:]

    init(floatingPanel: FloatingPanelController, localAI: LocalAIManager) {
        self.floatingPanel = floatingPanel
        self.localAI = localAI
    }

    func injectDiagnosticText(_ text: String) {
        VoiceTypeLogger.log("coordinator.injectDiagnosticText")
        pipeline.injectImmediate(text)
    }

    func beginHold() {
        guard !isRecording else {
            VoiceTypeLogger.log("coordinator.beginHold.ignored alreadyRecording=true")
            return
        }
        isRecording = true
        lastHoldStartedAt = Date()
        let sessionID = UUID()
        activeSessionID = sessionID

        let backend = settings.backend
        let language = settings.language
        let inputDeviceUID = settings.selectedInputDeviceUID
        let llmSettings = settings.llm
        activeBackend = backend
        postRecordingState(active: true, backend: backend)
        pipeline.setRecordingActive(true)
        VoiceTypeLogger.log("coordinator.beginHold session=\(sessionID.uuidString) backend=\(backend.rawValue) language=\(language.rawValue) inputDevice=\(inputDeviceUID.isEmpty ? "default" : inputDeviceUID) llmEnabled=\(llmSettings.enabled) profile=\(llmSettings.activeProfile.name) segmentation=\(llmSettings.activeProfile.segmentationStrategy.rawValue)")
        if backend == .appleSpeech,
           llmSettings.activeProfile.segmentationStrategy == .pauseBatches {
            pauseBatcher = PauseBatchSegmenter(llmSettings: llmSettings) { [weak self] text, settings in
                self?.pipeline.submitTextBatch(text, llmSettings: settings, presegmented: true)
            }
            VoiceTypeLogger.log("coordinator.pauseBatcher.enabled threshold=\(llmSettings.activeProfile.pauseThresholdSeconds)")
        } else {
            pauseBatcher = nil
        }
        floatingPanel.show(text: backend == .appleSpeech ? "Listening..." : "Recording...")

        let capture = SpeechCaptureSession(backend: backend, language: language, inputDeviceUID: inputDeviceUID)
        session = capture
        do {
            try capture.start(
                partialHandler: { [weak self] text in
                    guard let self, self.activeSessionID == sessionID else { return }
                    VoiceTypeLogger.log("coordinator.partial session=\(sessionID.uuidString) chars=\(text.count)")
                    self.floatingPanel.update(text: text)
                    self.pauseBatcher?.updateTranscript(text)
                },
                rmsHandler: { [weak self] rms in
                    guard let self, self.activeSessionID == sessionID else { return }
                    self.floatingPanel.update(level: rms)
                    self.pauseBatcher?.updateRMS(rms)
                }
            )
        } catch {
            isRecording = false
            session = nil
            activeSessionID = nil
            activeBackend = nil
            pauseBatcher = nil
            retire(capture)
            postRecordingState(active: false, backend: backend)
            pipeline.setRecordingActive(false)
            VoiceTypeLogger.error("coordinator.beginHold.failed", error: error)
            showTemporaryError("Recording failed: \(error.localizedDescription)")
        }
    }

    func endHold() {
        guard isRecording, let session else { return }
        VoiceTypeLogger.log("coordinator.endHold session=\(activeSessionID?.uuidString ?? "nil")")
        let releasedBackend = activeBackend ?? settings.backend
        let releasedLanguage = settings.language
        let releasedPauseBatcher = pauseBatcher
        isRecording = false
        self.session = nil
        let releasedSessionID = activeSessionID
        activeSessionID = nil
        activeBackend = nil
        pauseBatcher = nil

        let minimumHold: TimeInterval = 0.12
        if let start = lastHoldStartedAt, Date().timeIntervalSince(start) < minimumHold {
            session.cancel()
            retire(session)
            postRecordingState(active: false, backend: releasedBackend)
            pipeline.setRecordingActive(false)
            floatingPanel.hide()
            VoiceTypeLogger.log("coordinator.endHold.tooShort held=\(Date().timeIntervalSince(start))")
            return
        }

        postRecordingState(active: false, backend: releasedBackend)
        let releaseStatus: VoiceTypePipelineStatus = releasedBackend == .appleSpeech ? .transcribing("Finalizing...") : .queued
        NotificationCenter.default.post(name: .voiceTypePipelineStatusChanged, object: releaseStatus)
        VoiceTypeLogger.log("coordinator.queued session=\(releasedSessionID?.uuidString ?? "nil") backend=\(releasedBackend.rawValue)")

        session.stop { [weak self] appleText, audioURL in
            guard let self else { return }
            DispatchQueue.main.async {
                let noNewRecording = self.activeSessionID == nil || self.activeSessionID == releasedSessionID
                VoiceTypeLogger.log("coordinator.captureStopped session=\(releasedSessionID?.uuidString ?? "nil") appleChars=\(appleText.count) audio=\(audioURL?.path ?? "nil") noNewRecording=\(noNewRecording)")
                if let releasedPauseBatcher, releasedBackend == .appleSpeech {
                    releasedPauseBatcher.flushFinal(appleText)
                    if noNewRecording {
                        self.pipeline.setRecordingActive(false)
                    }
                    return
                }
                if noNewRecording {
                    self.pipeline.setRecordingActive(false)
                }
                self.pipeline.submit(
                    appleText: appleText,
                    audioURL: audioURL,
                    backend: releasedBackend,
                    language: releasedLanguage
                )
            }
        }
        retire(session)
    }

    private func showTemporaryError(_ message: String) {
        floatingPanel.updateStatus(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.floatingPanel.hide()
        }
    }

    private func postRecordingState(active: Bool, backend: SpeechBackend) {
        NotificationCenter.default.post(
            name: .voiceTypeRecordingStateChanged,
            object: VoiceTypeRecordingState(active: active, backend: backend)
        )
    }

    private func retire(_ session: SpeechCaptureSession) {
        let id = ObjectIdentifier(session)
        retiredSessions[id] = session
        VoiceTypeLogger.log("coordinator.session.retired id=\(session.debugID) retained=\(retiredSessions.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self else { return }
            self.retiredSessions.removeValue(forKey: id)
            VoiceTypeLogger.log("coordinator.session.released id=\(session.debugID) retained=\(self.retiredSessions.count)")
        }
    }
}
