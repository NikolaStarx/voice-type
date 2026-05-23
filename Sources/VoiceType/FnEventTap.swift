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
        VoiceTypeLogger.log("shortcutTap.start preflight listen=\(CGPreflightListenEventAccess()) shortcut=\(settings.recordingShortcut.logValue)")
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
        VoiceTypeLogger.log("shortcutTap.runningSuppressed shortcut=\(settings.recordingShortcut.logValue)")
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
        VoiceTypeLogger.log("shortcutTap.press shortcut=\(shortcut.logValue) source=\(source) keyCode=\(keyCode) flags=\(flags.rawValue)")
        DispatchQueue.main.async { self.onPress() }
    }

    private func finishShortcut(reason: String) {
        let shortcut = activeShortcut ?? settings.recordingShortcut
        isShortcutDown = false
        activeShortcut = nil
        VoiceTypeLogger.log("shortcutTap.release shortcut=\(shortcut.logValue) reason=\(reason)")
        DispatchQueue.main.async { self.onRelease() }
    }

    private func startFallbackMonitor(reason: String) {
        guard fallbackMonitor == nil else { return }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            self?.handleFallback(event: event)
        }
        postStatus(.runningObserveOnly)
        VoiceTypeLogger.log("shortcutTap.fallback reason=\(reason) shortcut=\(settings.recordingShortcut.logValue)")
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
        keyCode.map { CGKeyCode($0) }
    }

    var isModifierOnly: Bool {
        keyCode == nil
    }

    func matchesModifierKeyEvent(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let modifierKeyCode else { return false }
        if modifierKeyCode == 63 {
            return keyCode == 63 || flags.contains(.maskSecondaryFn)
        }
        return keyCode == modifierKeyCode
    }

    func matchesModifierKeyEvent(keyCode: CGKeyCode, flags: NSEvent.ModifierFlags) -> Bool {
        guard let modifierKeyCode else { return false }
        if modifierKeyCode == 63 {
            return keyCode == 63 || flags.contains(.function)
        }
        return keyCode == modifierKeyCode
    }

    func cgModifiersMatch(_ flags: CGEventFlags) -> Bool {
        flags.intersection(.voiceTypeShortcutRelevant) == requiredCGFlags
    }

    func eventModifiersMatch(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.voiceTypeShortcutRelevant) == requiredEventFlags
    }

    private var requiredCGFlags: CGEventFlags {
        modifiers.cgFlags
    }

    private var requiredEventFlags: NSEvent.ModifierFlags {
        modifiers.eventFlags
    }
}

extension RecordingShortcutModifiers {
    init(cgFlags: CGEventFlags) {
        var result: RecordingShortcutModifiers = []
        if cgFlags.contains(.maskShift) { result.insert(.shift) }
        if cgFlags.contains(.maskControl) { result.insert(.control) }
        if cgFlags.contains(.maskAlternate) { result.insert(.option) }
        if cgFlags.contains(.maskCommand) { result.insert(.command) }
        if cgFlags.contains(.maskSecondaryFn) { result.insert(.function) }
        self = result
    }

    init(eventFlags: NSEvent.ModifierFlags) {
        var result: RecordingShortcutModifiers = []
        if eventFlags.contains(.shift) { result.insert(.shift) }
        if eventFlags.contains(.control) { result.insert(.control) }
        if eventFlags.contains(.option) { result.insert(.option) }
        if eventFlags.contains(.command) { result.insert(.command) }
        if eventFlags.contains(.function) { result.insert(.function) }
        self = result
    }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.command) { flags.insert(.command) }
        if contains(.function) { flags.insert(.function) }
        return flags
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
