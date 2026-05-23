import AppKit

final class ShortcutRecorderWindowController: NSWindowController, NSWindowDelegate {
    var onSave: ((RecordingShortcut) -> Void)?
    var onClose: (() -> Void)?

    private let previewLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let currentShortcut: RecordingShortcut
    private var recordedShortcut: RecordingShortcut?
    private var monitors: [Any] = []

    init(currentShortcut: RecordingShortcut) {
        self.currentShortcut = currentShortcut
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Record Shortcut"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self
        configureViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        installMonitors()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        removeMonitors()
        onClose?()
    }

    private func configureViews() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 18, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Press the shortcut you want to hold for dictation.")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "Use at least one modifier, for example Option + Space or Command + Shift + V.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2

        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = 8
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        previewBox.layer?.borderColor = NSColor.separatorColor.cgColor
        previewBox.layer?.borderWidth = 1
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        previewLabel.stringValue = "Current: \(currentShortcut.title)"
        previewLabel.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        previewLabel.alignment = .center
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewLabel)

        messageLabel.stringValue = "Waiting for shortcut..."
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false

        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(saveButton)

        root.addArrangedSubview(title)
        root.addArrangedSubview(subtitle)
        root.addArrangedSubview(previewBox)
        root.addArrangedSubview(messageLabel)
        root.addArrangedSubview(buttonRow)
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            previewBox.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            previewBox.heightAnchor.constraint(equalToConstant: 54),
            previewLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -12),
            previewLabel.centerYAnchor.constraint(equalTo: previewBox.centerYAnchor),

            buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48)
        ])
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            self?.record(event: event)
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private func record(event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                close()
                return nil
            }
            if event.keyCode == 36, recordedShortcut != nil {
                save()
                return nil
            }
            let modifiers = RecordingShortcutModifiers(eventFlags: event.modifierFlags)
            guard !modifiers.isEmpty else {
                showMessage("Add a modifier so normal typing is not hijacked.", isError: true)
                return nil
            }
            let shortcut = RecordingShortcut(
                keyCode: UInt16(event.keyCode),
                keyName: ShortcutKeyName.name(for: event),
                modifiers: modifiers
            )
            setRecorded(shortcut)
            return nil
        case .flagsChanged:
            if recordedShortcut?.keyCode != nil {
                return nil
            }
            let modifiers = RecordingShortcutModifiers(eventFlags: event.modifierFlags)
            guard !modifiers.isEmpty else { return nil }
            let shortcut = RecordingShortcut(
                modifierKeyCode: UInt16(event.keyCode),
                keyName: ShortcutKeyName.modifierOnlyName(keyCode: UInt16(event.keyCode), modifiers: modifiers),
                modifiers: modifiers
            )
            setRecorded(shortcut)
            return nil
        default:
            return event
        }
    }

    private func setRecorded(_ shortcut: RecordingShortcut) {
        recordedShortcut = shortcut
        previewLabel.stringValue = shortcut.title
        saveButton.isEnabled = true
        showMessage("Release the keys, then Save.", isError: false)
        VoiceTypeLogger.log("shortcutRecorder.recorded shortcut=\(shortcut.logValue)")
    }

    private func showMessage(_ message: String, isError: Bool) {
        messageLabel.stringValue = message
        messageLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    @objc private func save() {
        guard let recordedShortcut else { return }
        VoiceTypeLogger.log("shortcutRecorder.save shortcut=\(recordedShortcut.logValue)")
        onSave?(recordedShortcut)
        close()
    }

    @objc private func cancel() {
        VoiceTypeLogger.log("shortcutRecorder.cancel")
        close()
    }
}

private enum ShortcutKeyName {
    static func name(for event: NSEvent) -> String {
        let keyCode = UInt16(event.keyCode)
        if let known = knownKeyNames[keyCode] {
            return known
        }
        let fallback = event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fallback.count == 1 {
            return fallback.uppercased()
        }
        return "Key \(keyCode)"
    }

    static func modifierOnlyName(keyCode: UInt16, modifiers: RecordingShortcutModifiers) -> String {
        if modifiers.titleParts.count > 1 {
            return modifiers.titleParts.joined(separator: " + ")
        }
        if let known = knownModifierNames[keyCode] {
            return known
        }
        return modifiers.titleParts.first ?? "Modifier"
    }

    private static let knownModifierNames: [UInt16: String] = [
        54: "Right Command",
        55: "Command",
        56: "Left Shift",
        58: "Left Option",
        59: "Left Control",
        60: "Right Shift",
        61: "Right Option",
        62: "Right Control",
        63: "Fn / Globe"
    ]

    private static let knownKeyNames: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        71: "Clear",
        76: "Enter",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        114: "Help",
        115: "Home",
        116: "Page Up",
        117: "Forward Delete",
        118: "F4",
        119: "End",
        120: "F2",
        121: "Page Down",
        122: "F1",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow"
    ]
}
