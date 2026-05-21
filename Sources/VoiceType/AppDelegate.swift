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
}
