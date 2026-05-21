import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore.shared
    private var menuController: MenuController!
    private var floatingPanel: FloatingPanelController!
    private var coordinator: VoiceCoordinator!
    private var eventTap: FnEventTap!
    private var localAI: LocalAIManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        VoiceTypeLogger.log("app.launch pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundlePath) executable=\(Bundle.main.executableURL?.path ?? "nil") version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
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
        eventTap?.stop()
        localAI?.shutdown()
    }

    @objc private func injectionFailed(_ notification: Notification) {
        let message = notification.object as? String ?? "Text injection failed"
        floatingPanel.show(text: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.floatingPanel.hide()
        }
    }

    @objc private func runDiagnosticPaste(_ notification: Notification) {
        let text = notification.userInfo?["text"] as? String ?? "VoiceType diagnostic paste 中文 English 123"
        VoiceTypeLogger.log("app.diagnosticPasteNotification chars=\(text.count)")
        coordinator.injectDiagnosticText(text)
    }
}
