import Foundation

final class LLMRefiner {
    @discardableResult
    func refine(text: String, settings: LLMSettings, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard let url = endpoint(base: settings.apiBaseURL, path: "chat/completions") else {
            VoiceTypeLogger.log("llm.refine.invalidBase base=\(settings.apiBaseURL)")
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
        let payload: [String: Any] = [
            "model": settings.model,
            "temperature": profile.id == "formal" ? 0.2 : 0,
            "reasoning_effort": profile.reasoningEffort.rawValue,
            "messages": [
                ["role": "system", "content": profile.systemPrompt],
                ["role": "user", "content": text]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            VoiceTypeLogger.log("llm.refine.encode.failed error=\(error.localizedDescription)")
            completion(.failure(error))
            return nil
        }

        VoiceTypeLogger.log("llm.refine.request url=\(url.absoluteString) model=\(settings.model) profile=\(profile.name) effort=\(profile.reasoningEffort.rawValue) chars=\(text.count)")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                VoiceTypeLogger.log("llm.refine.network.failed error=\(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                VoiceTypeLogger.log("llm.refine.http.failed status=\(status) body=\(message.prefix(500))")
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
                    VoiceTypeLogger.log("llm.refine.extract.failed")
                    completion(.failure(NSError.voiceType("LLM response did not contain text")))
                }
            } catch {
                VoiceTypeLogger.log("llm.refine.decode.failed error=\(error.localizedDescription)")
                completion(.failure(error))
            }
        }
        task.resume()
        return task
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
}

final class CloudSTTTranscriber {
    func transcribe(audioURL: URL, language: LanguageOption, settings: CloudSTTSettings, completion: @escaping (Result<String, Error>) -> Void) {
        guard settings.isConfigured else {
            VoiceTypeLogger.log("cloudSTT.notConfigured")
            completion(.failure(NSError.voiceType("Cloud STT is not configured")))
            return
        }
        guard let url = endpoint(base: settings.apiBaseURL, path: "audio/transcriptions") else {
            VoiceTypeLogger.log("cloudSTT.invalidBase base=\(settings.apiBaseURL)")
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
                    VoiceTypeLogger.log("cloudSTT.network.failed error=\(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data else {
                    let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    VoiceTypeLogger.log("cloudSTT.http.failed status=\(status) body=\(message.prefix(500))")
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
                        VoiceTypeLogger.log("cloudSTT.extract.failed")
                        completion(.failure(NSError.voiceType("Cloud STT response did not contain text")))
                    }
                } catch {
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        VoiceTypeLogger.log("cloudSTT.decode.rawText chars=\(text.count) text=\(text)")
                        completion(.success(text))
                    } else {
                        VoiceTypeLogger.log("cloudSTT.decode.failed error=\(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }.resume()
        } catch {
            VoiceTypeLogger.log("cloudSTT.audioRead.failed path=\(audioURL.path) error=\(error.localizedDescription)")
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
