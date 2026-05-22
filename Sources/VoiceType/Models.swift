import Foundation

enum LanguageOption: String, CaseIterable, Codable {
    case english = "en-US"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var title: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        }
    }
}

enum SpeechBackend: String, CaseIterable, Codable {
    case appleSpeech
    case localQwen06
    case localQwen17
    case cloud

    var title: String {
        switch self {
        case .appleSpeech: return "Apple Speech (Streaming)"
        case .localQwen06: return "Local Qwen3-ASR 0.6B"
        case .localQwen17: return "Local Qwen3-ASR 1.7B"
        case .cloud: return "Cloud STT"
        }
    }

    var localModel: LocalASRModel? {
        switch self {
        case .localQwen06: return .qwen06
        case .localQwen17: return .qwen17
        case .appleSpeech, .cloud: return nil
        }
    }
}

enum LocalASRModel: String, CaseIterable, Codable {
    case qwen06
    case qwen17

    var repoID: String {
        switch self {
        case .qwen06: return "mlx-community/Qwen3-ASR-0.6B-4bit"
        case .qwen17: return "mlx-community/Qwen3-ASR-1.7B-4bit"
        }
    }

    var folderName: String {
        repoID.replacingOccurrences(of: "/", with: "__")
    }

    var title: String {
        switch self {
        case .qwen06: return "Qwen3-ASR 0.6B 4-bit"
        case .qwen17: return "Qwen3-ASR 1.7B 4-bit"
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Codable {
    case minimal
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .minimal: return "Minimal / Fast"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

enum RefinementSegmentationStrategy: String, CaseIterable, Codable {
    case smartSentences
    case pauseBatches
    case wholeUtterance

    var title: String {
        switch self {
        case .smartSentences: return "Smart Sentences"
        case .pauseBatches: return "Pause Batches"
        case .wholeUtterance: return "Whole Utterance"
        }
    }

    var description: String {
        switch self {
        case .smartSentences: return "Split transcript by punctuation and safe text boundaries after release."
        case .pauseBatches: return "Send batches when the speaker pauses, without cutting audio."
        case .wholeUtterance: return "Wait until Fn is released, then refine the full transcript."
        }
    }
}

struct LLMProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var systemPrompt: String
    var reasoningEffort: ReasoningEffort
    var segmentationStrategy: RefinementSegmentationStrategy
    var pauseThresholdSeconds: Double

    init(
        id: String,
        name: String,
        systemPrompt: String,
        reasoningEffort: ReasoningEffort,
        segmentationStrategy: RefinementSegmentationStrategy,
        pauseThresholdSeconds: Double
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.reasoningEffort = reasoningEffort
        self.segmentationStrategy = segmentationStrategy
        self.pauseThresholdSeconds = pauseThresholdSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case systemPrompt
        case reasoningEffort
        case segmentationStrategy
        case pauseThresholdSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        reasoningEffort = try container.decode(ReasoningEffort.self, forKey: .reasoningEffort)

        if let strategy = try container.decodeIfPresent(RefinementSegmentationStrategy.self, forKey: .segmentationStrategy) {
            segmentationStrategy = strategy
        } else if id == "formal" {
            segmentationStrategy = .wholeUtterance
        } else if id == "oral" {
            segmentationStrategy = .pauseBatches
        } else {
            segmentationStrategy = .smartSentences
        }

        pauseThresholdSeconds = try container.decodeIfPresent(Double.self, forKey: .pauseThresholdSeconds) ?? 0.85
    }

    static let defaultProfiles: [LLMProfile] = [
        LLMProfile(
            id: "oral",
            name: "Oral",
            systemPrompt: """
You are a conservative speech-recognition correction engine.
Return only the corrected transcript, with no explanations, quotes, markdown, or metadata.
Only fix obvious speech recognition mistakes, including Chinese homophone mistakes and English technical terms that were mistakenly transcribed as Chinese sounds, for example 配森 -> Python, 派森 -> Python, 杰森 -> JSON, 扣得 -> code, 开发 -> dev when context clearly requires it.
Never rewrite, summarize, polish, reorder, normalize style, or remove content that appears correct.
Preserve the speaker's wording, punctuation style, language mix, hesitations, and informality.
If the input already looks correct, return it exactly as-is.
""",
            reasoningEffort: .minimal,
            segmentationStrategy: .pauseBatches,
            pauseThresholdSeconds: 0.85
        ),
        LLMProfile(
            id: "mixed_tech",
            name: "Mixed Tech",
            systemPrompt: """
You correct mixed Chinese-English technical dictation very conservatively.
Return only the final text, no explanations.
Fix clear ASR errors involving programming, product, and AI terms, especially Chinese phonetic substitutions for English words, such as 配森 or 派森 -> Python, 杰森 -> JSON, Java斯科瑞普特 -> JavaScript, open AI -> OpenAI, 麦克斯 -> MLX when context is obvious.
Keep all correct content unchanged. Do not add missing ideas, do not improve style, do not shorten, and do not remove repeated words unless they are plainly duplicated by ASR.
If uncertain, keep the original wording.
""",
            reasoningEffort: .low,
            segmentationStrategy: .pauseBatches,
            pauseThresholdSeconds: 0.65
        ),
        LLMProfile(
            id: "formal",
            name: "Formal",
            systemPrompt: """
You lightly edit dictated text into a formal written style without changing meaning.
Return only the edited text, no explanations.
You may correct obvious ASR errors, punctuation, grammar, spacing, and capitalization, and you may make the sentence more polished when the intent is clear.
Do not add facts, do not remove substantive content, do not change technical terms, and do not change the speaker's meaning.
If the text is already formal and correct, return it as-is.
""",
            reasoningEffort: .high,
            segmentationStrategy: .wholeUtterance,
            pauseThresholdSeconds: 1.2
        )
    ]
}

struct LLMSettings: Codable, Equatable {
    var enabled: Bool
    var apiBaseURL: String
    var apiKey: String
    var model: String
    var activeProfileID: String
    var profiles: [LLMProfile]

    static let defaults = LLMSettings(
        enabled: false,
        apiBaseURL: "http://localhost:11434/v1",
        apiKey: "",
        model: "qwen2.5:7b",
        activeProfileID: "oral",
        profiles: LLMProfile.defaultProfiles
    )

    var activeProfile: LLMProfile {
        profiles.first { $0.id == activeProfileID } ?? profiles.first ?? LLMProfile.defaultProfiles[0]
    }
}

struct CloudSTTSettings: Codable, Equatable {
    var apiBaseURL: String
    var apiKey: String
    var model: String

    static let defaults = CloudSTTSettings(
        apiBaseURL: "https://api.openai.com/v1",
        apiKey: "",
        model: "gpt-4o-transcribe"
    )

    var isConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum LocalAIStatus: Equatable {
    case idle
    case preparing(String)
    case ready(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Local AI: Idle"
        case .preparing(let message): return "Local AI: \(message)"
        case .ready(let message): return "Local AI: \(message)"
        case .failed(let message): return "Local AI Error: \(message)"
        }
    }
}

enum FnEventTapStatus: Equatable {
    case idle
    case runningSuppressed
    case runningObserveOnly
    case permissionMissing(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Fn Listener: Idle"
        case .runningSuppressed: return "Fn Listener: Active"
        case .runningObserveOnly: return "Fn Listener: Fallback Mode"
        case .permissionMissing(let message): return "Fn Listener: Permission Needed (\(message))"
        case .failed(let message): return "Fn Listener: Failed (\(message))"
        }
    }
}

enum VoiceTypePipelineStatus: Equatable {
    case queued
    case transcribing(String)
    case refining
    case inserting
    case done
    case failed(String)

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .transcribing(let message): return message
        case .refining: return "Refining..."
        case .inserting: return "Inserting..."
        case .done: return "Done"
        case .failed(let message): return message
        }
    }

    var shouldAutoHide: Bool {
        switch self {
        case .done: return true
        case .queued, .transcribing, .refining, .inserting, .failed: return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var isBackgroundProgress: Bool {
        switch self {
        case .queued, .transcribing, .refining, .inserting, .done:
            return true
        case .failed:
            return false
        }
    }
}

struct VoiceTypeRecordingState {
    var active: Bool
    var backend: SpeechBackend
}

extension Notification.Name {
    static let voiceTypeSettingsChanged = Notification.Name("VoiceTypeSettingsChanged")
    static let voiceTypeLocalAIStatusChanged = Notification.Name("VoiceTypeLocalAIStatusChanged")
    static let voiceTypeFnEventTapStatusChanged = Notification.Name("VoiceTypeFnEventTapStatusChanged")
    static let voiceTypeInjectionFailed = Notification.Name("VoiceTypeInjectionFailed")
    static let voiceTypePipelineStatusChanged = Notification.Name("VoiceTypePipelineStatusChanged")
    static let voiceTypeRecordingStateChanged = Notification.Name("VoiceTypeRecordingStateChanged")
}
