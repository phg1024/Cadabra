import Foundation

/// Roughly how text sounds, to tell a mishearing (不许 → push, 派森 → Python) from a rewrite
/// (电脑 → 手机, engine → model). Chinese goes through pinyin; then letters that are easily heard as
/// one another fall together, and a run of vowels counts as one.
enum Phonetic {
    static func key(_ text: String) -> String {
        var s = (text.applyingTransform(.mandarinToLatin, reverse: false) ?? text)
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? text.lowercased()
        // English -er sounds like a plain vowel to most ears here (ender ~ 恩的).
        s = s.replacing(#/er\b/#, with: "a")
        s = String(s.filter { $0.isASCII && $0.isLetter })
        for (from, to) in [("sh", "s"), ("ch", "s"), ("zh", "s"), ("ph", "f"), ("th", "t"), ("ck", "k"), ("ng", "n")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        for ch in s {
            let mapped = classes[ch] ?? "a"   // vowels and y
            if out.last != mapped { out.append(mapped) }
        }
        return out
    }

    private static let classes: [Character: Character] = [
        "b": "p", "p": "p", "d": "t", "t": "t", "g": "k", "k": "k", "c": "k", "q": "s",
        "s": "s", "z": "s", "x": "s", "j": "s", "l": "n", "n": "n", "r": "n", "m": "n",
        "f": "f", "h": "f", "w": "f", "v": "f",
    ]

    /// Sound alike: the keys differ in about a third of their length at most (one letter always passes),
    /// half when English was heard as Chinese or the other way round (肯贝 → commit), since pinyin can
    /// only get so close.
    static func similar(_ a: String, _ b: String) -> Bool {
        let (x, y) = (Array(key(a)), Array(key(b)))
        guard !x.isEmpty, !y.isEmpty else { return false }
        // Part of a word heard, the whole meant (dation → dictation).
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if short.count >= 3, String(long).contains(String(short)) { return true }
        let crossScript = isHan(a) != isHan(b)
        return distance(x, y) <= max(1, Int(Double(max(x.count, y.count)) * (crossScript ? 0.5 : 0.35)))
    }

    private static func isHan(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, cb) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (ca == cb ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// Plain English words ("push", "evaluate"): a fix that rewrites one is too risky to apply blindly,
    /// since the same word is usually right. From the system's word list.
    static func isEnglishWord(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter })
        return !words.isEmpty && words.allSatisfy { $0.allSatisfy(\.isASCII) && dictionary.contains(String($0)) }
    }

    private static let dictionary: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()
}
