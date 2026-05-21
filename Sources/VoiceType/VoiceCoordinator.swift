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

    init(floatingPanel: FloatingPanelController, localAI: LocalAIManager) {
        self.floatingPanel = floatingPanel
        self.localAI = localAI
    }

    func injectDiagnosticText(_ text: String) {
        VoiceTypeLogger.log("coordinator.injectDiagnosticText")
        pipeline.injectImmediate(text)
    }

    func beginHold() {
        guard !isRecording else { return }
        VoiceTypeLogger.log("coordinator.beginHold")
        isRecording = true
        pipeline.setRecordingActive(true)
        lastHoldStartedAt = Date()
        let sessionID = UUID()
        activeSessionID = sessionID

        let backend = settings.backend
        let language = settings.language
        let inputDeviceUID = settings.selectedInputDeviceUID
        floatingPanel.show(text: backend == .appleSpeech ? "Listening..." : "Recording...")

        let capture = SpeechCaptureSession(backend: backend, language: language, inputDeviceUID: inputDeviceUID)
        session = capture
        do {
            try capture.start(
                partialHandler: { [weak self] text in
                    guard let self, self.activeSessionID == sessionID else { return }
                    self.floatingPanel.update(text: text)
                },
                rmsHandler: { [weak self] rms in
                    guard let self, self.activeSessionID == sessionID else { return }
                    self.floatingPanel.update(level: rms)
                }
            )
        } catch {
            isRecording = false
            session = nil
            activeSessionID = nil
            pipeline.setRecordingActive(false)
            VoiceTypeLogger.log("coordinator.beginHold.failed \(error.localizedDescription)")
            showTemporaryError("Recording failed: \(error.localizedDescription)")
        }
    }

    func endHold() {
        guard isRecording, let session else { return }
        VoiceTypeLogger.log("coordinator.endHold")
        let releasedBackend = settings.backend
        let releasedLanguage = settings.language
        isRecording = false
        self.session = nil
        let releasedSessionID = activeSessionID
        activeSessionID = nil

        let minimumHold: TimeInterval = 0.12
        if let start = lastHoldStartedAt, Date().timeIntervalSince(start) < minimumHold {
            session.cancel()
            pipeline.setRecordingActive(false)
            floatingPanel.hide()
            VoiceTypeLogger.log("coordinator.endHold.tooShort")
            return
        }

        floatingPanel.updateStatus("Queued")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard self?.activeSessionID == nil else { return }
            self?.floatingPanel.hide()
        }

        session.stop { [weak self] appleText, audioURL in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.activeSessionID == nil || self.activeSessionID == releasedSessionID {
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
    }

    private func showTemporaryError(_ message: String) {
        floatingPanel.updateStatus(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.floatingPanel.hide()
        }
    }
}
