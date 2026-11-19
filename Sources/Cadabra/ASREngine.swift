import AppKit
import CSherpaOnnx
import Foundation

struct Transcript {
    let text: String
    let duration: Double   // seconds of audio
    let latency: Double    // seconds spent decoding
}

enum ASRError: LocalizedError {
    case modelMissing(String)
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing(let path): t("找不到模型文件：\(path)", "Model file not found: \(path)")
        case .loadFailed: t("SenseVoice 模型加载失败", "Could not load the SenseVoice model")
        }
    }
}

/// SenseVoice-Small, run through onnxruntime and decoded here (with a bias toward the user's words, see
/// `HotwordDecoder`); sherpa-onnx's recognizer is the fallback, and what CADABRA_ASR=sherpa uses.
/// Loading and decoding run on one serial queue, so a transcription requested while the model (re)loads
/// simply waits for it.
final class ASREngine: @unchecked Sendable {
    static let sampleRate = 16000

    private let queue = DispatchQueue(label: "Cadabra.asr", qos: .userInitiated)
    private var net: SenseVoiceNet?
    private var recognizer: OpaquePointer?
    private var language = Language.auto
    private var loadError: Error?
    private var decoder: (words: [String], decoder: HotwordDecoder)?

    /// The bundled model, or CADABRA_MODEL_DIR, or models/ in the current directory (for `swift run`).
    static func defaultModelDirectory() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CADABRA_MODEL_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("model"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.int8.onnx").path) }
    }

    func load(modelDirectory: URL?, language: Language, completion: @escaping (Error?) -> Void) {
        queue.async {
            if let old = self.recognizer { SherpaOnnxDestroyOfflineRecognizer(old) }
            self.recognizer = nil
            self.net = nil
            self.language = language
            self.loadError = nil
            if ProcessInfo.processInfo.environment["CADABRA_ASR"] != "sherpa", let dir = modelDirectory {
                do {
                    self.net = try SenseVoiceNet(modelDirectory: dir)
                } catch {
                    NSLog("Cadabra: onnxruntime path unavailable, using sherpa-onnx: \(error.localizedDescription)")
                }
            }
            if self.net == nil {
                do {
                    self.recognizer = try Self.makeRecognizer(modelDirectory: modelDirectory, language: language)
                } catch {
                    self.loadError = error
                }
            }
            completion(self.loadError)
        }
    }

    /// `hotwords`: the user's own words, favoured where the model was unsure (see `HotwordDecoder`).
    func transcribe(_ samples: [Float], hotwords: [String] = []) async throws -> Transcript {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.decode(samples, hotwords: hotwords) })
            }
        }
    }

    private func decode(_ samples: [Float], hotwords: [String]) throws -> Transcript {
        if let net { return try decode(samples, with: net, hotwords: hotwords) }
        guard let recognizer else { throw loadError ?? ASRError.loadFailed }
        let start = Date()
        let stream = SherpaOnnxCreateOfflineStream(recognizer)
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        var text = ""
        if let result = SherpaOnnxGetOfflineStreamResult(stream) {
            if let raw = result.pointee.text { text = String(cString: raw) }
            SherpaOnnxDestroyOfflineRecognizerResult(result)
        }
        return Transcript(text: Self.clean(text),
                          duration: Double(samples.count) / Double(Self.sampleRate),
                          latency: Date().timeIntervalSince(start))
    }

    private func decode(_ samples: [Float], with net: SenseVoiceNet, hotwords: [String]) throws -> Transcript {
        let start = Date()
        let scores = try net.scores(samples, language: language.rawValue)
        let words = hotwords.filter(HotwordDecoder.usable)
        if decoder?.words != words { decoder = (words, HotwordDecoder(words: words, pieces: net.pieces)) }
        let tokens = decoder?.decoder.decode(scores) ?? SenseVoiceNet.greedy(scores)
        return Transcript(text: Self.clean(net.text(tokens)),
                          duration: Double(samples.count) / Double(Self.sampleRate),
                          latency: Date().timeIntervalSince(start))
    }

    /// SenseVoice can leave tags such as <|zh|><|NEUTRAL|><|Speech|> in the text.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeRecognizer(modelDirectory: URL?, language: Language) throws -> OpaquePointer {
        guard let dir = modelDirectory else { throw ASRError.modelMissing("model.int8.onnx") }
        let model = dir.appendingPathComponent("model.int8.onnx").path
        let tokens = dir.appendingPathComponent("tokens.txt").path
        for path in [model, tokens] where !FileManager.default.fileExists(atPath: path) {
            throw ASRError.modelMissing(path)
        }
        // The C structs hold borrowed pointers; keep the copies alive until the recognizer exists.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(sampleRate)
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = c(model)
        config.model_config.sense_voice.language = c(language.rawValue)
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = c(tokens)
        config.model_config.num_threads = 4
        config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search")
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else { throw ASRError.loadFailed }
        return recognizer
    }
}

/// SenseVoice sometimes emits the end of an English word twice: a whole-word token followed by a
/// piece that repeats its ending ("pending" + "ending", "object" + "ject"). Such a word is removed
/// only when the word as given is misspelled and the word without the repeat is spelled correctly,
/// so real words ("singing", "papa") and names stay as they are. Uses the local spell checker.
enum RepeatedEnding {
    static func fix(_ text: String) -> String {
        var result = text
        let words = text.ranges(of: #/[A-Za-z]{5,}/#).reversed()
        for range in words {
            let word = String(text[range])
            if let fixed = repaired(word) { result.replaceSubrange(range, with: fixed) }
        }
        return result
    }

    private static func repaired(_ word: String) -> String? {
        guard !isWord(word) else { return nil }
        let chars = Array(word)
        // Longest repeat first: "visualualization" drops "ual", not a shorter accident.
        for length in stride(from: chars.count / 2, through: 2, by: -1) {
            for start in 0...(chars.count - 2 * length) {
                guard chars[start..<start + length] == chars[start + length..<start + 2 * length] else { continue }
                var candidate = chars
                candidate.removeSubrange(start + length..<start + 2 * length)
                let fixed = String(candidate)
                if isWord(fixed) { return fixed }
            }
        }
        return nil
    }

    private static func isWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}
