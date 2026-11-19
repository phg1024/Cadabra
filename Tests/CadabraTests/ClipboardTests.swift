import AppKit
import Testing
@testable import Cadabra

@MainActor
struct ClipboardTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("CadabraTests-\(UUID().uuidString)"))

    init() {
        pasteboard.clearContents()
        pasteboard.setString("the user's own", forType: .string)
    }

    func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func putsTheUsersClipboardBack() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("dictated", restoreAfter: 0.05)
        #expect(pasteboard.string(forType: .string) == "dictated")
        await wait(0.2)
        #expect(pasteboard.string(forType: .string) == "the user's own")
    }

    @Test func settlingEarlyRestoresOrKeepsTheDictation() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("dictated", restoreAfter: 5)
        swap.settle(restore: true)   // the text showed up in the field
        #expect(pasteboard.string(forType: .string) == "the user's own")
        swap.put("dictated", restoreAfter: 0.05)
        swap.settle(restore: false)   // it didn't: leave it for ⌘V, even after the delay
        await wait(0.2)
        #expect(pasteboard.string(forType: .string) == "dictated")
    }

    @Test func twoPastesInARowStillPutTheUsersClipboardBack() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("first", restoreAfter: 0.1)
        swap.put("second", restoreAfter: 0.1)
        #expect(pasteboard.string(forType: .string) == "second")
        await wait(0.3)
        #expect(pasteboard.string(forType: .string) == "the user's own")
    }

    @Test func somethingTheUserCopiedMeanwhileStays() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("dictated", restoreAfter: 0.1)
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        await wait(0.3)
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
    }

    @Test func somethingCopiedBetweenTwoPastesIsWhatComesBack() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("first", restoreAfter: 0.1)
        pasteboard.clearContents()
        pasteboard.setString("copied in between", forType: .string)
        swap.put("second", restoreAfter: 0.1)
        await wait(0.3)
        #expect(pasteboard.string(forType: .string) == "copied in between")
    }

    @Test func withoutRestoringTheTextStays() async {
        let swap = ClipboardSwap(pasteboard)
        swap.put("first", restoreAfter: 0.05)
        swap.put("kept", restoreAfter: nil)
        await wait(0.2)
        #expect(pasteboard.string(forType: .string) == "kept")
    }

    @Test func pastedTextIsTransient() {
        ClipboardSwap(pasteboard).put("dictated", restoreAfter: 1)
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
    }
}

@MainActor
struct LiveTyperTests {
    @Test func onlyTheEndThatChangedIsRetyped() {
        #expect(LiveTyper.shared("我们明天开会。", "我们明天开会吧，") == 6)
        #expect(LiveTyper.shared("push上去", "push上去了") == 6)
        #expect(LiveTyper.shared("", "你好") == 0)
        #expect(LiveTyper.shared("👍好", "👍对") == 1)   // emoji counts as one character, like one backspace
    }

    @Test func nothingIsTypedWithoutAFieldToTypeInto() {
        let typer = LiveTyper()
        typer.begin(in: nil)   // our own window in front
        #expect(!typer.isTyping)
        #expect(!typer.show("你好"))
        #expect(typer.typed.isEmpty)
    }
}
