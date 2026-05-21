import Foundation

final class LLMRefiner {
    @discardableResult
    func refine(text: String, settings: LLMSettings, completion: @escaping (Result<String, Error>) -> Void) -> URLSessionDataTask? {
        guard let url = endpoint(base: settings.apiBaseURL, path: "chat/completions") else {
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
            completion(.failure(error))
            return nil
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                completion(.failure(NSError.voiceType("LLM request failed: \(message)")))
                return
            }

            do {
                let object = try JSONSerialization.jsonObject(with: data)
                if let text = Self.extractChatText(from: object) {
                    completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                } else {
                    completion(.failure(NSError.voiceType("LLM response did not contain text")))
                }
            } catch {
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
            completion(.failure(NSError.voiceType("Cloud STT is not configured")))
            return
        }
        guard let url = endpoint(base: settings.apiBaseURL, path: "audio/transcriptions") else {
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

            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data else {
                    let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                    completion(.failure(NSError.voiceType("Cloud STT request failed: \(message)")))
                    return
                }
                do {
                    let object = try JSONSerialization.jsonObject(with: data)
                    if let dictionary = object as? [String: Any],
                       let text = dictionary["text"] as? String {
                        completion(.success(text))
                    } else if let dictionary = object as? [String: Any],
                              let text = dictionary["transcript"] as? String {
                        completion(.success(text))
                    } else {
                        completion(.failure(NSError.voiceType("Cloud STT response did not contain text")))
                    }
                } catch {
                    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        completion(.success(text))
                    } else {
                        completion(.failure(error))
                    }
                }
            }.resume()
        } catch {
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
