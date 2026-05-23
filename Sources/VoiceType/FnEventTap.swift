import AppKit
import CoreGraphics

final class FnEventTap {
    private let settings = SettingsStore.shared
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var isShortcutDown = false
    private var activeShortcut: RecordingShortcut?

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard eventTap == nil else { return }
        VoiceTypeLogger.log("shortcutTap.start preflight listen=\(CGPreflightListenEventAccess()) shortcut=\(settings.recordingShortcut.rawValue)")
        guard CGPreflightListenEventAccess() else {
            startFallbackMonitor(reason: "Input Monitoring")
            postStatus(.permissionMissing("Input Monitoring"))
            retryAfterPermissionIfNeeded()
            return
        }

        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: FnEventTap.callback,
            userInfo: refcon
        )

        guard let eventTap else {
            startFallbackMonitor(reason: "Event tap unavailable")
            postStatus(.failed("Event tap unavailable"))
            VoiceTypeLogger.error("shortcutTap.create.failed")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        postStatus(.runningSuppressed)
        VoiceTypeLogger.log("shortcutTap.runningSuppressed shortcut=\(settings.recordingShortcut.rawValue)")
    }

    func stop() {
        VoiceTypeLogger.log("shortcutTap.stop")
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
        if isShortcutDown {
            finishShortcut(reason: "listenerStopped")
        }
        postStatus(.idle)
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            VoiceTypeLogger.log("shortcutTap.reenabled type=\(type.rawValue)")
            return Unmanaged.passUnretained(event)
        }

        let shortcut = settings.recordingShortcut
        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event: event, shortcut: shortcut)
        case .keyDown:
            return handleKey(event: event, shortcut: shortcut, keyDown: true)
        case .keyUp:
            return handleKey(event: event, shortcut: shortcut, keyDown: false)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(event: CGEvent, shortcut: RecordingShortcut) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if shortcut.isModifierOnly {
            guard shortcut.matchesModifierKeyEvent(keyCode: keyCode, flags: flags) || activeShortcut == shortcut else {
                return Unmanaged.passUnretained(event)
            }
            if shortcut.cgModifiersMatch(flags), !isShortcutDown {
                beginShortcut(shortcut, keyCode: keyCode, flags: flags, source: "flagsChanged")
            } else if isShortcutDown, activeShortcut == shortcut, !shortcut.cgModifiersMatch(flags) {
                finishShortcut(reason: "flagsChanged")
            }
            return nil
        }

        if isShortcutDown, activeShortcut == shortcut, !shortcut.cgModifiersMatch(flags) {
            finishShortcut(reason: "modifierReleased")
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKey(event: CGEvent, shortcut: RecordingShortcut, keyDown: Bool) -> Unmanaged<CGEvent>? {
        guard let triggerKeyCode = shortcut.triggerKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == triggerKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if keyDown {
            if isShortcutDown, activeShortcut == shortcut {
                return nil
            }
            guard shortcut.cgModifiersMatch(flags) else {
                return Unmanaged.passUnretained(event)
            }
            beginShortcut(shortcut, keyCode: keyCode, flags: flags, source: "keyDown")
            return nil
        }

        if isShortcutDown, activeShortcut == shortcut {
            finishShortcut(reason: "keyUp")
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func beginShortcut(_ shortcut: RecordingShortcut, keyCode: CGKeyCode, flags: CGEventFlags, source: String) {
        isShortcutDown = true
        activeShortcut = shortcut
        VoiceTypeLogger.log("shortcutTap.press shortcut=\(shortcut.rawValue) source=\(source) keyCode=\(keyCode) flags=\(flags.rawValue)")
        DispatchQueue.main.async { self.onPress() }
    }

    private func finishShortcut(reason: String) {
        let shortcut = activeShortcut ?? settings.recordingShortcut
        isShortcutDown = false
        activeShortcut = nil
        VoiceTypeLogger.log("shortcutTap.release shortcut=\(shortcut.rawValue) reason=\(reason)")
        DispatchQueue.main.async { self.onRelease() }
    }

    private func startFallbackMonitor(reason: String) {
        guard fallbackMonitor == nil else { return }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handleFallback(event: event)
        }
        postStatus(.runningObserveOnly)
        VoiceTypeLogger.log("shortcutTap.fallback reason=\(reason) shortcut=\(settings.recordingShortcut.rawValue)")
        NSLog("VoiceType shortcut listener fallback mode: \(reason)")
    }

    private func handleFallback(event: NSEvent) {
        let shortcut = settings.recordingShortcut
        switch event.type {
        case .flagsChanged:
            handleFallbackFlagsChanged(event: event, shortcut: shortcut)
        case .keyDown:
            handleFallbackKey(event: event, shortcut: shortcut, keyDown: true)
        case .keyUp:
            handleFallbackKey(event: event, shortcut: shortcut, keyDown: false)
        default:
            return
        }
    }

    private func handleFallbackFlagsChanged(event: NSEvent, shortcut: RecordingShortcut) {
        if shortcut.isModifierOnly {
            guard shortcut.matchesModifierKeyEvent(keyCode: CGKeyCode(event.keyCode), flags: event.modifierFlags) || activeShortcut == shortcut else {
                return
            }
            if shortcut.eventModifiersMatch(event.modifierFlags), !isShortcutDown {
                beginShortcut(shortcut, keyCode: CGKeyCode(event.keyCode), flags: [], source: "fallbackFlagsChanged")
            } else if isShortcutDown, activeShortcut == shortcut, !shortcut.eventModifiersMatch(event.modifierFlags) {
                finishShortcut(reason: "fallbackFlagsChanged")
            }
            return
        }

        if isShortcutDown, activeShortcut == shortcut, !shortcut.eventModifiersMatch(event.modifierFlags) {
            finishShortcut(reason: "fallbackModifierReleased")
        }
    }

    private func handleFallbackKey(event: NSEvent, shortcut: RecordingShortcut, keyDown: Bool) {
        guard let triggerKeyCode = shortcut.triggerKeyCode,
              CGKeyCode(event.keyCode) == triggerKeyCode else {
            return
        }

        if keyDown {
            guard !isShortcutDown else { return }
            guard shortcut.eventModifiersMatch(event.modifierFlags) else { return }
            beginShortcut(shortcut, keyCode: CGKeyCode(event.keyCode), flags: [], source: "fallbackKeyDown")
        } else if isShortcutDown, activeShortcut == shortcut {
            finishShortcut(reason: "fallbackKeyUp")
        }
    }

    private func postStatus(_ status: FnEventTapStatus) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .voiceTypeFnEventTapStatusChanged, object: status)
        }
    }

    private func retryAfterPermissionIfNeeded(attemptsRemaining: Int = 30) {
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.eventTap == nil else { return }
            if CGPreflightListenEventAccess() {
                VoiceTypeLogger.log("shortcutTap.retry.permissionDetected")
                self.stop()
                self.start()
            } else {
                VoiceTypeLogger.log("shortcutTap.retry.waiting attemptsRemaining=\(attemptsRemaining)")
                self.retryAfterPermissionIfNeeded(attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<FnEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return manager.handle(event: event, type: type)
    }
}

private extension RecordingShortcut {
    var triggerKeyCode: CGKeyCode? {
        switch self {
        case .optionSpace, .controlOptionSpace:
            return 49
        case .rightOption, .fn:
            return nil
        }
    }

    var isModifierOnly: Bool {
        switch self {
        case .rightOption, .fn:
            return true
        case .optionSpace, .controlOptionSpace:
            return false
        }
    }

    func matchesModifierKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch self {
        case .rightOption:
            return keyCode == 61
        case .fn:
            return keyCode == 63 || flags.contains(.maskSecondaryFn)
        case .optionSpace, .controlOptionSpace:
            return false
        }
    }

    func matchesModifierKeyEvent(keyCode: CGKeyCode, flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption:
            return keyCode == 61
        case .fn:
            return keyCode == 63 || flags.contains(.function)
        case .optionSpace, .controlOptionSpace:
            return false
        }
    }

    func cgModifiersMatch(_ flags: CGEventFlags) -> Bool {
        flags.intersection(.voiceTypeShortcutRelevant) == requiredCGFlags
    }

    func eventModifiersMatch(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.voiceTypeShortcutRelevant) == requiredEventFlags
    }

    private var requiredCGFlags: CGEventFlags {
        switch self {
        case .optionSpace, .rightOption:
            return [.maskAlternate]
        case .controlOptionSpace:
            return [.maskControl, .maskAlternate]
        case .fn:
            return [.maskSecondaryFn]
        }
    }

    private var requiredEventFlags: NSEvent.ModifierFlags {
        switch self {
        case .optionSpace, .rightOption:
            return [.option]
        case .controlOptionSpace:
            return [.control, .option]
        case .fn:
            return [.function]
        }
    }
}

private extension CGEventFlags {
    static let voiceTypeShortcutRelevant: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskControl,
        .maskAlternate,
        .maskSecondaryFn
    ]
}

private extension NSEvent.ModifierFlags {
    static let voiceTypeShortcutRelevant: NSEvent.ModifierFlags = [
        .command,
        .shift,
        .control,
        .option,
        .function
    ]
}
