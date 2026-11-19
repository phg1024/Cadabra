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

    /// Whether `text` is now in the focused field: nil when the app doesn't expose its text.
    @MainActor
    static func landed(_ text: String) -> Bool? {
        guard let element = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value = value as? String else { return nil }
        return value.contains(text)
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
