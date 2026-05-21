import AVFoundation
import AudioToolbox
import Foundation
import Speech

final class SpeechCaptureSession {
    private let id = UUID().uuidString
    private let backend: SpeechBackend
    private let language: LanguageOption
    private let inputDeviceUID: String
    private let engine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var latestText = ""
    private var finalText = ""
    private var didStop = false
    private var didComplete = false
    private let audioURL: URL
    private var tapFrames: AVAudioFramePosition = 0
    private var tapStartedAt = Date()
    private var lastAudioLogAt = Date.distantPast
    private var rmsPeak: Float = 0

    init(backend: SpeechBackend, language: LanguageOption, inputDeviceUID: String) {
        self.backend = backend
        self.language = language
        self.inputDeviceUID = inputDeviceUID
        self.audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceType-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    func start(partialHandler: @escaping (String) -> Void, rmsHandler: @escaping (Float) -> Void) throws {
        let inputNode = engine.inputNode
        try configureInputDevice(on: inputNode)
        let format = inputNode.outputFormat(forBus: 0)
        audioFile = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        tapStartedAt = Date()
        lastAudioLogAt = Date.distantPast
        rmsPeak = 0
        tapFrames = 0
        VoiceTypeLogger.log("capture.start id=\(id) backend=\(backend.rawValue) language=\(language.rawValue) inputDevice=\(inputDeviceUID.isEmpty ? "default" : inputDeviceUID) format=\(format) audio=\(audioURL.path)")

        if backend == .appleSpeech {
            try startAppleRecognition(partialHandler: partialHandler)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                VoiceTypeLogger.log("capture.audioWrite.failed id=\(self.id) error=\(error.localizedDescription)")
            }
            self.recognitionRequest?.append(buffer)
            let rms = buffer.voiceTypeRMS()
            self.tapFrames += AVAudioFramePosition(buffer.frameLength)
            self.rmsPeak = max(self.rmsPeak, rms)
            let now = Date()
            if now.timeIntervalSince(self.lastAudioLogAt) >= 0.5 {
                self.lastAudioLogAt = now
                let elapsed = now.timeIntervalSince(self.tapStartedAt)
                VoiceTypeLogger.log("capture.audio id=\(self.id) elapsed=\(String(format: "%.2f", elapsed)) frames=\(self.tapFrames) rms=\(String(format: "%.5f", rms)) peak=\(String(format: "%.5f", self.rmsPeak))")
            }
            DispatchQueue.main.async {
                rmsHandler(rms)
            }
        }

        engine.prepare()
        try engine.start()
        VoiceTypeLogger.log("capture.engine.started id=\(id)")
    }

    func stop(completion: @escaping (String, URL?) -> Void) {
        guard !didStop else { return }
        didStop = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognitionRequest?.endAudio()
        audioFile = nil
        VoiceTypeLogger.log("capture.stop id=\(id) endAudio latestChars=\(latestText.count) finalChars=\(finalText.count) frames=\(tapFrames) peak=\(String(format: "%.5f", rmsPeak)) audio=\(audioURL.path)")

        if backend == .appleSpeech {
            VoiceTypeLogger.log("capture.stop.waitForAppleFinal id=\(id) delay=2.2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self.completeOnce(completion: completion)
            }
        } else {
            completion("", audioURL)
        }
    }

    func cancel() {
        didStop = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        audioFile = nil
        VoiceTypeLogger.log("capture.cancel id=\(id)")
    }

    private func startAppleRecognition(partialHandler: @escaping (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)) else {
            throw NSError.voiceType("Apple Speech does not support \(language.title)")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        recognitionRequest = request

        VoiceTypeLogger.log("appleSpeech.start id=\(id) available=\(recognizer.isAvailable) locale=\(language.rawValue) auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                self.latestText = text
                if result?.isFinal == true {
                    self.finalText = text
                }
                VoiceTypeLogger.log("appleSpeech.result id=\(self.id) final=\(result?.isFinal == true) chars=\(text.count) text=\(text)")
                DispatchQueue.main.async {
                    partialHandler(text)
                }
            }
            if let error {
                VoiceTypeLogger.log("appleSpeech.error id=\(self.id) \(error.localizedDescription)")
            }
        }
    }

    private func configureInputDevice(on inputNode: AVAudioInputNode) throws {
        guard let selected = AudioDeviceManager.device(for: inputDeviceUID) else {
            VoiceTypeLogger.log("capture.inputDevice.default id=\(id)")
            return
        }
        try inputNode.auAudioUnit.setDeviceID(selected.id)
        VoiceTypeLogger.log("capture.inputDevice.bound id=\(id) name=\(selected.name) uid=\(selected.uid) deviceID=\(selected.id)")
    }

    private func completeOnce(completion: @escaping (String, URL?) -> Void) {
        guard !didComplete else { return }
        didComplete = true
        let text = finalText.isEmpty ? latestText : finalText
        recognitionTask?.cancel()
        recognitionTask = nil
        VoiceTypeLogger.log("capture.complete id=\(id) chars=\(text.count) audioExists=\(FileManager.default.fileExists(atPath: audioURL.path)) text=\(text)")
        completion(text, audioURL)
    }
}

private extension AVAudioPCMBuffer {
    func voiceTypeRMS() -> Float {
        guard let channels = floatChannelData else { return 0 }
        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)
        guard channelCount > 0, frameCount > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<frameCount {
                let sample = data[frame]
                sum += sample * sample
            }
        }
        let mean = sum / Float(channelCount * frameCount)
        return min(1, sqrt(mean))
    }
}

extension NSError {
    static func voiceType(_ message: String) -> NSError {
        NSError(domain: "VoiceType", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
