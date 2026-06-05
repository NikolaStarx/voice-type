import Foundation

final class LLMRefiner {
    @discardableResult
    func refine(text: String, settings: LLMSettings, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard let url = endpoint(base: settings.apiBaseURL, path: "chat/completions") else {
            VoiceTypeLogger.error("llm.refine.invalidBase base=\(settings.apiBaseURL)")
            completion(.failure(NSError.voiceType("Invalid LLM API Base URL")))
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout(for: settings.activeProfile.reasoningEffort)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let profile = settings.activeProfile
        var payload: [String: Any] = [
            "model": settings.model,
            "temperature": profile.id == "formal" ? 0.2 : 0,
            "messages": [
                ["role": "system", "content": profile.systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        if let reasoningEffort = apiReasoningEffort(for: profile.reasoningEffort) {
            payload["reasoning_effort"] = reasoningEffort
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            VoiceTypeLogger.error("llm.refine.encode.failed", error: error)
            completion(.failure(error))
            return nil
        }

        VoiceTypeLogger.log("llm.refine.request url=\(url.absoluteString) model=\(settings.model) profile=\(profile.name) effort=\(profile.reasoningEffort.rawValue) apiEffort=\(payload["reasoning_effort"] ?? "omitted") chars=\(text.count)")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                VoiceTypeLogger.error("llm.refine.network.failed", error: error)
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status == 400,
                   payload["reasoning_effort"] != nil,
                   Self.looksLikeReasoningParameterFailure(message) {
                    VoiceTypeLogger.warning("llm.refine.reasoningUnsupported.retryWithoutReasoning status=\(status) body=\(message.prefix(500))")
                    self.refineWithoutReasoning(text: text, settings: settings, completion: completion)
                    return
                }
                VoiceTypeLogger.error("llm.refine.http.failed status=\(status) body=\(message.prefix(500))")
                completion(.failure(NSError.voiceType("LLM request failed: \(message)")))
                return
            }
            VoiceTypeLogger.log("llm.refine.response status=\(http.statusCode) bytes=\(data.count)")

            do {
                let object = try JSONSerialization.jsonObject(with: data)
                if let text = Self.extractChatText(from: object) {
                    VoiceTypeLogger.log("llm.refine.extract.success chars=\(text.count) text=\(text)")
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    VoiceTypeLogger.error("llm.refine.extract.failed")
                    completion(.failure(NSError.voiceType("LLM response did not contain text")))
                }
            } catch {
                VoiceTypeLogger.error("llm.refine.decode.failed", error: error)
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }

    private func refineWithoutReasoning(text: String, settings: LLMSettings, completion: @escaping (Result<String, Error>) -> Void) {
        var retrySettings = settings
        let profile = settings.activeProfile
        let retryProfile = LLMProfile(
            id: profile.id,
            name: profile.name,
            systemPrompt: profile.systemPrompt,
            reasoningEffort: profile.reasoningEffort,
            segmentationStrategy: profile.segmentationStrategy,
            pauseThresholdSeconds: profile.pauseThresholdSeconds
        )
        retrySettings.profiles = settings.profiles.map { existing in
            existing.id == profile.id ? retryProfile : existing
        }

        guard let url = endpoint(base: retrySettings.apiBaseURL, path: "chat/completions") else {
            completion(.failure(NSError.voiceType("Invalid LLM API Base URL")))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout(for: retrySettings.activeProfile.reasoningEffort)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !retrySettings.apiKey.isEmpty {
            request.setValue("Bearer \(retrySettings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let retryPayload: [String: Any] = [
            "model": retrySettings.model,
            "temperature": retryProfile.id == "formal" ? 0.2 : 0,
            "messages": [
                ["role": "system", "content": retryProfile.systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: retryPayload, options: [])
        } catch {
            VoiceTypeLogger.error("llm.refine.retry.encode.failed", error: error)
            completion(.failure(error))
            return
        }

        VoiceTypeLogger.log("llm.refine.retry.request url=\(url.absoluteString) model=\(retrySettings.model) profile=\(retryProfile.name) chars=\(text.count)")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                VoiceTypeLogger.error("llm.refine.retry.network.failed", error: error)
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                VoiceTypeLogger.error("llm.refine.retry.http.failed status=\(status) body=\(message.prefix(500))")
                completion(.failure(NSError.voiceType("LLM retry failed: \(message)")))
                return
            }
            VoiceTypeLogger.log("llm.refine.retry.response status=\(http.statusCode) bytes=\(data.count)")
            do {
                let object = try JSONSerialization.jsonObject(with: data)
                if let text = Self.extractChatText(from: object) {
                    VoiceTypeLogger.log("llm.refine.retry.extract.success chars=\(text.count) text=\(text)")
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    VoiceTypeLogger.error("llm.refine.retry.extract.failed")
                    completion(.failure(NSError.voiceType("LLM response did not contain text")))
                }
            } catch {
                VoiceTypeLogger.error("llm.refine.retry.decode.failed", error: error)
                completion(.failure(error))
            }
        }.resume()
    }

    static func extractChatText(from object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let response = dictionary["response"] as? String {
            return response
        }
        if let choices = dictionary["choices"] as? [[String: Any]],
           let first = choices.first {
            if let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
            if let text = first["text"] as? String {
                return text
            }
        }
        return nil
    }

    private func timeout(for effort: ReasoningEffort) -> TimeInterval {
        switch effort {
        case .minimal: return 10
        case .low: return 14
        case .medium: return 24
        case .high: return 40
        }
    }

    private func apiReasoningEffort(for effort: ReasoningEffort) -> String? {
        switch effort {
        case .minimal:
            return "none"
        case .low, .medium, .high:
            return effort.rawValue
        }
    }

    private static func looksLikeReasoningParameterFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("reasoning") || lowercased.contains("reasoning_effort")
    }
}

final class CloudSTTTranscriber {
    func transcribe(audioURL: URL, language: LanguageOption, settings: CloudSTTSettings, completion: @escaping (Result<String, Error>) -> Void) {
        guard settings.isConfigured else {
            VoiceTypeLogger.error("cloudSTT.notConfigured")
            completion(.failure(NSError.voiceType("Cloud STT is not configured")))
            return
        }
        guard let url = endpoint(base: settings.apiBaseURL, path: "audio/transcriptions") else {
            VoiceTypeLogger.error("cloudSTT.invalidBase base=\(settings.apiBaseURL)")
            completion(.failure(NSError.voiceType("Invalid Cloud STT API Base URL")))
            return
        }

        do {
            let audioData = try Data(contentsOf: audioURL)
            let boundary = "VoiceTypeBoundary-\(UUID().uuidString)"
            var body = Data()
            body.appendMultipartField(name: "model", value: settings.model, boundary: boundary)
            body.appendMultipartField(name: "language", value: language.rawValue, boundary: boundary)
            body.appendMultipartFile(name: "file", filename: "speech.wav", mimeType: "audio/wav", data: audioData, boundary: boundary)
            body.appendString("--\(boundary)--\r\n")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 90
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if !settings.apiKey.isEmpty {
                request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = body

            VoiceTypeLogger.log("cloudSTT.request url=\(url.absoluteString) model=\(settings.model) language=\(language.rawValue) audioBytes=\(audioData.count)")
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    VoiceTypeLogger.error("cloudSTT.network.failed", error: error)
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data else {
                    let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    VoiceTypeLogger.error("cloudSTT.http.failed status=\(status) body=\(message.prefix(500))")
                    completion(.failure(NSError.voiceType("Cloud STT request failed: \(message)")))
                    return
                }
                VoiceTypeLogger.log("cloudSTT.response status=\(http.statusCode) bytes=\(data.count)")
                do {
                    let object = try JSONSerialization.jsonObject(with: data)
                    if let dictionary = object as? [String: Any],
                       let text = dictionary["text"] as? String {
                        VoiceTypeLogger.log("cloudSTT.extract.text chars=\(text.count) text=\(text)")
                        completion(.success(text))
                    } else if let dictionary = object as? [String: Any],
                              let text = dictionary["transcript"] as? String {
                        VoiceTypeLogger.log("cloudSTT.extract.transcript chars=\(text.count) text=\(text)")
                        completion(.success(text))
                    } else {
                        VoiceTypeLogger.error("cloudSTT.extract.failed")
                        completion(.failure(NSError.voiceType("Cloud STT response did not contain text")))
                    }
                } catch {
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        VoiceTypeLogger.log("cloudSTT.decode.rawText chars=\(text.count) text=\(text)")
                        completion(.success(text))
                    } else {
                        VoiceTypeLogger.error("cloudSTT.decode.failed", error: error)
                        completion(.failure(error))
                    }
                }
            }.resume()
        } catch {
            VoiceTypeLogger.error("cloudSTT.audioRead.failed path=\(audioURL.path)", error: error)
            completion(.failure(error))
        }
    }
}

func endpoint(base: String, path: String) -> URL? {
    let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasSuffix(path) {
        return URL(string: trimmed)
    }
    return URL(string: "\(trimmed)/\(path)")
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(name: String, filename: String, mimeType: String, data: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
