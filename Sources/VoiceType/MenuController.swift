import AppKit

final class MenuController: NSObject {
    private let settings = SettingsStore.shared
    private let coordinator: VoiceCoordinator
    private let localAI: LocalAIManager
    private let fnEventTap: FnEventTap
    private let statusItem: NSStatusItem
    private var llmWindow: LLMSettingsWindowController?
    private var sttWindow: STTSettingsWindowController?
    private var diagnosticsWindow: DiagnosticsWindowController?
    private var shortcutRecorderWindow: ShortcutRecorderWindowController?
    private var localStatus: LocalAIStatus = .idle
    private var fnStatus: FnEventTapStatus = .idle

    init(coordinator: VoiceCoordinator, localAI: LocalAIManager, fnEventTap: FnEventTap) {
        self.coordinator = coordinator
        self.localAI = localAI
        self.fnEventTap = fnEventTap
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureStatusIcon()
        rebuildMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .voiceTypeSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(localAIStatusChanged(_:)), name: .voiceTypeLocalAIStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fnStatusChanged(_:)), name: .voiceTypeFnEventTapStatusChanged, object: nil)
    }

    private func configureStatusIcon() {
        guard let button = statusItem.button else {
            VoiceTypeLogger.error("menu.statusIcon.missingButton")
            return
        }
        statusItem.length = 46
        button.image = MenuController.makeStatusIcon()
        button.image?.isTemplate = true
        button.title = "VT"
        button.imagePosition = .imageLeft
        button.contentTintColor = .labelColor
        button.toolTip = "VoiceType: \(settings.recordingShortcut.holdHint)"
        button.setAccessibilityLabel("VoiceType")
        VoiceTypeLogger.log("menu.statusIcon.configured length=\(statusItem.length) hasImage=\(button.image != nil) title=\(button.title)")
    }

    private func rebuildMenu() {
        VoiceTypeLogger.log("menu.rebuild fnStatus=\(fnStatus.title) localStatus=\(localStatus.title)")
        let menu = NSMenu()

        let title = NSMenuItem(title: "VoiceType", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let hint = NSMenuItem(title: settings.recordingShortcut.holdHint, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        menu.addItem(languageMenuItem())
        menu.addItem(recordingShortcutMenuItem())
        menu.addItem(backendMenuItem())
        menu.addItem(inputDeviceMenuItem())
        menu.addItem(localAIMenuItem())
        menu.addItem(llmMenuItem())
        menu.addItem(permissionsMenuItem())
        menu.addItem(diagnosticsMenuItem())
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Cloud STT Settings...", action: #selector(openSTTSettings), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VoiceType", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.target == nil && item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func languageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in LanguageOption.allCases {
            let languageItem = NSMenuItem(title: language.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = language.rawValue
            languageItem.state = settings.language == language ? .on : .off
            submenu.addItem(languageItem)
        }
        item.submenu = submenu
        return item
    }

    private func recordingShortcutMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Record Shortcut", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let current = NSMenuItem(title: "Current: \(settings.recordingShortcut.title)", action: nil, keyEquivalent: "")
        current.isEnabled = false
        submenu.addItem(current)
        submenu.addItem(.separator())

        for preset in RecordingShortcutPreset.allCases {
            let shortcut = preset.shortcut
            let shortcutItem = NSMenuItem(title: preset.menuTitle, action: #selector(selectRecordingShortcut(_:)), keyEquivalent: "")
            shortcutItem.target = self
            shortcutItem.representedObject = preset.rawValue
            shortcutItem.state = settings.recordingShortcut == shortcut ? .on : .off
            submenu.addItem(shortcutItem)
        }

        if !RecordingShortcutPreset.allCases.contains(where: { $0.shortcut == settings.recordingShortcut }) {
            let custom = NSMenuItem(title: "Custom: \(settings.recordingShortcut.title)", action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            submenu.addItem(custom)
        }

        submenu.addItem(.separator())
        let record = NSMenuItem(title: "Record Shortcut...", action: #selector(recordShortcut), keyEquivalent: "")
        record.target = self
        submenu.addItem(record)

        item.submenu = submenu
        return item
    }

    private func diagnosticsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let paste = NSMenuItem(title: "Paste Test Text", action: #selector(pasteTestText), keyEquivalent: "")
        paste.target = self
        submenu.addItem(paste)

        let record = NSMenuItem(title: "Record 2s Test", action: #selector(recordTest), keyEquivalent: "")
        record.target = self
        submenu.addItem(record)
        submenu.addItem(.separator())

        let showDiagnostics = NSMenuItem(title: "Show Recent Diagnostics...", action: #selector(showDiagnostics), keyEquivalent: "")
        showDiagnostics.target = self
        submenu.addItem(showDiagnostics)

        let copyDiagnostics = NSMenuItem(title: "Copy Diagnostics to Clipboard", action: #selector(copyDiagnostics), keyEquivalent: "")
        copyDiagnostics.target = self
        submenu.addItem(copyDiagnostics)
        submenu.addItem(.separator())

        let compact = NSMenuItem(title: "Compact Old Logs Now", action: #selector(compactLog), keyEquivalent: "")
        compact.target = self
        submenu.addItem(compact)

        let clear = NSMenuItem(title: "Clear Log", action: #selector(clearLog), keyEquivalent: "")
        clear.target = self
        submenu.addItem(clear)

        let reveal = NSMenuItem(title: "Reveal Log in Finder", action: #selector(revealLog), keyEquivalent: "")
        reveal.target = self
        submenu.addItem(reveal)

        item.submenu = submenu
        return item
    }

    private func inputDeviceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let systemDefault = NSMenuItem(title: "System Default", action: #selector(selectInputDevice(_:)), keyEquivalent: "")
        systemDefault.target = self
        systemDefault.representedObject = ""
        systemDefault.state = settings.selectedInputDeviceUID.isEmpty ? .on : .off
        submenu.addItem(systemDefault)
        submenu.addItem(.separator())

        let devices = AudioDeviceManager.inputDevices()
        for device in devices {
            let deviceItem = NSMenuItem(title: device.menuTitle, action: #selector(selectInputDevice(_:)), keyEquivalent: "")
            deviceItem.target = self
            deviceItem.representedObject = device.uid
            deviceItem.state = settings.selectedInputDeviceUID == device.uid ? .on : .off
            submenu.addItem(deviceItem)
        }

        if devices.isEmpty {
            let empty = NSMenuItem(title: "No input devices found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }

        submenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Devices", action: #selector(settingsChanged), keyEquivalent: "")
        refresh.target = self
        submenu.addItem(refresh)

        item.submenu = submenu
        return item
    }

    private func backendMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Speech Backend", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for backend in SpeechBackend.allCases {
            let backendItem = NSMenuItem(title: backend.title, action: #selector(selectBackend(_:)), keyEquivalent: "")
            backendItem.target = self
            backendItem.representedObject = backend.rawValue
            backendItem.state = settings.backend == backend ? .on : .off
            submenu.addItem(backendItem)
        }
        submenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Cloud STT Settings...", action: #selector(openSTTSettings), keyEquivalent: "")
        settingsItem.target = self
        submenu.addItem(settingsItem)
        item.submenu = submenu
        return item
    }

    private func permissionsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let fn = NSMenuItem(title: fnStatus.title, action: nil, keyEquivalent: "")
        fn.isEnabled = false
        submenu.addItem(fn)

        let summary = NSMenuItem(title: PermissionsManager.shared.statusSummary(), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        submenu.addItem(summary)
        submenu.addItem(.separator())

        let request = NSMenuItem(title: "Request Permissions Once", action: #selector(requestPermissions), keyEquivalent: "")
        request.target = self
        submenu.addItem(request)

        let retry = NSMenuItem(title: "Restart Shortcut Listener", action: #selector(restartFnListener), keyEquivalent: "")
        retry.target = self
        submenu.addItem(retry)

        let inputMonitoring = NSMenuItem(title: "Open Input Monitoring Settings...", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        inputMonitoring.target = self
        submenu.addItem(inputMonitoring)

        let accessibility = NSMenuItem(title: "Open Accessibility Settings...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessibility.target = self
        submenu.addItem(accessibility)

        item.submenu = submenu
        return item
    }

    private func localAIMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Local AI", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let status = NSMenuItem(title: localStatus.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        submenu.addItem(status)
        submenu.addItem(.separator())

        let autoPrepare = NSMenuItem(title: "Prepare Models Automatically", action: #selector(toggleLocalAutoPrepare), keyEquivalent: "")
        autoPrepare.target = self
        autoPrepare.state = settings.localAutoPrepare ? .on : .off
        submenu.addItem(autoPrepare)

        let prepare = NSMenuItem(title: "Prepare Qwen Models Now", action: #selector(prepareLocalModels), keyEquivalent: "")
        prepare.target = self
        submenu.addItem(prepare)

        item.submenu = submenu
        return item
    }

    private func llmMenuItem() -> NSMenuItem {
        var llm = settings.llm
        let item = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleLLM), keyEquivalent: "")
        enabled.target = self
        enabled.state = llm.enabled ? .on : .off
        submenu.addItem(enabled)

        submenu.addItem(.separator())
        for profile in llm.profiles {
            let profileItem = NSMenuItem(title: profile.name, action: #selector(selectLLMProfile(_:)), keyEquivalent: "")
            profileItem.target = self
            profileItem.representedObject = profile.id
            profileItem.state = profile.id == llm.activeProfileID ? .on : .off
            submenu.addItem(profileItem)
        }

        if llm.profiles.isEmpty {
            llm.profiles = LLMProfile.defaultProfiles
            settings.llm = llm
        }

        submenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openLLMSettings), keyEquivalent: "")
        settingsItem.target = self
        submenu.addItem(settingsItem)

        item.submenu = submenu
        return item
    }

    @objc private func settingsChanged() {
        configureStatusIcon()
        rebuildMenu()
    }

    @objc private func localAIStatusChanged(_ notification: Notification) {
        if let status = notification.object as? LocalAIStatus {
            localStatus = status
            rebuildMenu()
        }
    }

    @objc private func fnStatusChanged(_ notification: Notification) {
        if let status = notification.object as? FnEventTapStatus {
            fnStatus = status
            rebuildMenu()
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = LanguageOption(rawValue: raw) else { return }
        VoiceTypeLogger.log("menu.selectLanguage \(language.rawValue)")
        settings.language = language
    }

    @objc private func selectBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let backend = SpeechBackend(rawValue: raw) else { return }
        VoiceTypeLogger.log("menu.selectBackend \(backend.rawValue)")
        settings.backend = backend
        if let model = backend.localModel {
            localAI.prepare(model: model)
        }
    }

    @objc private func selectRecordingShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = RecordingShortcutPreset(rawValue: raw) else { return }
        VoiceTypeLogger.log("menu.selectRecordingShortcut \(preset.rawValue)")
        settings.recordingShortcut = preset.shortcut
    }

    @objc private func recordShortcut() {
        VoiceTypeLogger.log("menu.recordShortcut")
        fnEventTap.stop()
        let recorder = ShortcutRecorderWindowController(currentShortcut: settings.recordingShortcut)
        recorder.onSave = { [weak self] shortcut in
            self?.settings.recordingShortcut = shortcut
        }
        recorder.onClose = { [weak self, weak recorder] in
            if self?.shortcutRecorderWindow === recorder {
                self?.shortcutRecorderWindow = nil
            }
            self?.fnEventTap.start()
        }
        shortcutRecorderWindow = recorder
        recorder.showWindow(nil)
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        VoiceTypeLogger.log("menu.selectInputDevice uid=\(uid.isEmpty ? "default" : uid)")
        settings.selectedInputDeviceUID = uid
    }

    @objc private func toggleLocalAutoPrepare() {
        settings.localAutoPrepare.toggle()
        VoiceTypeLogger.log("menu.toggleLocalAutoPrepare enabled=\(settings.localAutoPrepare)")
        if settings.localAutoPrepare {
            localAI.prepareAllInBackground()
        }
    }

    @objc private func prepareLocalModels() {
        VoiceTypeLogger.log("menu.prepareLocalModels")
        localAI.prepareAllInBackground()
    }

    @objc private func toggleLLM() {
        var llm = settings.llm
        llm.enabled.toggle()
        VoiceTypeLogger.log("menu.toggleLLM enabled=\(llm.enabled)")
        settings.llm = llm
    }

    @objc private func selectLLMProfile(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String else { return }
        var llm = settings.llm
        llm.activeProfileID = profileID
        VoiceTypeLogger.log("menu.selectLLMProfile id=\(profileID)")
        settings.llm = llm
    }

    @objc private func openLLMSettings() {
        VoiceTypeLogger.log("menu.openLLMSettings")
        if llmWindow == nil {
            llmWindow = LLMSettingsWindowController()
        }
        llmWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSTTSettings() {
        VoiceTypeLogger.log("menu.openSTTSettings")
        if sttWindow == nil {
            sttWindow = STTSettingsWindowController()
        }
        sttWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAccessibilitySettings() {
        PermissionsManager.shared.openAccessibilitySettings()
    }

    @objc private func openInputMonitoringSettings() {
        PermissionsManager.shared.openInputMonitoringSettings()
    }

    @objc private func requestPermissions() {
        VoiceTypeLogger.log("menu.requestPermissions")
        PermissionsManager.shared.requestEventPermissionsNow()
        restartFnListener()
    }

    @objc private func restartFnListener() {
        VoiceTypeLogger.log("menu.restartFnListener")
        fnEventTap.stop()
        fnEventTap.start()
    }

    @objc private func pasteTestText() {
        VoiceTypeLogger.log("menu.pasteTestText")
        coordinator.injectDiagnosticText("VoiceType paste test 中文 English 123")
    }

    @objc private func recordTest() {
        VoiceTypeLogger.log("menu.recordTest.start duration=2.00")
        coordinator.beginHold()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            VoiceTypeLogger.log("menu.recordTest.stop")
            self?.coordinator.endHold()
        }
    }

    @objc private func showDiagnostics() {
        VoiceTypeLogger.log("menu.showDiagnostics")
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindowController()
        }
        diagnosticsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyDiagnostics() {
        VoiceTypeLogger.log("menu.copyDiagnostics")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(VoiceTypeLogger.diagnosticsSnapshot(), forType: .string)
    }

    @objc private func compactLog() {
        VoiceTypeLogger.log("menu.compactLog")
        VoiceTypeLogger.compactOldLogsNow()
    }

    @objc private func clearLog() {
        VoiceTypeLogger.log("menu.clearLog")
        VoiceTypeLogger.clear()
    }

    @objc private func revealLog() {
        VoiceTypeLogger.log("menu.revealLog")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("VoiceType/voice-type.log")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private static func makeStatusIcon() -> NSImage {
        if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "VoiceType") {
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            let configured = symbol.withSymbolConfiguration(configuration) ?? symbol
            configured.isTemplate = true
            return configured
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.7, 0.5]
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1.7
        let totalWidth = CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * gap
        let startX = (size.width - totalWidth) / 2
        for (index, weight) in weights.enumerated() {
            let height = 12 * weight
            let rect = NSRect(
                x: startX + CGFloat(index) * (barWidth + gap),
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
            path.fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
