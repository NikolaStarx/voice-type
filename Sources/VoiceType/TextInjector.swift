import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

final class TextInjector {
    func inject(text: String, completion: @escaping (Bool) -> Void) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let axTrusted = AXIsProcessTrusted()
        let postEvents = CGPreflightPostEventAccess()
        VoiceTypeLogger.log("textInjector.inject chars=\(text.count) axTrusted=\(axTrusted) postEvents=\(postEvents) frontmost=\(frontmost?.localizedName ?? "nil") bundle=\(frontmost?.bundleIdentifier ?? "nil") text=\(text)")
        if AccessibilityTextInjector.inject(text: text) {
            VoiceTypeLogger.log("textInjector.ax.success")
            completion(true)
            return
        }
        VoiceTypeLogger.warning("textInjector.ax.unavailableOrFailed")

        guard axTrusted || postEvents else {
            VoiceTypeLogger.error("textInjector.eventInjectionAccess.missing axTrusted=\(axTrusted) postEvents=\(postEvents)")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            VoiceTypeLogger.warning("textInjector.permissionFallback.copiedToClipboard chars=\(text.count)")
            NotificationCenter.default.post(
                name: .voiceTypeInjectionFailed,
                object: "Text injection needs Accessibility or Paste Events permission. Text copied to clipboard."
            )
            completion(false)
            return
        }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let originalSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let shouldSwitch = originalSource.map { InputSourceHelper.isCJK($0) } ?? false
        let asciiSource = shouldSwitch ? InputSourceHelper.preferredASCIISource() : nil

        DispatchQueue.main.async {
            if let asciiSource {
                VoiceTypeLogger.log("textInjector.switchToASCII")
                TISSelectInputSource(asciiSource)
            }

            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            VoiceTypeLogger.log("textInjector.pasteboard.set changeCount=\(pasteboard.changeCount)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                VoiceTypeLogger.log("textInjector.postPasteShortcut")
                Self.postPasteShortcut()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                    snapshot.restore(to: pasteboard)
                    if shouldSwitch, let originalSource {
                        VoiceTypeLogger.log("textInjector.restoreInputSource")
                        TISSelectInputSource(originalSource)
                    }
                    VoiceTypeLogger.log("textInjector.complete restoredClipboard=true")
                    completion(true)
                }
            }
        }
    }

    private static func postPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

private enum AccessibilityTextInjector {
    static func inject(text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            VoiceTypeLogger.error("axInjector.notTrusted")
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: AnyObject?
        let focusedError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedError == .success,
              let focusedElement = focusedObject.map({ $0 as! AXUIElement }) else {
            VoiceTypeLogger.error("axInjector.noFocusedElement error=\(focusedError.rawValue)")
            return false
        }
        VoiceTypeLogger.log("axInjector.focusedElement.ok")

        if setSelectedText(text, element: focusedElement) {
            return true
        }
        return spliceIntoValue(text, element: focusedElement)
    }

    private static func setSelectedText(_ text: String, element: AXUIElement) -> Bool {
        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if error == .success {
            VoiceTypeLogger.log("axInjector.selectedText.success")
            return true
        }
        VoiceTypeLogger.warning("axInjector.selectedText.failed error=\(error.rawValue)")
        return false
    }

    private static func spliceIntoValue(_ text: String, element: AXUIElement) -> Bool {
        var valueObject: AnyObject?
        let valueError = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        )
        guard valueError == .success,
              let current = valueObject as? String else {
            VoiceTypeLogger.warning("axInjector.value.read.failed error=\(valueError.rawValue) valueType=\(String(describing: valueObject.map { type(of: $0) }))")
            return false
        }

        let range = selectedRange(in: element) ?? CFRange(location: current.count, length: 0)
        guard range.location >= 0, range.location <= current.count else {
            VoiceTypeLogger.error("axInjector.range.invalid location=\(range.location) length=\(range.length) current=\(current.count)")
            return false
        }

        let safeLength = max(0, min(range.length, current.count - range.location))
        let start = current.index(current.startIndex, offsetBy: range.location)
        let end = current.index(start, offsetBy: safeLength)
        let next = String(current[..<start]) + text + String(current[end...])
        let setError = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            next as CFTypeRef
        )
        guard setError == .success else {
            VoiceTypeLogger.error("axInjector.value.set.failed error=\(setError.rawValue)")
            return false
        }

        setSelectedRange(CFRange(location: range.location + text.count, length: 0), element: element)
        VoiceTypeLogger.log("axInjector.value.splice.success oldChars=\(current.count) newChars=\(next.count)")
        return true
    }

    private static func selectedRange(in element: AXUIElement) -> CFRange? {
        var rangeObject: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeObject
        )
        guard error == .success,
              let axValue = rangeObject,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            VoiceTypeLogger.warning("axInjector.range.read.failed error=\(error.rawValue)")
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue((axValue as! AXValue), .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func setSelectedRange(_ range: CFRange, element: AXUIElement) {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        if error == .success {
            VoiceTypeLogger.log("axInjector.range.set success")
        } else {
            VoiceTypeLogger.warning("axInjector.range.set failed error=\(error.rawValue)")
        }
    }
}

private struct PasteboardSnapshot {
    struct Item {
        var values: [(NSPasteboard.PasteboardType, Data)]
    }

    var items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
    }
}

private enum InputSourceHelper {
    static func preferredASCIISource() -> TISInputSource? {
        let preferredIDs = [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.US",
            "com.apple.keylayout.British"
        ]
        let sources = allInputSources()
        for id in preferredIDs {
            if let source = sources.first(where: { sourceID($0) == id }) {
                return source
            }
        }
        return sources.first { source in
            guard let id = sourceID(source) else { return false }
            return id.contains("keylayout") && !isCJK(source)
        }
    }

    static func isCJK(_ source: TISInputSource) -> Bool {
        if let languages = property(source, kTISPropertyInputSourceLanguages) as? [String] {
            if languages.contains(where: { language in
                language.hasPrefix("zh") || language.hasPrefix("ja") || language.hasPrefix("ko")
            }) {
                return true
            }
        }
        guard let id = sourceID(source)?.lowercased() else { return false }
        let markers = [
            "scim", "tcim", "pinyin", "shuangpin", "wubi", "zhuyin",
            "chinese", "kotoeri", "japanese", "korean", "hangul"
        ]
        return markers.contains { id.contains($0) }
    }

    private static func allInputSources() -> [TISInputSource] {
        guard let unmanaged = TISCreateInputSourceList(nil, false) else { return [] }
        let array = unmanaged.takeRetainedValue() as NSArray
        return array.map { $0 as! TISInputSource }
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        property(source, kTISPropertyInputSourceID) as? String
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> Any? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }
}
