import AppKit
import CoreGraphics

final class FnEventTap {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var isFnDown = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        guard eventTap == nil else { return }
        VoiceTypeLogger.log("fnTap.start preflight listen=\(CGPreflightListenEventAccess())")
        guard CGPreflightListenEventAccess() else {
            startFallbackMonitor(reason: "Input Monitoring")
            postStatus(.permissionMissing("Input Monitoring"))
            retryAfterPermissionIfNeeded()
            return
        }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: FnEventTap.callback,
            userInfo: refcon
        )

        guard let eventTap else {
            startFallbackMonitor(reason: "Event tap unavailable")
            postStatus(.failed("Event tap unavailable"))
            VoiceTypeLogger.error("fnTap.create.failed")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        postStatus(.runningSuppressed)
        VoiceTypeLogger.log("fnTap.runningSuppressed")
    }

    func stop() {
        VoiceTypeLogger.log("fnTap.stop")
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
        postStatus(.idle)
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            VoiceTypeLogger.log("fnTap.reenabled type=\(type.rawValue)")
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let fnDown = flags.contains(.maskSecondaryFn)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let looksLikeFn = fnDown != isFnDown || keyCode == 63

        guard looksLikeFn else {
            return Unmanaged.passUnretained(event)
        }

        if fnDown && !isFnDown {
            isFnDown = true
            VoiceTypeLogger.log("fnTap.press keyCode=\(keyCode) flags=\(flags.rawValue)")
            DispatchQueue.main.async { self.onPress() }
        } else if !fnDown && isFnDown {
            isFnDown = false
            VoiceTypeLogger.log("fnTap.release keyCode=\(keyCode) flags=\(flags.rawValue)")
            DispatchQueue.main.async { self.onRelease() }
        }

        return nil
    }

    private func startFallbackMonitor(reason: String) {
        guard fallbackMonitor == nil else { return }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFallback(event: event)
        }
        postStatus(.runningObserveOnly)
        VoiceTypeLogger.log("fnTap.fallback reason=\(reason)")
        NSLog("VoiceType Fn listener fallback mode: \(reason)")
    }

    private func handleFallback(event: NSEvent) {
        let fnDown = event.modifierFlags.contains(.function)
        let looksLikeFn = fnDown != isFnDown || event.keyCode == 63
        guard looksLikeFn else { return }
        if fnDown && !isFnDown {
            isFnDown = true
            VoiceTypeLogger.log("fnTap.fallback.press keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
            DispatchQueue.main.async { self.onPress() }
        } else if !fnDown && isFnDown {
            isFnDown = false
            VoiceTypeLogger.log("fnTap.fallback.release keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
            DispatchQueue.main.async { self.onRelease() }
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
                VoiceTypeLogger.log("fnTap.retry.permissionDetected")
                self.stop()
                self.start()
            } else {
                VoiceTypeLogger.log("fnTap.retry.waiting attemptsRemaining=\(attemptsRemaining)")
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
