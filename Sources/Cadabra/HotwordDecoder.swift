import Foundation

/// Decodes SenseVoice's per-frame scores with a bias toward the user's own words: a CTC prefix beam
/// search in which a prefix that spells one of the hotwords gets a bonus per token, part of it while the
/// word is under way and all of it once the word is finished; a word that breaks off gives its part back.
/// A word the model barely heard can't win this way; one it was torn about (不许 or push?) can.
///
/// When the best answer spells no hotword at all, the plain greedy answer is used, so the beam search by
/// itself never changes anything. Tuned on the user's own recordings (research/knn-ctc/hotwords.py, then
/// `Cadabra --transcribe --hotwords`): character errors went from 4.9% to 3.8% on 294 recordings, 21
/// better and none worse; about 60 ms for a few seconds of speech.
struct HotwordDecoder {
    final class Node {
        var next: [Int: Node] = [:]
        var end = false
        var depth = 0
    }

    static let bonus: Float = 3.0
    static let partial: Float = 0.6
    static let beam = 16
    /// Candidate tokens per frame besides the hotwords' next pieces.
    static let top = 6
    /// Log-probability below which a token isn't considered at all.
    static let floor: Float = -14

    let root = Node()
    var isEmpty: Bool { root.next.isEmpty }

    /// `pieces`: the model's tokens. Each word goes in as every way of spelling it with the model's pieces
    /// (as it would be emitted inside a sentence, and lowercase too), so it matches however the model
    /// happens to split it.
    init(words: [String], pieces: [String]) {
        var index: [String: Int] = [:]
        for (i, piece) in pieces.enumerated() where index[piece] == nil && !piece.hasPrefix("<") { index[piece] = i }
        let longest = pieces.map(\.count).max() ?? 1
        for word in Set(words.flatMap { [$0, $0.lowercased()] }) {
            for form in [word, "▁" + word] {
                for spelling in Self.spellings(Array(form), index: index, longest: longest) { add(spelling) }
            }
        }
    }

    /// Hotwords worth a bonus: long enough not to match everywhere.
    static func usable(_ word: String) -> Bool {
        word.allSatisfy(\.isASCII) ? word.count >= 3 : word.count >= 2
    }

    /// Ways to write `chars` as a sequence of pieces, the fewest pieces first, at most a handful.
    static func spellings(_ chars: [Character], index: [String: Int], longest: Int, limit: Int = 12) -> [[Int]] {
        // fewest[i]: fewest pieces for chars[i...]; then walk the choices that stay within one of it.
        let n = chars.count
        var fewest = [Int](repeating: Int.max / 2, count: n + 1)
        fewest[n] = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in (i + 1)...min(n, i + longest) where index[String(chars[i..<j])] != nil {
                fewest[i] = min(fewest[i], 1 + fewest[j])
            }
        }
        guard fewest[0] < Int.max / 2 else { return [] }
        let budget = fewest[0] + 1
        var out: [[Int]] = []
        func walk(_ i: Int, _ path: [Int]) {
            guard out.count < limit else { return }
            if i == n { out.append(path); return }
            for j in (i + 1)...min(n, i + longest) {
                guard let id = index[String(chars[i..<j])], path.count + 1 + fewest[j] <= budget else { continue }
                walk(j, path + [id])
            }
        }
        walk(0, [])
        return out.sorted { $0.count < $1.count }
    }

    private func add(_ ids: [Int]) {
        var node = root
        for id in ids {
            if let child = node.next[id] {
                node = child
            } else {
                let child = Node()
                child.depth = node.depth + 1
                node.next[id] = child
                node = child
            }
        }
        node.end = true
    }

    /// The context after `token`: where in a word it is, the bonus still pending, and the score change.
    private func step(_ node: Node, _ pending: Float, _ token: Int) -> (Node, Float, Float) {
        var node = node, change: Float = 0
        if node.next[token] == nil {
            change = -pending   // the partial word broke off
            node = root
            if root.next[token] == nil { return (root, 0, change) }
        }
        let child = node.next[token]!
        if child.end {
            let whole = Self.bonus * Float(child.depth)
            return (child.next.isEmpty ? root : child, 0, change + whole - (node === root ? 0 : pending))
        }
        let part = Self.bonus * Self.partial
        return (child, (node === root ? 0 : pending) + part, change + part)
    }

    private struct Beam {
        var blank: Float      // log P(prefix), ending in blank
        var token: Float      // log P(prefix), ending in its last token
        var node: Node
        var pending: Float
        var context: Float
        var total: Float { logAdd(blank, token) }
    }

    /// The tokens of the best answer, or nil when it spells no hotword (use greedy decoding then).
    func decode(_ scores: SenseVoiceNet.Scores) -> [Int]? {
        guard !isEmpty, scores.frames > 0 else { return nil }
        let blankID = SenseVoiceNet.blank
        let rootTokens = Array(root.next.keys)
        var beams: [[Int]: Beam] = [[]: Beam(blank: 0, token: -.infinity, node: root, pending: 0, context: 0)]
        scores.logp.withUnsafeBufferPointer { logp in
            for t in 0..<scores.frames {
                let row = UnsafeBufferPointer(rebasing: logp[t * scores.vocabulary..<(t + 1) * scores.vocabulary])
                var candidates = Set(Self.topIndices(row, Self.top))
                candidates.formUnion(rootTokens)
                for beam in beams.values { candidates.formUnion(beam.node.next.keys) }
                candidates.remove(blankID)
                var next: [[Int]: Beam] = [:]
                func extend(_ prefix: [Int], from beam: Beam, token: Int, score: Float) {
                    if var existing = next[prefix] {
                        existing.token = logAdd(existing.token, score)
                        next[prefix] = existing
                    } else {
                        let (node, pending, change) = step(beam.node, beam.pending, token)
                        next[prefix] = Beam(blank: -.infinity, token: score, node: node, pending: pending, context: beam.context + change)
                    }
                }
                for (prefix, beam) in beams {
                    let total = beam.total
                    if var same = next[prefix] {
                        same.blank = logAdd(same.blank, total + row[blankID])
                        next[prefix] = same
                    } else {
                        next[prefix] = Beam(blank: total + row[blankID], token: -.infinity, node: beam.node, pending: beam.pending, context: beam.context)
                    }
                    let last = prefix.last
                    for c in candidates {
                        let p = row[c]
                        // Too unlikely to be said here: even a whole word's bonus wouldn't carry it.
                        if p < Self.floor { continue }
                        if c == last {
                            // The same token going on, or (after a blank) the token again.
                            var same = next[prefix]!
                            same.token = logAdd(same.token, beam.token + p)
                            next[prefix] = same
                            extend(prefix + [c], from: beam, token: c, score: beam.blank + p)
                        } else {
                            extend(prefix + [c], from: beam, token: c, score: total + p)
                        }
                    }
                }
                beams = Dictionary(uniqueKeysWithValues: next.sorted { $0.value.total + $0.value.context > $1.value.total + $1.value.context }
                    .prefix(Self.beam).map { ($0.key, $0.value) })
            }
        }
        // An unfinished word gives its part back.
        guard let best = beams.max(by: { $0.value.total + $0.value.context - $0.value.pending < $1.value.total + $1.value.context - $1.value.pending }),
              best.value.context - best.value.pending > 0 else { return nil }
        return best.key
    }

    private static func topIndices(_ row: UnsafeBufferPointer<Float>, _ k: Int) -> [Int] {
        var best: [(Int, Float)] = []
        for (i, p) in row.enumerated() where best.count < k || p > best[best.count - 1].1 {
            let at = best.firstIndex { p > $0.1 } ?? best.count
            best.insert((i, p), at: at)
            if best.count > k { best.removeLast() }
        }
        return best.map(\.0)
    }
}

private func logAdd(_ a: Float, _ b: Float) -> Float {
    if a == -.infinity { return b }
    if b == -.infinity { return a }
    let m = max(a, b)
    return m + log(exp(a - m) + exp(b - m))
}
