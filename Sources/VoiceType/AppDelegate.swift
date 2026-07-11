import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private var menuController: MenuController!
    private var floatingPanel: FloatingPanelController!
    private var coordinator: VoiceCoordinator!
    private var eventTap: FnEventTap!
    private var localAI: LocalAIManager!
    private var activeRecordingBackend: SpeechBackend?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSSetUncaughtExceptionHandler { exception in
            VoiceTypeLogger.error("uncaughtException name=\(exception.name.rawValue) reason=\(exception.reason ?? "nil") callStack=\(exception.callStackSymbols.joined(separator: " | "))")
        }
        VoiceTypeLogger.log("app.launch pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundlePath) executable=\(Bundle.main.executableURL?.path ?? "nil") version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
        VoiceTypeLogger.compactOldLogsIfNeeded()
        guard continueLaunchingAsSingleInstance() else { return }
        installApplicationMenu()
        PermissionsManager.shared.requestInitialPermissionsOnce()

        floatingPanel = FloatingPanelController()
        localAI = LocalAIManager.shared
        coordinator = VoiceCoordinator(floatingPanel: floatingPanel, localAI: localAI)
        eventTap = FnEventTap(
            onPress: { [weak coordinator] in coordinator?.beginHold() },
            onRelease: { [weak coordinator] in coordinator?.endHold() }
        )
        menuController = MenuController(coordinator: coordinator, localAI: localAI, fnEventTap: eventTap)
        eventTap.start()
        NotificationCenter.default.addObserver(self, selector: #selector(injectionFailed(_:)), name: .voiceTypeInjectionFailed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pipelineStatusChanged(_:)), name: .voiceTypePipelineStatusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordingStateChanged(_:)), name: .voiceTypeRecordingStateChanged, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(runDiagnosticPaste(_:)),
            name: Notification.Name("com.codex.voicetype.diagnosticPaste"),
            object: nil
        )

        if settings.localAutoPrepare {
            localAI.prepareAllInBackground()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VoiceTypeLogger.log("app.willTerminate")
        eventTap?.stop()
        localAI?.shutdown()
    }

    @objc private func injectionFailed(_ notification: Notification) {
        let message = notification.object as? String ?? "Text injection failed"
        VoiceTypeLogger.error("app.injectionFailed message=\(message)")
        floatingPanel.show(text: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.floatingPanel.hide()
        }
    }

    @objc private func pipelineStatusChanged(_ notification: Notification) {
        guard let status = notification.object as? VoiceTypePipelineStatus else { return }
        VoiceTypeLogger.log("app.pipelineStatus \(status.title)")
        if activeRecordingBackend == .appleSpeech, status.isBackgroundProgress {
            VoiceTypeLogger.log("app.pipelineStatus.suppressedForAppleStreaming status=\(status.title)")
            return
        }
        if status == .done {
            floatingPanel.hide()
            return
        }
        floatingPanel.show(text: status.title)
        if status.shouldAutoHide {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.floatingPanel.hide()
            }
        } else if status.isFailure {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.floatingPanel.hide()
            }
        }
    }

    @objc private func recordingStateChanged(_ notification: Notification) {
        guard let state = notification.object as? VoiceTypeRecordingState else { return }
        activeRecordingBackend = state.active ? state.backend : nil
        VoiceTypeLogger.log("app.recordingState active=\(state.active) backend=\(state.backend.rawValue)")
    }

    @objc private func runDiagnosticPaste(_ notification: Notification) {
        let text = notification.userInfo?["text"] as? String ?? "VoiceType diagnostic paste 中文 English 123"
        VoiceTypeLogger.log("app.diagnosticPasteNotification chars=\(text.count)")
        coordinator.injectDiagnosticText(text)
    }

    private func continueLaunchingAsSingleInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleURL = Bundle.main.bundleURL.standardizedFileURL
        let canonicalInstallURL = URL(fileURLWithPath: "/Applications/VoiceType.app", isDirectory: true)
            .standardizedFileURL
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.codex.voicetype"
        let existingApps = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier == bundleIdentifier && app.processIdentifier != currentPID
        }

        guard currentBundleURL.path == canonicalInstallURL.path else {
            if FileManager.default.fileExists(atPath: canonicalInstallURL.path) {
                let opened = NSWorkspace.shared.open(canonicalInstallURL)
                VoiceTypeLogger.error("app.nonCanonicalInstanceExit pid=\(currentPID) bundle=\(currentBundleURL.path) openedCanonical=\(opened)")
            } else if let existing = existingApps.first {
                existing.activate(options: [])
                VoiceTypeLogger.error("app.nonCanonicalInstanceExit pid=\(currentPID) bundle=\(currentBundleURL.path) activatedExistingPID=\(existing.processIdentifier)")
            } else {
                VoiceTypeLogger.warning("app.nonCanonicalInstanceAllowed pid=\(currentPID) bundle=\(currentBundleURL.path) canonicalMissing=true")
                return true
            }
            VoiceTypeLogger.flush()
            NSApp.terminate(nil)
            return false
        }

        guard !existingApps.isEmpty else {
            return true
        }

        for app in existingApps {
            let bundlePath = app.bundleURL?.standardizedFileURL.path ?? "nil"
            VoiceTypeLogger.warning("app.duplicateInstance.terminate pid=\(app.processIdentifier) bundle=\(bundlePath)")
            app.terminate()
        }
        return true
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit VoiceType", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
        VoiceTypeLogger.log("app.mainMenu.installed editActions=true")
    }
}
