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
        for model in LocalASRModel.allCases {
            prepare(model: model)
        }
    }

    func prepare(model: LocalASRModel) {
        prepare(model: model) { _ in }
    }

    func transcribe(audioURL: URL, model: LocalASRModel, language: LanguageOption, completion: @escaping (Result<String, Error>) -> Void) {
        prepare(model: model) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.startServerIfNeeded()
                self.waitForServer(timeout: 45) { ready in
                    guard ready else {
                        completion(.failure(NSError.voiceType("Local ASR server did not become ready")))
                        return
                    }
                    self.performTranscription(audioURL: audioURL, model: model, language: language, completion: completion)
                }
            }
        }
    }

    func shutdown() {
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
                self.waitForModel(model, completion: completion)
                return
            }
            self.preparingModels.insert(model)
            self.postStatus(.preparing("Preparing \(model.title)"))
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
                try process.run()
                self.processLock.lock()
                self.bootstrapProcesses[model] = process
                self.processLock.unlock()
                process.waitUntilExit()
                self.processLock.lock()
                self.bootstrapProcesses[model] = nil
                self.processLock.unlock()
                log.closeFile()
                if process.terminationStatus != 0 {
                    throw NSError.voiceType("Bootstrap exited with status \(process.terminationStatus). See \(logURL.path)")
                }
                self.preparingModels.remove(model)
                self.postStatus(.ready("\(model.title) ready"))
                completion(.success(()))
            } catch {
                self.preparingModels.remove(model)
                self.postStatus(.failed(error.localizedDescription))
                completion(.failure(error))
            }
        }
    }

    private func waitForModel(_ model: LocalASRModel, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.asyncAfter(deadline: .now() + 2) {
            if self.preparingModels.contains(model) {
                self.waitForModel(model, completion: completion)
            } else {
                completion(.success(()))
            }
        }
    }

    private func startServerIfNeeded() {
        processLock.lock()
        let existingServer = serverProcess
        processLock.unlock()
        if let existingServer, existingServer.isRunning {
            return
        }
        guard FileManager.default.isExecutableFile(atPath: venvPython.path),
              let serverScript = localAIScript(named: "stt_server.py") else {
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
            try process.run()
            processLock.lock()
            serverProcess = process
            processLock.unlock()
            postStatus(.preparing("Starting local ASR server"))
        } catch {
            postStatus(.failed(error.localizedDescription))
        }
    }

    private func waitForServer(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let started = Date()
        func poll() {
            guard Date().timeIntervalSince(started) < timeout else {
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
                    completion(true)
                } else {
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
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                completion(.failure(NSError.voiceType("Local ASR request failed: \(message)")))
                return
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any],
                      let text = dictionary["text"] as? String else {
                    completion(.failure(NSError.voiceType("Local ASR response did not contain text")))
                    return
                }
                completion(.success(text))
            } catch {
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
