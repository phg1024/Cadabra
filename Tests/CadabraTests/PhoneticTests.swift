import Testing
@testable import Cadabra

struct PhoneticTests {
    @Test(arguments: [("不许", "push"), ("派森", "Python"), ("杰森", "JSON"), ("and", "ender"), ("赛福瑞", "Safari"),
                      ("锅", "Go"), ("dation", "dictation"), ("12夜", "12页"), ("Jaba", "Java")])
    func mishearingsSoundAlike(heard: String, meant: String) {
        #expect(Phonetic.similar(heard, meant))
    }

    @Test(arguments: [("电脑", "手机"), ("engine", "model"), ("Swift", "Rust"), ("OK", "Sure"), ("拳头", "苹果"),
                      ("commit", "桌子"), ("明天见", "好的")])
    func rewritesDont(heard: String, meant: String) {
        #expect(!Phonetic.similar(heard, meant))
    }

    @Test func englishWords() {
        #expect(Phonetic.isEnglishWord("evaluate"))
        #expect(Phonetic.isEnglishWord("push"))
        #expect(!Phonetic.isEnglishWord("Jaba"))
        #expect(!Phonetic.isEnglishWord("不许"))
    }
}
