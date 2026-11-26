import Testing
@testable import Cadabra

struct FocusContextTests {
    @Test func theLiveDraftIsNotContext() {
        let draft = "mususe home link里面是什么东西？"
        #expect(FocusContext(before: draft, after: "").without(draft) == nil)
        #expect(FocusContext(before: "你看看HomeLink。" + draft, after: "")
            .without(draft) == FocusContext(before: "你看看HomeLink。", after: ""))
        #expect(FocusContext(before: "link里面是什么东西？", after: "后面").without(draft) == FocusContext(before: "", after: "后面"))
    }

    @Test func splitsAtTheCaret() {
        let text = "Hi Jonathan, 你好"
        let context = FocusContext.around(text, caret: 13)   // after the comma and space
        #expect(context.before == "Hi Jonathan,")
        #expect(context.after == "你好")
        #expect(FocusContext.around(text, caret: 999).after.isEmpty)
        #expect(FocusContext.around(text, caret: -3).before.isEmpty)
    }

    @Test func caretCountsUTF16LikeAccessibility() {
        let text = "👍ok"   // the emoji is two UTF-16 units
        #expect(FocusContext.around(text, caret: 2) == FocusContext(before: "👍", after: "ok"))
    }

    @Test func keepsOnlyTheTextNearTheCaret() {
        let text = String(repeating: "a", count: 1000) + "|" + String(repeating: "b", count: 1000)
        let context = FocusContext.around(text, caret: 1000)
        #expect(context.before.count == FocusContext.beforeLimit)
        #expect(context.after.count == FocusContext.afterLimit)
    }

    @Test func wordsAreNamesAndIdentifiersNearestFirst() {
        let context = FocusContext(before: "Please ask Jonathan about the useState hook in the P2S file", after: "and kubectl logs")
        let words = context.words()
        #expect(words.contains("useState"))
        #expect(words.contains("P2S"))
        #expect(words.contains("kubectl"))
        #expect(!words.contains("Please"))
        #expect(!words.contains("about"))
        #expect(!words.contains("file"))
        #expect(words.firstIndex(of: "P2S")! < words.firstIndex(of: "useState")!)
    }
}
