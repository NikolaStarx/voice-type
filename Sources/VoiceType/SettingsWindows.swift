import AppKit

final class LLMSettingsWindowController: NSWindowController {
    private let store = SettingsStore.shared
    private var settings = SettingsStore.shared.llm
    private var selectedProfileIndex = 0

    private let enabledButton = NSButton(checkboxWithTitle: "Enable LLM refinement", target: nil, action: nil)
    private let profilePopup = NSPopUpButton()
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let deleteButton = NSButton(title: "-", target: nil, action: nil)
    private let baseField = NSTextField()
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let profileNameField = NSTextField()
    private let reasoningPopup = NSPopUpButton()
    private let promptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LLM Refinement Settings"
        window.center()
        super.init(window: window)
        configure()
        loadSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        enabledButton.target = self
        enabledButton.action = #selector(markDirty)

        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addProfile)
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteProfile)

        let profileRow = NSStackView(views: [
            label("Profile"),
            profilePopup,
            addButton,
            deleteButton
        ])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 8
        profilePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        deleteButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        root.addArrangedSubview(enabledButton)
        root.addArrangedSubview(profileRow)
        root.addArrangedSubview(formRow("API Base URL", baseField))
        root.addArrangedSubview(formRow("API Key", keyField))
        root.addArrangedSubview(formRow("Model", modelField))
        root.addArrangedSubview(formRow("Profile Name", profileNameField))

        reasoningPopup.addItems(withTitles: ReasoningEffort.allCases.map(\.title))
        root.addArrangedSubview(formRow("Reasoning", reasoningPopup))

        let promptLabel = label("System Prompt")
        root.addArrangedSubview(promptLabel)

        promptView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        promptView.isRichText = false
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = promptView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 230).isActive = true
        root.addArrangedSubview(scroll)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let testButton = NSButton(title: "Test", target: self, action: #selector(test))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [statusLabel, testButton, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func loadSettings() {
        settings = store.llm
        selectedProfileIndex = max(0, settings.profiles.firstIndex { $0.id == settings.activeProfileID } ?? 0)
        enabledButton.state = settings.enabled ? .on : .off
        baseField.stringValue = settings.apiBaseURL
        keyField.stringValue = settings.apiKey
        modelField.stringValue = settings.model
        reloadProfilePopup()
        loadSelectedProfile()
    }

    private func reloadProfilePopup() {
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: settings.profiles.map(\.name))
        if selectedProfileIndex < settings.profiles.count {
            profilePopup.selectItem(at: selectedProfileIndex)
        }
        deleteButton.isEnabled = settings.profiles.count > 1
    }

    private func loadSelectedProfile() {
        guard selectedProfileIndex < settings.profiles.count else { return }
        let profile = settings.profiles[selectedProfileIndex]
        profileNameField.stringValue = profile.name
        promptView.string = profile.systemPrompt
        reasoningPopup.selectItem(at: ReasoningEffort.allCases.firstIndex(of: profile.reasoningEffort) ?? 0)
    }

    private func captureSelectedProfile() {
        guard selectedProfileIndex < settings.profiles.count else { return }
        var profile = settings.profiles[selectedProfileIndex]
        let name = profileNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = name.isEmpty ? "Untitled" : name
        profile.systemPrompt = promptView.string
        profile.reasoningEffort = ReasoningEffort.allCases[max(0, reasoningPopup.indexOfSelectedItem)]
        settings.profiles[selectedProfileIndex] = profile
    }

    @objc private func profileChanged() {
        captureSelectedProfile()
        selectedProfileIndex = profilePopup.indexOfSelectedItem
        settings.activeProfileID = settings.profiles[selectedProfileIndex].id
        loadSelectedProfile()
    }

    @objc private func addProfile() {
        captureSelectedProfile()
        let profile = LLMProfile(
            id: UUID().uuidString,
            name: "Custom",
            systemPrompt: LLMProfile.defaultProfiles[0].systemPrompt,
            reasoningEffort: .low
        )
        settings.profiles.append(profile)
        selectedProfileIndex = settings.profiles.count - 1
        settings.activeProfileID = profile.id
        reloadProfilePopup()
        loadSelectedProfile()
    }

    @objc private func deleteProfile() {
        guard settings.profiles.count > 1 else { return }
        settings.profiles.remove(at: selectedProfileIndex)
        selectedProfileIndex = min(selectedProfileIndex, settings.profiles.count - 1)
        settings.activeProfileID = settings.profiles[selectedProfileIndex].id
        reloadProfilePopup()
        loadSelectedProfile()
    }

    @objc private func markDirty() {
        statusLabel.stringValue = ""
    }

    @objc private func save() {
        captureSelectedProfile()
        settings.enabled = enabledButton.state == .on
        settings.apiBaseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.apiKey = keyField.stringValue
        settings.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.activeProfileID = settings.profiles[selectedProfileIndex].id
        store.llm = settings
        reloadProfilePopup()
        statusLabel.stringValue = "Saved"
    }

    @objc private func test() {
        captureSelectedProfile()
        var testSettings = settings
        testSettings.enabled = true
        testSettings.apiBaseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        testSettings.apiKey = keyField.stringValue
        testSettings.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        testSettings.activeProfileID = settings.profiles[selectedProfileIndex].id

        statusLabel.stringValue = "Testing..."
        LLMRefiner().refine(text: "我在配森里面解析杰森。", settings: testSettings) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self?.statusLabel.stringValue = "Result: \(text)"
                case .failure(let error):
                    self?.statusLabel.stringValue = "Test failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

final class STTSettingsWindowController: NSWindowController {
    private let store = SettingsStore.shared
    private let backendPopup = NSPopUpButton()
    private let baseField = NSTextField()
    private let keyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Speech Backend Settings"
        window.center()
        super.init(window: window)
        configure()
        loadSettings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        guard let contentView = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        backendPopup.addItems(withTitles: SpeechBackend.allCases.map(\.title))
        root.addArrangedSubview(formRow("Backend", backendPopup))
        root.addArrangedSubview(formRow("API Base URL", baseField))
        root.addArrangedSubview(formRow("API Key", keyField))
        root.addArrangedSubview(formRow("Model", modelField))

        statusLabel.textColor = .secondaryLabelColor
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let footer = NSStackView(views: [statusLabel, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func loadSettings() {
        let cloud = store.cloudSTT
        backendPopup.selectItem(at: SpeechBackend.allCases.firstIndex(of: store.backend) ?? 0)
        baseField.stringValue = cloud.apiBaseURL
        keyField.stringValue = cloud.apiKey
        modelField.stringValue = cloud.model
    }

    @objc private func save() {
        let selectedBackend = SpeechBackend.allCases[max(0, backendPopup.indexOfSelectedItem)]
        store.backend = selectedBackend
        store.cloudSTT = CloudSTTSettings(
            apiBaseURL: baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: keyField.stringValue,
            model: modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let model = selectedBackend.localModel {
            LocalAIManager.shared.prepare(model: model)
        }
        statusLabel.stringValue = "Saved"
    }
}

private func label(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.widthAnchor.constraint(equalToConstant: 110).isActive = true
    return label
}

private func formRow(_ title: String, _ control: NSView) -> NSStackView {
    let row = NSStackView(views: [label(title), control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    control.translatesAutoresizingMaskIntoConstraints = false
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return row
}
