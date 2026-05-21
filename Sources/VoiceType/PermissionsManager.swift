import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech

final class PermissionsManager {
    static let shared = PermissionsManager()

    private let settings = SettingsStore.shared

    func requestInitialPermissionsOnce() {
        VoiceTypeLogger.log("permissions.startupPreflight \(statusSummary())")
        requestSpeechIfNeeded()
        requestMicrophoneIfNeeded()
    }

    var needsSetup: Bool {
        let canInject = AXIsProcessTrusted() || CGPreflightPostEventAccess()
        return !CGPreflightListenEventAccess() ||
        !canInject ||
        AVCaptureDevice.authorizationStatus(for: .audio) != .authorized ||
        SFSpeechRecognizer.authorizationStatus() != .authorized
    }

    func requestEventPermissionsNow() {
        VoiceTypeLogger.log("permissions.requestEventPermissionsNow.before \(statusSummary())")
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        settings.didRequestAccessibility = true
        settings.didRequestListenEvents = true
        settings.didRequestPostEvents = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            VoiceTypeLogger.log("permissions.requestEventPermissionsNow.after \(self.statusSummary())")
        }
    }

    func openAccessibilitySettings() {
        VoiceTypeLogger.log("permissions.openAccessibilitySettings")
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        VoiceTypeLogger.log("permissions.openInputMonitoringSettings")
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func statusSummary() -> String {
        let listen = CGPreflightListenEventAccess() ? "Input Monitoring OK" : "Input Monitoring missing"
        let post = CGPreflightPostEventAccess() ? "Paste Events OK" : "Paste Events missing"
        let ax = AXIsProcessTrusted() ? "Accessibility OK" : "Accessibility missing"
        let mic = AVCaptureDevice.authorizationStatus(for: .audio).title
        let speech = SFSpeechRecognizer.authorizationStatus().title
        return "\(listen), \(post), \(ax), Mic \(mic), Speech \(speech)"
    }

    private func requestSpeechIfNeeded() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    private func requestMicrophoneIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func openSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension AVAuthorizationStatus {
    var title: String {
        switch self {
        case .authorized: return "OK"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }
}

private extension SFSpeechRecognizerAuthorizationStatus {
    var title: String {
        switch self {
        case .authorized: return "OK"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }
}
