import AppKit
import ApplicationServices

/// The text around the cursor in the field being dictated into, read through Accessibility when the user
/// stops talking. Names and terms in it help twice: the speech decoder favours its uncommon words (a
/// colleague's name in the chat, a variable in the editor) and the correction model sees how they are
/// written. Used for this one dictation and dropped; never stored or logged. Password fields are skipped,
/// and apps that don't expose their text simply give none.
struct FocusContext: Equatable {
    var before: String
    var after: String

    static let beforeLimit = 400, afterLimit = 150

    var isEmpty: Bool { before.isEmpty && after.isEmpty }

    /// Without `typed` (the dictation's own live draft) where it sits, just before the cursor; nil when
    /// nothing else is left.
    func without(_ typed: String) -> FocusContext? {
        var context = self
        if let range = before.range(of: typed, options: .backwards) {
            context.before.removeSubrange(range)
        } else if typed.hasSuffix(before) {
            context.before = ""   // a long draft: all that was kept before the cursor is its end
        }
        return context.isEmpty ? nil : context
    }

    @MainActor
    static func read() -> FocusContext? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
              let element = TextInjector.focusedElement(), !TextInjector.isSecure(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        var caret = text.utf16.count
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
           let range, CFGetTypeID(range) == AXValueGetTypeID() {
            var r = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &r) { caret = r.location }
        }
        let context = around(text, caret: caret)
        return context.isEmpty ? nil : context
    }

    /// The text up to `beforeLimit` characters before the caret (a UTF-16 offset) and `afterLimit` after it.
    static func around(_ text: String, caret: Int) -> FocusContext {
        let utf16 = text.utf16
        let at = utf16.index(utf16.startIndex, offsetBy: min(max(caret, 0), utf16.count))
        let index = String.Index(at, within: text) ?? text.endIndex
        return FocusContext(before: String(text[..<index].suffix(beforeLimit)).trimmingCharacters(in: .whitespacesAndNewlines),
                            after: String(text[index...].prefix(afterLimit)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Words worth favouring while recognizing: names and identifiers rather than everyday English
    /// (Jonathan, useState, kubectl, P2S), nearest the cursor first, at most `limit`.
    func words(limit: Int = 20) -> [String] {
        func candidates(_ s: String) -> [String] { s.ranges(of: #/[A-Za-z][A-Za-z0-9_]{2,}/#).map { String(s[$0]) } }
        var seen = Set<String>()
        let near = candidates(before).reversed() + candidates(after)
        return near.filter { word in
            let inner = word.dropFirst()
            let unusual = inner.contains(where: \.isUppercase) || word.contains(where: { $0.isNumber || $0 == "_" })
                || !Phonetic.isEnglishWord(word)
            return unusual && HotwordDecoder.usable(word) && seen.insert(word.lowercased()).inserted
        }.prefix(limit).map { $0 }
    }

    /// For the correction model: the text with the cursor marked.
    var prompt: String { "\(before)⟨光标⟩\(after)" }
}
