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
    private let segmentationPopup = NSPopUpButton()
    private let pauseThresholdField = NSTextField()
    private let promptView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
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

        segmentationPopup.addItems(withTitles: RefinementSegmentationStrategy.allCases.map(\.title))
        segmentationPopup.target = self
        segmentationPopup.action = #selector(segmentationChanged)
        root.addArrangedSubview(formRow("Segmentation", segmentationPopup))

        pauseThresholdField.placeholderString = "0.85"
        pauseThresholdField.formatter = decimalFormatter()
        root.addArrangedSubview(formRow("Pause Seconds", pauseThresholdField))

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
        baseField.stringValue = profile.apiBaseURL ?? settings.apiBaseURL
        keyField.stringValue = profile.apiKey ?? settings.apiKey
        modelField.stringValue = profile.model ?? settings.model
        profileNameField.stringValue = profile.name
        promptView.string = profile.systemPrompt
        reasoningPopup.selectItem(at: ReasoningEffort.allCases.firstIndex(of: profile.reasoningEffort) ?? 0)
        segmentationPopup.selectItem(at: RefinementSegmentationStrategy.allCases.firstIndex(of: profile.segmentationStrategy) ?? 0)
        pauseThresholdField.stringValue = String(format: "%.2f", profile.pauseThresholdSeconds)
        statusLabel.stringValue = "API settings for \(profile.name)"
        segmentationChanged()
    }

    private func captureSelectedProfile() {
        guard selectedProfileIndex < settings.profiles.count else { return }
        var profile = settings.profiles[selectedProfileIndex]
        profile.apiBaseURL = baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.apiKey = keyField.stringValue
        profile.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = profileNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.name = name.isEmpty ? "Untitled" : name
        profile.systemPrompt = promptView.string
        profile.reasoningEffort = ReasoningEffort.allCases[max(0, reasoningPopup.indexOfSelectedItem)]
        profile.segmentationStrategy = RefinementSegmentationStrategy.allCases[max(0, segmentationPopup.indexOfSelectedItem)]
        profile.pauseThresholdSeconds = max(0.2, min(5.0, pauseThresholdField.doubleValue))
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
        let sourceProfile = settings.profiles[selectedProfileIndex]
        let profile = LLMProfile(
            id: UUID().uuidString,
            name: "Custom",
            apiBaseURL: sourceProfile.apiBaseURL,
            apiKey: sourceProfile.apiKey,
            model: sourceProfile.model,
            systemPrompt: LLMProfile.defaultProfiles[0].systemPrompt,
            reasoningEffort: .low,
            segmentationStrategy: .smartSentences,
            pauseThresholdSeconds: 0.85
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

    @objc private func segmentationChanged() {
        let strategy = RefinementSegmentationStrategy.allCases[max(0, segmentationPopup.indexOfSelectedItem)]
        pauseThresholdField.isEnabled = strategy == .pauseBatches
        pauseThresholdField.alphaValue = strategy == .pauseBatches ? 1.0 : 0.55
    }

    @objc private func save() {
        captureSelectedProfile()
        settings.enabled = enabledButton.state == .on
        settings.activeProfileID = settings.profiles[selectedProfileIndex].id
        store.llm = settings
        reloadProfilePopup()
        statusLabel.stringValue = "Saved"
    }

    @objc private func test() {
        captureSelectedProfile()
        var testSettings = settings
        testSettings.enabled = true
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

final class DiagnosticsWindowController: NSWindowController {
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoiceType Recent Diagnostics"
        window.center()
        super.init(window: window)
        configure()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        refresh()
        super.showWindow(sender)
    }

    private func configure() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        root.addArrangedSubview(scroll)

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        let copyButton = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        let revealButton = NSButton(title: "Reveal Log", target: self, action: #selector(revealLog))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [statusLabel, refreshButton, copyButton, revealButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])
    }

    private func refresh() {
        let snapshot = VoiceTypeLogger.diagnosticsSnapshot()
        textView.string = snapshot
        statusLabel.stringValue = "Updated \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))"
        if !snapshot.isEmpty {
            textView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func refreshClicked() {
        VoiceTypeLogger.log("diagnosticsWindow.refresh")
        refresh()
    }

    @objc private func copyDiagnostics() {
        VoiceTypeLogger.log("diagnosticsWindow.copyDiagnostics")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(VoiceTypeLogger.diagnosticsSnapshot(), forType: .string)
        statusLabel.stringValue = "Copied diagnostics"
        refresh()
    }

    @objc private func revealLog() {
        VoiceTypeLogger.log("diagnosticsWindow.revealLog")
        NSWorkspace.shared.activateFileViewerSelecting([VoiceTypeLogger.logFileURL])
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

private func decimalFormatter() -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0.2
    formatter.maximum = 5
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter
}
