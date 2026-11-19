import Testing
@testable import Cadabra

struct HotwordDecoderTests {
    static let pieces = ["<blk>", "不", "许", "p", "ush", "出", "去", "pu", "sh", "push"]
    static func id(_ piece: String) -> Int { pieces.firstIndex(of: piece)! }

    /// Frames given as the pieces worth mentioning and their log-probabilities; everything else very unlikely.
    func scores(_ frames: [[String: Float]]) -> SenseVoiceNet.Scores {
        let v = Self.pieces.count
        var logp = [Float](repeating: -30, count: frames.count * v)
        for (t, frame) in frames.enumerated() {
            for (piece, p) in frame { logp[t * v + Self.id(piece)] = p }
        }
        return SenseVoiceNet.Scores(logp: logp, frames: frames.count, vocabulary: v)
    }

    /// 不许出去, with p/ush a close second for the first two characters.
    func torn(_ second: Float) -> SenseVoiceNet.Scores {
        scores([["不": -0.3, "p": second], ["<blk>": -0.05], ["许": -0.3, "ush": second], ["<blk>": -0.05],
                ["出": -0.1], ["去": -0.1], ["<blk>": -0.05]])
    }

    @Test func aHotwordTheModelWasTornAboutWins() {
        let decoder = HotwordDecoder(words: ["push"], pieces: Self.pieces)
        let tokens = decoder.decode(torn(-1.5))
        #expect(tokens.map { $0.map { Self.pieces[$0] }.joined() } == "push出去")
    }

    @Test func aHotwordTheModelBarelyHeardDoesnt() {
        let decoder = HotwordDecoder(words: ["push"], pieces: Self.pieces)
        #expect(decoder.decode(torn(-9)) == nil)   // nothing spelled: the caller keeps greedy decoding
        #expect(SenseVoiceNet.greedy(torn(-9)).map { Self.pieces[$0] }.joined() == "不许出去")
    }

    @Test func noHotwordsMeansNoBeamSearch() {
        let decoder = HotwordDecoder(words: [], pieces: Self.pieces)
        #expect(decoder.isEmpty)
        #expect(decoder.decode(torn(-1.5)) == nil)
    }

    @Test func everySpellingWithTheFewestPiecesOrOneMore() {
        var index: [String: Int] = [:]
        for (i, p) in Self.pieces.enumerated() { index[p] = i }
        let spellings = HotwordDecoder.spellings(Array("push"), index: index, longest: 4)
            .map { $0.map { Self.pieces[$0] }.joined(separator: "|") }
        #expect(spellings.first == "push")
        #expect(Set(spellings) == ["push", "p|ush", "pu|sh"])
        #expect(HotwordDecoder.spellings(Array("xyz"), index: index, longest: 4).isEmpty)
    }

    @Test func wordsTooShortToFavour() {
        #expect(HotwordDecoder.usable("push"))
        #expect(!HotwordDecoder.usable("pi"))
        #expect(HotwordDecoder.usable("上海"))
        #expect(!HotwordDecoder.usable("页"))
    }

    @Test func learnedHotwordsAreTheEnglishWordsCorrectedTo() {
        let learned = LearnedFixes(url: nil)
        learned.learn(typed: "有铺上去", edited: "有push上去")
        learned.learn(typed: "问派森吧", edited: "问Python吧")
        learned.learn(typed: "放在这件桌上", edited: "放在这边桌上")
        #expect(Set(learned.hotwords) == ["push", "Python"])
    }
}
