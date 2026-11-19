import AppKit
import ApplicationServices
import Carbon

/// Puts text at the cursor of whatever app has focus: clipboard + a synthetic ⌘V,
/// then (optionally) puts the previous clipboard back.
enum TextInjector {
    /// Tags our synthetic key events so the hotkey monitor ignores them.
    static let eventMarker: Int64 = 0x4D_5769_7370   // "MWisp"

    /// Where the text should go: the app and field that had focus when the user finished speaking.
    struct Target {
        let pid: pid_t
        let element: AXUIElement?

        /// Nil when our own app is in front (the menu's button), where there is nothing to compare.
        @MainActor static func current() -> Target? {
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
            return Target(pid: app.processIdentifier, element: focusedElement())
        }

        /// Still in front, and (when the app tells) the same field.
        @MainActor var isStillFocused: Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            guard let element, let now = focusedElement() else { return true }
            return CFEqual(element, now)
        }
    }

    /// Why a paste was not made; the text is on the clipboard instead.
    enum Refusal { case noAccess, focusMoved, secureField }

    /// Pastes unless focus moved away from `target` meanwhile or a password field has it; returns why not.
    /// The clipboard goes back to the user's after `settle(restore:)` or a few seconds.
    @MainActor
    static func paste(_ text: String, restoreClipboard: Bool, into target: Target?) -> Refusal? {
        guard AXIsProcessTrusted() else { return .noAccess }
        if let target, !target.isStillFocused { return .focusMoved }
        if IsSecureEventInputEnabled() || focusedElement().map(isSecure) == true { return .secureField }
        ClipboardSwap.general.put(text, restoreAfter: restoreClipboard ? 3 : nil)
        postCommandV()
        return nil
    }

    /// The selected text in the app in front: through Accessibility, or where the app doesn't say, by
    /// copying it (⌘C) and putting the clipboard back. Empty when nothing is selected.
    @MainActor
    static func selection() async -> String {
        if let element = focusedElement(), !isSecure(element) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
               let text = value as? String {
                return text
            }
        }
        return await ClipboardSwap.general.copySelection() ?? ""
    }

    /// Where the text is going on screen (AppKit coordinates): the line with the caret, or failing that a
    /// field small enough to stand for it (not a whole editor). Nil when the app doesn't say.
    @MainActor
    static func caretRect() -> NSRect? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
              let element = focusedElement() else { return nil }
        var rect: CGRect?
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let range, CFGetTypeID(range) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &r) {
                // An empty range often has no bounds: take the character before the caret.
                var probe = r.length > 0 ? r : CFRange(location: max(r.location - 1, 0), length: 1)
                if let value = AXValueCreate(.cfRange, &probe) {
                    var bounds: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &bounds) == .success,
                       let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() {
                        var b = CGRect.zero
                        if AXValueGetValue(bounds as! AXValue, .cgRect, &b), b.height > 0 { rect = b }
                    }
                }
            }
        }
        if rect == nil {
            var position: CFTypeRef?, size: CFTypeRef?
            var p = CGPoint.zero, s = CGSize.zero
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
               AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
               let position, let size, AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
               s.height > 0, s.height <= 240 {
                rect = CGRect(origin: p, size: s)
            }
        }
        // Accessibility counts from the top of the main screen; AppKit from the bottom.
        guard let rect, let main = NSScreen.screens.first else { return nil }
        let flipped = NSRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        return NSScreen.screens.contains { $0.frame.intersects(flipped) } ? flipped : nil
    }

    /// Whether `text` is now in the focused field: nil when the app doesn't expose its text.
    @MainActor
    static func landed(_ text: String) -> Bool? {
        guard let element = focusedElement(), let value = value(of: element) else { return nil }
        return value.contains(text)
    }

    static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    @MainActor
    static func copy(_ text: String) {
        ClipboardSwap.general.put(text, restoreAfter: nil)
    }

    private static func postCommandV() { postCommand(9) }

    /// Backspace `count` times, with no modifier (⌥⌫ would take a whole word), marked as ours.
    static func postBackspaces(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down) else { continue }
                event.flags = CGEventFlags(rawValue: 0)
                event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// ⌘ + a key, marked as ours. 9 is V, 8 is C.
    static func postCommand(_ key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = .maskCommand   // explicit, so a still-held dictation key doesn't turn this into ⌥⌘V
            event.setIntegerValueField(.eventSourceUserData, value: eventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Types the words recognized so far into the field while the user talks, and keeps them up to date as
/// recognition changes its mind: deletes back to where the old and the new text part, and pastes the
/// rest (pasting, unlike typing, gets past an input method). Gives up for good as soon as the field it
/// started in loses focus or a password field has it; nothing is ever deleted anywhere else.
@MainActor
final class LiveTyper {
    private(set) var typed = ""
    private var target: TextInjector.Target?
    private(set) var stopped = true

    /// A recording started in `target` (nil: our own window is in front, so nothing is typed).
    func begin(in target: TextInjector.Target?) {
        typed = ""
        self.target = target
        stopped = target == nil || !AXIsProcessTrusted()
    }

    var isTyping: Bool { !stopped }

    /// Shows `text` in the field; false when it can't (any more).
    @discardableResult
    func show(_ text: String) -> Bool {
        guard !stopped else { return false }
        guard stillInField(), !IsSecureEventInputEnabled(),
              TextInjector.focusedElement().map(TextInjector.isSecure) != true else {
            stopped = true
            return false
        }
        replace(with: text)
        return true
    }

    /// The same app in front and, as far as can be told, the same field. Electron apps (Slack, Claude)
    /// hand out a new element for the focused field every time, so there the field counts as the same
    /// while it still holds what was typed.
    private func stillInField() -> Bool {
        guard let target, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { return false }
        guard let original = target.element, let now = TextInjector.focusedElement() else { return true }
        if CFEqual(original, now) { return true }
        guard let value = TextInjector.value(of: now) else { return true }
        return typed.isEmpty || value.contains(typed)
    }

    /// Turns what was typed into `text`, if the field still has focus. The clipboard comes back as after a paste.
    @discardableResult
    func finish(with text: String, restoreClipboard: Bool) -> Bool {
        defer { end() }
        guard !stopped, stillInField() else { return false }
        replace(with: text, restoreAfter: restoreClipboard ? 3 : nil)
        return true
    }

    /// Takes out what was typed (a cancelled or empty dictation), if the field still has focus.
    func clear() {
        if !stopped, stillInField() { replace(with: "") }
        end()
    }

    func end() {
        target = nil
        typed = ""
        stopped = true
    }

    private func replace(with text: String, restoreAfter: TimeInterval? = 5) {
        let common = zip(typed, text).prefix { $0 == $1 }.count
        TextInjector.postBackspaces(typed.count - common)
        let rest = String(text.dropFirst(common))
        if !rest.isEmpty {
            ClipboardSwap.general.put(rest, restoreAfter: restoreAfter)
            TextInjector.postCommand(9)
        }
        typed = text
    }

    /// The part two texts share at the start, in characters: what needn't be retyped.
    static func shared(_ a: String, _ b: String) -> Int { zip(a, b).prefix { $0 == $1 }.count }
}

/// Puts dictated text on the clipboard for a paste and, if asked, the user's own clipboard back after it.
@MainActor
final class ClipboardSwap {
    static let general = ClipboardSwap(.general)

    private let pasteboard: NSPasteboard
    /// The user's clipboard while putting it back is pending. A second paste in that time keeps this
    /// one rather than saving the first dictation as the user's.
    private var saved: [NSPasteboardItem]?
    /// The clipboard's change count right after our last write.
    private var ours = 0
    private var generation = 0

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// Settles a pending restore early: `restore` puts the user's clipboard back now (the text arrived);
    /// otherwise the dictation stays on the clipboard for ⌘V (it didn't).
    func settle(restore: Bool) {
        guard let saved else { return }
        generation += 1
        self.saved = nil
        guard restore, pasteboard.changeCount == ours else { return }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    func put(_ text: String, restoreAfter delay: TimeInterval?) {
        generation += 1
        if delay == nil {
            saved = nil
        } else if saved == nil || pasteboard.changeCount != ours {
            saved = snapshot()
        }
        // Like clearContents(), but what comes next stays on this Mac: Universal Clipboard does not
        // hand it to the user's iPhone or other Macs.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        if delay != nil {
            // Clipboard managers skip transient items, so the dictated text doesn't pile up there.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        ours = pasteboard.changeCount
        guard let delay else { return }
        let this = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard this == generation, let saved else { return }   // a later paste puts it back
            self.saved = nil
            guard pasteboard.changeCount == ours else { return }   // the user copied something meanwhile
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    /// Copies the selection in the app in front with ⌘C and puts the clipboard back. Nil when nothing
    /// was copied (no selection, or an app that doesn't copy).
    func copySelection() async -> String? {
        let saved = snapshot(), before = pasteboard.changeCount
        generation += 1   // a pending restore would put back something older
        TextInjector.postCommand(8)
        for _ in 0..<15 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before else { return nil }
        let text = pasteboard.string(forType: .string)
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        return text
    }

    private func snapshot() -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
