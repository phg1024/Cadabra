import Foundation
import Testing
@testable import Cadabra

struct LearnedFixesTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("learned-\(UUID().uuidString).json")

    func fix(_ heard: String, _ meant: String, count: Int = LearnedFixes.confirmAt) -> LearnedFix {
        LearnedFix(heard: heard, meant: meant, count: count, lastSeen: Date())
    }

    @Test func learningTheSameFixAgainConfirmsIt() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "试试Jaba吧", edited: "试试Java吧")
        #expect(learned.fixes.map(\.count) == [1])
        #expect(learned.apply("再说一次Jaba") == "再说一次Jaba")   // not confirmed yet
        learned.learn(typed: "Jaba好用", edited: "Java好用")
        #expect(learned.fixes.map(\.count) == [2])
        #expect(learned.apply("再说一次Jaba") == "再说一次Java")
    }

    @Test func aFixMadeInHistoryIsConfirmedAtOnce() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "用不许", edited: "用push", weight: LearnedFixes.confirmAt)
        #expect(learned.fixes.first?.confirmed == true)
    }

    @Test func changingYourMindDropsTheOppositeFix() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "问杰森一下", edited: "问JSON一下")
        learned.learn(typed: "问JSON一下", edited: "问杰森一下")
        #expect(learned.fixes.map { "\($0.heard) → \($0.meant)" } == ["JSON → 杰森"])
    }

    @Test func rewordingIsNotLearned() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "我们用电脑来做", edited: "我们用手机来做")
        learned.learn(typed: "OK", edited: "Sure")
        learned.learn(typed: "the engine is slow", edited: "the model is slow")
        #expect(learned.fixes.isEmpty)
        learned.learn(typed: "问派森吧", edited: "问Python吧")
        #expect(learned.fixes.map(\.meant) == ["Python"])
    }

    @Test func aPlainEnglishWordIsOnlyAHint() {
        let fixes = [fix("evaluate", "evaluator"), fix("Jaba", "Java")]
        #expect(!fixes[0].applies)
        #expect(fixes[1].applies)
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "the evaluate run", edited: "the evaluator run", weight: LearnedFixes.confirmAt)
        #expect(learned.apply("the evaluate run") == "the evaluate run")
    }

    @Test func junkLearnedBeforeTheCheckIsCleanedUpWithABackup() throws {
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("before-cleanup.json"))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([fix("电脑", "手机"), fix("不许", "push")]).write(to: url)
        let learned = LearnedFixes(url: url)
        #expect(learned.fixes.map(\.meant) == ["push"])
        #expect(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("before-cleanup.json").path))
    }

    @Test func englishFixesReplaceWholeWordsInAnyCase() {
        let fixes = [fix("deline", "Deline")]
        #expect(LearnedFixes.apply(fixes, to: "DELINE and deline") == "Deline and Deline")
        #expect(LearnedFixes.apply(fixes, to: "delineate") == "delineate")
        #expect(LearnedFixes.apply(fixes, to: "去deline吧") == "去Deline吧")   // Chinese around it is a boundary
    }

    @Test func chineseFixesReplaceEveryOccurrence() {
        #expect(LearnedFixes.apply([fix("和派", "和pi")], to: "键盘和派，鼠标和派") == "键盘和pi，鼠标和pi")
    }

    @Test func longerFixesGoFirst() {
        let fixes = [fix("派", "pi"), fix("树莓派", "Raspberry Pi")]
        #expect(LearnedFixes.apply(fixes, to: "树莓派和派") == "Raspberry Pi和pi")
    }

    @Test func replacementTextIsLiteral() {
        #expect(LearnedFixes.apply([fix("dollar", "$1")], to: "one dollar") == "one $1")
    }

    @Test func hintsPutFixesForThisTextFirst() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "试试dation吧", edited: "试试dictation吧", weight: 5)
        learned.learn(typed: "记得不许上去", edited: "记得push上去")
        #expect(learned.hints(for: "可以不许吗") == Hints(sure: "dation → dictation", once: "不许 → push"))
        #expect(learned.hints(for: "可以不许吗", limit: 1) == Hints(once: "不许 → push"))
        learned.learn(typed: "记得不许上去", edited: "记得push上去")
        #expect(learned.hints(for: "可以不许吗") == Hints(sure: "不许 → push；dation → dictation"))
        #expect(learned.terms == ["dictation", "push"])
    }

    @Test func keepIsVocabularyAndTermsButNotWhatAFixChanges() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "记得不许上去", edited: "记得push上去")
        learned.learn(typed: "拿push打支架", edited: "拿pushes打支架")
        #expect(learned.keep(vocabulary: "Bambu, OrcaSlicer，Kuma\n Ender ") == ["Bambu", "OrcaSlicer", "Kuma", "Ender", "pushes"])
        #expect(learned.keep(vocabulary: "") == ["pushes"])   // push is what a fix changes
    }

    @Test func containsTerm() {
        #expect(TextDiff.contains("拿Ender打支架", term: "ender"))
        #expect(!TextDiff.contains("rendering", term: "ender"))
        #expect(TextDiff.contains("接上dwin的屏", term: "dwin"))
        #expect(TextDiff.contains("把板清了", term: "板"))
    }

    @Test func termsLeaveOutTheNeighbourKeptForContext() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "昨天没有铺过去", edited: "昨天没有push过去")
        learned.learn(typed: "问派森吧", edited: "问Python吧")
        #expect(learned.fixes.map(\.heard) == ["有铺", "派森"])
        #expect(learned.terms == ["push", "Python"])
        #expect(learned.keep(vocabulary: "") == ["push", "Python"])
        #expect(learned.fixes[0].core == ("铺", "push"))
        #expect(LearnedFix(heard: "dation", meant: "dictation", count: 1, lastSeen: .now).core == ("dation", "dictation"))
        #expect(LearnedFix(heard: "The Luga Halla", meant: "beluga Halluga", count: 1, lastSeen: .now).core == ("The Luga Halla", "beluga Halluga"))
    }

    @Test func fixesSurviveARestart() throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let learned = LearnedFixes(url: url)
        learned.learn(typed: "试试dation吧", edited: "试试dictation吧")
        Storage.flush()
        let reloaded = LearnedFixes(url: url)
        #expect(reloaded.fixes.map(\.heard) == ["dation"])
        #expect(reloaded.fixes.map(\.meant) == ["dictation"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func deleteAndClear() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "试试dation吧", edited: "试试dictation吧")
        learned.learn(typed: "记得不许上去", edited: "记得push上去")
        learned.delete(learned.fixes[0])
        #expect(learned.fixes.map(\.meant) == ["push"])
        learned.clear()
        #expect(learned.fixes.isEmpty)
    }
}
