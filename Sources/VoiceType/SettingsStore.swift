import Foundation

final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Key {
        static let language = "language"
        static let backend = "speechBackend"
        static let recordingShortcut = "recordingShortcut"
        static let llm = "llmSettings"
        static let cloudSTT = "cloudSTTSettings"
        static let localAutoPrepare = "localAutoPrepare"
        static let selectedInputDeviceUID = "selectedInputDeviceUID"
        static let didRequestAccessibility = "didRequestAccessibility"
        static let didRequestListenEvents = "didRequestListenEvents"
        static let didRequestPostEvents = "didRequestPostEvents"
    }

    var language: LanguageOption {
        get {
            guard let raw = defaults.string(forKey: Key.language),
                  let value = LanguageOption(rawValue: raw) else {
                return .simplifiedChinese
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.language)
            notify()
        }
    }

    var backend: SpeechBackend {
        get {
            guard let raw = defaults.string(forKey: Key.backend),
                  let value = SpeechBackend(rawValue: raw) else {
                return .appleSpeech
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.backend)
            notify()
        }
    }

    var recordingShortcut: RecordingShortcut {
        get {
            if let data = defaults.data(forKey: Key.recordingShortcut),
               let shortcut = try? decoder.decode(RecordingShortcut.self, from: data) {
                return shortcut
            }
            if let raw = defaults.string(forKey: Key.recordingShortcut),
               let preset = RecordingShortcutPreset(rawValue: raw) {
                let migrated = preset.shortcut
                if let data = try? encoder.encode(migrated) {
                    defaults.set(data, forKey: Key.recordingShortcut)
                }
                return migrated
            }
            return RecordingShortcutPreset.optionSpace.shortcut
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: Key.recordingShortcut)
            }
            notify()
        }
    }

    var llm: LLMSettings {
        get {
            guard let data = defaults.data(forKey: Key.llm),
                  var settings = try? decoder.decode(LLMSettings.self, from: data) else {
                return .defaults
            }
            let existingIDs = Set(settings.profiles.map(\.id))
            for profile in LLMProfile.defaultProfiles where !existingIDs.contains(profile.id) {
                settings.profiles.append(profile)
            }
            if !settings.profiles.contains(where: { $0.id == settings.activeProfileID }) {
                settings.activeProfileID = settings.profiles.first?.id ?? "oral"
            }
            return settings
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: Key.llm)
            }
            notify()
        }
    }

    var cloudSTT: CloudSTTSettings {
        get {
            guard let data = defaults.data(forKey: Key.cloudSTT),
                  let settings = try? decoder.decode(CloudSTTSettings.self, from: data) else {
                return .defaults
            }
            return settings
        }
        set {
            if let data = try? encoder.encode(newValue) {
                defaults.set(data, forKey: Key.cloudSTT)
            }
            notify()
        }
    }

    var localAutoPrepare: Bool {
        get {
            if defaults.object(forKey: Key.localAutoPrepare) == nil {
                return true
            }
            return defaults.bool(forKey: Key.localAutoPrepare)
        }
        set {
            defaults.set(newValue, forKey: Key.localAutoPrepare)
            notify()
        }
    }

    var selectedInputDeviceUID: String {
        get { defaults.string(forKey: Key.selectedInputDeviceUID) ?? "" }
        set {
            defaults.set(newValue, forKey: Key.selectedInputDeviceUID)
            notify()
        }
    }

    var didRequestAccessibility: Bool {
        get { defaults.bool(forKey: Key.didRequestAccessibility) }
        set { defaults.set(newValue, forKey: Key.didRequestAccessibility) }
    }

    var didRequestListenEvents: Bool {
        get { defaults.bool(forKey: Key.didRequestListenEvents) }
        set { defaults.set(newValue, forKey: Key.didRequestListenEvents) }
    }

    var didRequestPostEvents: Bool {
        get { defaults.bool(forKey: Key.didRequestPostEvents) }
        set { defaults.set(newValue, forKey: Key.didRequestPostEvents) }
    }

    private func notify() {
        NotificationCenter.default.post(name: .voiceTypeSettingsChanged, object: self)
    }
}
