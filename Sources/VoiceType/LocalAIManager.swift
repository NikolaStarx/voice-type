import Foundation

final class LocalAIManager {
    static let shared = LocalAIManager()

    private let queue = DispatchQueue(label: "VoiceType.LocalAI", qos: .utility)
    private let processLock = NSLock()
    private let port = 38741
    private var serverProcess: Process?
    private var bootstrapProcesses: [LocalASRModel: Process] = [:]
    private var preparingModels = Set<LocalASRModel>()

    private lazy var supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VoiceType/LocalAI", isDirectory: true)
    }()

    private var venvPython: URL {
        supportDirectory.appendingPathComponent("venv/bin/python")
    }

    func prepareAllInBackground() {
        VoiceTypeLogger.log("localAI.prepareAllInBackground")
        for model in LocalASRModel.allCases {
            prepare(model: model)
        }
    }

    func prepare(model: LocalASRModel) {
        VoiceTypeLogger.log("localAI.prepare.request model=\(model.repoID)")
        prepare(model: model) { _ in }
    }

    func transcribe(audioURL: URL, model: LocalASRModel, language: LanguageOption, completion: @escaping (Result<String, Error>) -> Void) {
        VoiceTypeLogger.log("localAI.transcribe.request model=\(model.repoID) language=\(language.rawValue) audio=\(audioURL.path)")
        prepare(model: model) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                VoiceTypeLogger.error("localAI.prepare.failedForTranscribe model=\(model.repoID)", error: error)
                completion(.failure(error))
            case .success:
                self.startServerIfNeeded()
                self.waitForServer(timeout: 45) { ready in
                    guard ready else {
                        VoiceTypeLogger.error("localAI.server.notReady timeout=45")
                        completion(.failure(NSError.voiceType("Local ASR server did not become ready")))
                        return
                    }
                    self.performTranscription(audioURL: audioURL, model: model, language: language, completion: completion)
                }
            }
        }
    }

    func shutdown() {
        VoiceTypeLogger.log("localAI.shutdown")
        processLock.lock()
        let server = serverProcess
        let bootstraps = Array(bootstrapProcesses.values)
        serverProcess = nil
        bootstrapProcesses.removeAll()
        processLock.unlock()

        server?.terminate()
        for process in bootstraps where process.isRunning {
            process.terminate()
        }
    }

    private func prepare(model: LocalASRModel, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            if self.preparingModels.contains(model) {
                VoiceTypeLogger.log("localAI.prepare.alreadyRunning model=\(model.repoID)")
                self.waitForModel(model, completion: completion)
                return
            }
            self.preparingModels.insert(model)
            self.postStatus(.preparing("Preparing \(model.title)"))
            VoiceTypeLogger.log("localAI.prepare.start model=\(model.repoID) home=\(self.supportDirectory.path)")
            do {
                try FileManager.default.createDirectory(at: self.supportDirectory, withIntermediateDirectories: true)
                guard let bootstrap = self.localAIScript(named: "bootstrap_local_asr.py") else {
                    throw NSError.voiceType("Bundled local ASR bootstrap script is missing")
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [
                    bootstrap.path,
                    "--home", self.supportDirectory.path,
                    "--model", model.repoID
                ]
                process.environment = self.processEnvironment()
                let logURL = self.supportDirectory.appendingPathComponent("bootstrap.log")
                let log = try FileHandle(forWritingTo: self.ensureFile(logURL))
                log.seekToEndOfFile()
                process.standardOutput = log
                process.standardError = log
                VoiceTypeLogger.log("localAI.bootstrap.run model=\(model.repoID) log=\(logURL.path)")
                try process.run()
                self.processLock.lock()
                self.bootstrapProcesses[model] = process
                self.processLock.unlock()
                process.waitUntilExit()
                self.processLock.lock()
                self.bootstrapProcesses[model] = nil
                self.processLock.unlock()
                log.closeFile()
                VoiceTypeLogger.log("localAI.bootstrap.exit model=\(model.repoID) status=\(process.terminationStatus)")
                if process.terminationStatus != 0 {
                    VoiceTypeLogger.error("localAI.bootstrap.failed model=\(model.repoID) status=\(process.terminationStatus) log=\(logURL.path)")
                    throw NSError.voiceType("Bootstrap exited with status \(process.terminationStatus). See \(logURL.path)")
                }
                self.preparingModels.remove(model)
                self.postStatus(.ready("\(model.title) ready"))
                completion(.success(()))
            } catch {
                self.preparingModels.remove(model)
                self.postStatus(.failed(error.localizedDescription))
                VoiceTypeLogger.error("localAI.prepare.failed model=\(model.repoID)", error: error)
                completion(.failure(error))
            }
        }
    }

    private func waitForModel(_ model: LocalASRModel, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.asyncAfter(deadline: .now() + 2) {
            if self.preparingModels.contains(model) {
                VoiceTypeLogger.log("localAI.waitForModel.pending model=\(model.repoID)")
                self.waitForModel(model, completion: completion)
            } else {
                VoiceTypeLogger.log("localAI.waitForModel.ready model=\(model.repoID)")
                completion(.success(()))
            }
        }
    }

    private func startServerIfNeeded() {
        processLock.lock()
        let existingServer = serverProcess
        if let existingServer, !existingServer.isRunning {
            serverProcess = nil
        }
        processLock.unlock()
        if let existingServer, existingServer.isRunning {
            VoiceTypeLogger.log("localAI.server.alreadyRunning pid=\(existingServer.processIdentifier)")
            return
        }
        if isServerHealthyNow() {
            postStatus(.ready("Local ASR server ready"))
            VoiceTypeLogger.log("localAI.server.externalReady port=\(port)")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: venvPython.path),
              let serverScript = localAIScript(named: "stt_server.py") else {
            VoiceTypeLogger.error("localAI.server.cannotStart python=\(venvPython.path) exists=\(FileManager.default.isExecutableFile(atPath: venvPython.path))")
            return
        }

        do {
            let process = Process()
            process.executableURL = venvPython
            process.arguments = [
                serverScript.path,
                "--home", supportDirectory.path,
                "--port", "\(port)"
            ]
            process.environment = processEnvironment()
            let logURL = supportDirectory.appendingPathComponent("server.log")
            let log = try FileHandle(forWritingTo: ensureFile(logURL))
            log.seekToEndOfFile()
            process.standardOutput = log
            process.standardError = log
            VoiceTypeLogger.log("localAI.server.run log=\(logURL.path)")
            try process.run()
            processLock.lock()
            serverProcess = process
            processLock.unlock()
            postStatus(.preparing("Starting local ASR server"))
        } catch {
            postStatus(.failed(error.localizedDescription))
            VoiceTypeLogger.error("localAI.server.start.failed", error: error)
        }
    }

    private func isServerHealthyNow(timeout: TimeInterval = 0.7) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let semaphore = DispatchSemaphore(value: 0)
        var isReady = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                isReady = true
                VoiceTypeLogger.log("localAI.server.healthProbe.ready status=\(http.statusCode)")
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 0.3)
        return isReady
    }

    private func waitForServer(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let started = Date()
        func poll() {
            guard Date().timeIntervalSince(started) < timeout else {
                VoiceTypeLogger.error("localAI.server.poll.timeout")
                completion(false)
                return
            }
            guard let url = URL(string: "http://127.0.0.1:\(port)/health") else {
                completion(false)
                return
            }
            URLSession.shared.dataTask(with: url) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.postStatus(.ready("Local ASR server ready"))
                    VoiceTypeLogger.log("localAI.server.poll.ready status=\(http.statusCode)")
                    completion(true)
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    VoiceTypeLogger.log("localAI.server.poll.wait status=\(status)")
                    self.queue.asyncAfter(deadline: .now() + 1, execute: poll)
                }
            }.resume()
        }
        poll()
    }

    private func performTranscription(audioURL: URL, model: LocalASRModel, language: LanguageOption, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/transcribe") else {
            completion(.failure(NSError.voiceType("Invalid local ASR server URL")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "audio_path": audioURL.path,
            "model": model.repoID,
            "language": language.rawValue
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            VoiceTypeLogger.error("localAI.transcribe.encode.failed", error: error)
            completion(.failure(error))
            return
        }

        VoiceTypeLogger.log("localAI.transcribe.http.request model=\(model.repoID) url=\(url.absoluteString)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                VoiceTypeLogger.error("localAI.transcribe.network.failed", error: error)
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                VoiceTypeLogger.error("localAI.transcribe.http.failed status=\(status) body=\(message.prefix(500))")
                completion(.failure(NSError.voiceType("Local ASR request failed: \(message)")))
                return
            }
            VoiceTypeLogger.log("localAI.transcribe.http.response status=\(http.statusCode) bytes=\(data.count)")
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any],
                      let text = dictionary["text"] as? String else {
                    VoiceTypeLogger.error("localAI.transcribe.extract.failed")
                    completion(.failure(NSError.voiceType("Local ASR response did not contain text")))
                    return
                }
                if let audio = dictionary["audio"] as? [String: Any],
                   let audioData = try? JSONSerialization.data(withJSONObject: audio, options: [.sortedKeys]),
                   let audioJSON = String(data: audioData, encoding: .utf8) {
                    VoiceTypeLogger.log("localAI.transcribe.audio \(audioJSON)")
                }
                VoiceTypeLogger.log("localAI.transcribe.success chars=\(text.count) text=\(text)")
                completion(.success(text))
            } catch {
                VoiceTypeLogger.error("localAI.transcribe.decode.failed", error: error)
                completion(.failure(error))
            }
        }.resume()
    }

    private func localAIScript(named name: String) -> URL? {
        let bundleCandidate = Bundle.main.resourceURL?
            .appendingPathComponent("LocalAI", isDirectory: true)
            .appendingPathComponent(name)
        if let bundleCandidate, FileManager.default.fileExists(atPath: bundleCandidate.path) {
            return bundleCandidate
        }
        let sourceCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/LocalAI", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: sourceCandidate.path) {
            return sourceCandidate
        }
        return nil
    }

    private func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let pathPrefix = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(pathPrefix):\(environment["PATH"] ?? "")"
        environment["VOICE_TYPE_LOCALAI_HOME"] = supportDirectory.path
        environment["HF_HOME"] = supportDirectory.appendingPathComponent("hf-home").path
        environment["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private func ensureFile(_ url: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    private func postStatus(_ status: LocalAIStatus) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voiceTypeLocalAIStatusChanged, object: status)
        }
    }
}
