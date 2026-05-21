import AVFoundation
import AudioToolbox
import Foundation
import Speech

final class SpeechCaptureSession {
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
        VoiceTypeLogger.log("capture.start backend=\(backend.rawValue) language=\(language.rawValue) inputDevice=\(inputDeviceUID.isEmpty ? "default" : inputDeviceUID) format=\(format)")

        if backend == .appleSpeech {
            try startAppleRecognition(partialHandler: partialHandler)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                NSLog("VoiceType audio write failed: \(error.localizedDescription)")
            }
            self.recognitionRequest?.append(buffer)
            let rms = buffer.voiceTypeRMS()
            DispatchQueue.main.async {
                rmsHandler(rms)
            }
        }

        engine.prepare()
        try engine.start()
        VoiceTypeLogger.log("capture.engine.started")
    }

    func stop(completion: @escaping (String, URL?) -> Void) {
        guard !didStop else { return }
        didStop = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recognitionRequest?.endAudio()
        audioFile = nil
        VoiceTypeLogger.log("capture.stop endAudio latestChars=\(latestText.count) audio=\(audioURL.path)")

        if backend == .appleSpeech {
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
        VoiceTypeLogger.log("capture.cancel")
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

        VoiceTypeLogger.log("appleSpeech.start available=\(recognizer.isAvailable) locale=\(language.rawValue) auth=\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                self.latestText = text
                if result?.isFinal == true {
                    self.finalText = text
                }
                VoiceTypeLogger.log("appleSpeech.result final=\(result?.isFinal == true) chars=\(text.count) text=\(text)")
                DispatchQueue.main.async {
                    partialHandler(text)
                }
            }
            if let error {
                VoiceTypeLogger.log("appleSpeech.error \(error.localizedDescription)")
            }
        }
    }

    private func configureInputDevice(on inputNode: AVAudioInputNode) throws {
        guard let selected = AudioDeviceManager.device(for: inputDeviceUID) else { return }
        try inputNode.auAudioUnit.setDeviceID(selected.id)
        VoiceTypeLogger.log("capture.inputDevice.bound name=\(selected.name) uid=\(selected.uid) id=\(selected.id)")
    }

    private func completeOnce(completion: @escaping (String, URL?) -> Void) {
        guard !didComplete else { return }
        didComplete = true
        let text = finalText.isEmpty ? latestText : finalText
        recognitionTask?.cancel()
        recognitionTask = nil
        VoiceTypeLogger.log("capture.complete chars=\(text.count) audioExists=\(FileManager.default.fileExists(atPath: audioURL.path))")
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
