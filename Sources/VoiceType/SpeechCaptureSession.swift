import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import Speech

final class SpeechCaptureSession: NSObject {
    private let id = UUID().uuidString
    private let backend: SpeechBackend
    private let language: LanguageOption
    private let inputDeviceUID: String
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "VoiceType.CaptureSession.Audio")
    private let dataOutput = AVCaptureAudioDataOutput()
    private let fileOutput = AVCaptureAudioFileOutput()
    private let minimumUsablePeak: Float = 0.0035
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestText = ""
    private var finalText = ""
    private var didStop = false
    private var didComplete = false
    private let audioURL: URL
    private var tapFrames: AVAudioFramePosition = 0
    private var tapStartedAt = Date()
    private var lastAudioLogAt = Date.distantPast
    private var rmsPeak: Float = 0
    private var didLogSampleFormat = false
    private var stopCompletion: ((String, URL?) -> Void)?
    private var rmsHandler: ((Float) -> Void)?
    private var discardAudioAfterStop = false

    var debugID: String { id }

    init(backend: SpeechBackend, language: LanguageOption, inputDeviceUID: String) {
        self.backend = backend
        self.language = language
        self.inputDeviceUID = inputDeviceUID
        self.audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceType-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }

    func start(partialHandler: @escaping (String) -> Void, rmsHandler: @escaping (Float) -> Void) throws {
        self.rmsHandler = rmsHandler
        tapStartedAt = Date()
        lastAudioLogAt = Date.distantPast
        rmsPeak = 0
        tapFrames = 0
        didLogSampleFormat = false
        discardAudioAfterStop = false

        let device = try configureCaptureSession()
        VoiceTypeLogger.log("capture.start id=\(id) backend=\(backend.rawValue) language=\(language.rawValue) inputDevice=\(inputDeviceUID.isEmpty ? "default" : inputDeviceUID) captureDevice=\(device.localizedName)|\(device.uniqueID) audio=\(audioURL.path)")

        if backend == .appleSpeech {
            try startAppleRecognition(partialHandler: partialHandler)
        }

        captureSession.startRunning()
        guard captureSession.isRunning else {
            throw NSError.voiceType("Audio capture session did not start")
        }
        fileOutput.startRecording(to: audioURL, outputFileType: .wav, recordingDelegate: self)
        VoiceTypeLogger.log("capture.session.started id=\(id) running=\(captureSession.isRunning) dataConnections=\(dataOutput.connections.count) fileConnections=\(fileOutput.connections.count)")
    }

    func stop(completion: @escaping (String, URL?) -> Void) {
        guard !didStop else { return }
        didStop = true
        recognitionRequest?.endAudio()
        discardAudioAfterStop = backend != .appleSpeech && tapFrames > 0 && rmsPeak < minimumUsablePeak
        if discardAudioAfterStop {
            VoiceTypeLogger.warning("capture.silenceDetected id=\(id) peak=\(String(format: "%.5f", rmsPeak)) threshold=\(String(format: "%.5f", minimumUsablePeak)) frames=\(tapFrames)")
        }
        VoiceTypeLogger.log("capture.stop id=\(id) endAudio latestChars=\(latestText.count) finalChars=\(finalText.count) frames=\(tapFrames) peak=\(String(format: "%.5f", rmsPeak)) audio=\(audioURL.path)")

        stopCompletion = completion
        if fileOutput.isRecording {
            fileOutput.stopRecording()
        } else {
            captureSession.stopRunning()
            finishStop(audioURL: audioURL, error: nil)
        }
    }

    func cancel() {
        didStop = true
        if fileOutput.isRecording {
            fileOutput.stopRecording()
        }
        captureSession.stopRunning()
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
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
                VoiceTypeLogger.error("appleSpeech.error id=\(self.id)", error: error)
            }
        }
    }

    private func configureCaptureSession() throws -> AVCaptureDevice {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        if captureSession.canSetSessionPreset(.high) {
            captureSession.sessionPreset = .high
        }

        let device = try captureDevice()
        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw NSError.voiceType("Cannot add input device \(device.localizedName)")
        }
        captureSession.addInput(input)

        dataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        guard captureSession.canAddOutput(dataOutput) else {
            throw NSError.voiceType("Cannot add audio data output")
        }
        captureSession.addOutput(dataOutput)

        guard captureSession.canAddOutput(fileOutput) else {
            throw NSError.voiceType("Cannot add audio file output")
        }
        captureSession.addOutput(fileOutput)

        VoiceTypeLogger.log("capture.inputDevice.bound id=\(id) name=\(device.localizedName) uid=\(device.uniqueID) dataConnections=\(dataOutput.connections.count) fileConnections=\(fileOutput.connections.count)")
        return device
    }

    private func captureDevice() throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices
        VoiceTypeLogger.log("capture.devices id=\(id) devices=\(devices.map { "\($0.localizedName)|\($0.uniqueID)|connected=\($0.isConnected)" }.joined(separator: ";"))")

        if !inputDeviceUID.isEmpty {
            if let device = devices.first(where: { $0.uniqueID == inputDeviceUID }) {
                return device
            }
            VoiceTypeLogger.warning("capture.inputDevice.missing id=\(id) uid=\(inputDeviceUID); falling back to default audio device")
        }

        if let device = AVCaptureDevice.default(for: .audio) {
            VoiceTypeLogger.log("capture.inputDevice.default id=\(id) name=\(device.localizedName) uid=\(device.uniqueID)")
            return device
        }
        throw NSError.voiceType("No audio input device available")
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

    private func finishStop(audioURL: URL, error: Error?) {
        if let error {
            VoiceTypeLogger.error("capture.file.finishedWithError id=\(id) audio=\(audioURL.path)", error: error)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue ?? -1
        VoiceTypeLogger.log("capture.file.finished id=\(id) bytes=\(bytes) frames=\(tapFrames) peak=\(String(format: "%.5f", rmsPeak)) audio=\(audioURL.path)")

        guard let completion = stopCompletion else { return }
        stopCompletion = nil
        if discardAudioAfterStop {
            DispatchQueue.main.async {
                completion("", nil)
            }
            return
        }
        if backend == .appleSpeech {
            VoiceTypeLogger.log("capture.stop.waitForAppleFinal id=\(id) delay=2.2")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self.completeOnce(completion: completion)
            }
        } else {
            DispatchQueue.main.async {
                completion("", audioURL)
            }
        }
    }
}

extension SpeechCaptureSession: AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if backend == .appleSpeech {
            recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let rms = sampleBuffer.voiceTypeRMS()
        tapFrames += AVAudioFramePosition(frameCount)
        rmsPeak = max(rmsPeak, rms)

        if !didLogSampleFormat {
            didLogSampleFormat = true
            VoiceTypeLogger.log("capture.sampleFormat id=\(id) \(sampleBuffer.voiceTypeFormatDescription())")
        }

        let now = Date()
        if now.timeIntervalSince(lastAudioLogAt) >= 0.5 {
            lastAudioLogAt = now
            let elapsed = now.timeIntervalSince(tapStartedAt)
            VoiceTypeLogger.log("capture.audio id=\(id) elapsed=\(String(format: "%.2f", elapsed)) frames=\(tapFrames) sampleFrames=\(frameCount) rms=\(String(format: "%.5f", rms)) peak=\(String(format: "%.5f", rmsPeak))")
        }

        DispatchQueue.main.async { [rmsHandler] in
            rmsHandler?(rms)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        VoiceTypeLogger.log("capture.file.started id=\(id) audio=\(fileURL.path) connections=\(connections.count)")
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        captureSession.stopRunning()
        VoiceTypeLogger.log("capture.session.stopped id=\(id) running=\(captureSession.isRunning)")
        finishStop(audioURL: outputFileURL, error: error)
    }
}

extension NSError {
    static func voiceType(_ message: String) -> NSError {
        NSError(domain: "VoiceType", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension CMSampleBuffer {
    func voiceTypeFormatDescription() -> String {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return "format=unknown"
        }
        let asbd = streamDescription.pointee
        return "formatID=\(asbd.mFormatID) flags=\(asbd.mFormatFlags) sampleRate=\(String(format: "%.1f", asbd.mSampleRate)) channels=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame)"
    }

    func voiceTypeRMS() -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0
        }
        let asbd = streamDescription.pointee
        let flags = asbd.mFormatFlags
        let bits = asbd.mBitsPerChannel
        guard bits > 0 else { return 0 }

        var bufferListSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, bufferListSize > 0 else { return 0 }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }
        let audioBufferList = rawBufferList.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return 0 }

        var sum: Double = 0
        var sampleCount = 0
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if flags & kAudioFormatFlagIsFloat != 0, bits == 32 {
                let count = byteCount / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count {
                    let sample = Double(samples[index])
                    sum += sample * sample
                }
                sampleCount += count
            } else if flags & kAudioFormatFlagIsSignedInteger != 0, bits == 16 {
                let count = byteCount / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int16.max)
                    sum += sample * sample
                }
                sampleCount += count
            } else if flags & kAudioFormatFlagIsSignedInteger != 0, bits == 32 {
                let count = byteCount / MemoryLayout<Int32>.size
                let samples = data.bindMemory(to: Int32.self, capacity: count)
                for index in 0..<count {
                    let sample = Double(samples[index]) / Double(Int32.max)
                    sum += sample * sample
                }
                sampleCount += count
            }
        }

        guard sampleCount > 0 else { return 0 }
        return min(1, Float(sqrt(sum / Double(sampleCount))))
    }
}
