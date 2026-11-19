import Accelerate
import COnnxRuntime
import Foundation

/// SenseVoice-Small run through onnxruntime directly, rather than sherpa-onnx's recognizer, to get the
/// model's score for every token at every frame: the hotword decoder needs them. The features and the
/// greedy text are the same as sherpa-onnx's (checked on real recordings: `Cadabra --transcribe`
/// with CADABRA_ASR=sherpa for the other side).
final class SenseVoiceNet {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Per-frame log-probabilities, frames × vocabulary, without the four query frames in front.
    struct Scores {
        let logp: [Float]
        let frames: Int
        let vocabulary: Int

        func row(_ t: Int) -> ArraySlice<Float> { logp[t * vocabulary..<(t + 1) * vocabulary] }
    }

    static let blank = 0
    let pieces: [String]

    private let api: OrtApi
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var memory: OpaquePointer?
    private let negMean: [Float]
    private let invStd: [Float]
    private let languages: [String: Int32]
    private let withITN: Int32
    private let fbank = Fbank()

    init(modelDirectory dir: URL) throws {
        guard let base = OrtGetApiBase(), let pointer = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw Failure(message: "onnxruntime API \(ORT_API_VERSION) not available")
        }
        let api = pointer.pointee
        self.api = api
        func check(_ status: OpaquePointer?) throws {
            guard let status else { return }
            defer { api.ReleaseStatus(status) }
            throw Failure(message: api.GetErrorMessage(status).map { String(cString: $0) } ?? "onnxruntime error")
        }

        pieces = try String(contentsOf: dir.appendingPathComponent("tokens.txt"), encoding: .utf8)
            .split(separator: "\n").map { line in
                line.lastIndex(of: " ").map { String(line[..<$0]) } ?? String(line)
            }

        try check(api.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "cadabra", &env))
        var options: OpaquePointer?
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try check(api.SetIntraOpNumThreads(options, 4))
        try check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        try check(api.CreateSession(env, dir.appendingPathComponent("model.int8.onnx").path, options, &session))
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))

        // Normalization and the query tokens are in the model's metadata.
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try check(api.GetAllocatorWithDefaultOptions(&allocator))
        var metadata: OpaquePointer?
        try check(api.SessionGetModelMetadata(session, &metadata))
        defer { api.ReleaseModelMetadata(metadata) }
        func value(_ key: String) throws -> String {
            var out: UnsafeMutablePointer<CChar>?
            try check(api.ModelMetadataLookupCustomMetadataMap(metadata, allocator, key, &out))
            guard let out else { throw Failure(message: "model metadata has no \(key)") }
            defer { allocator?.pointee.Free(allocator, out) }
            return String(cString: out)
        }
        negMean = try value("neg_mean").split(separator: ",").compactMap { Float($0) }
        invStd = try value("inv_stddev").split(separator: ",").compactMap { Float($0) }
        var languages: [String: Int32] = [:]
        for name in ["auto", "zh", "en", "yue", "ja", "ko"] { languages[name] = Int32(try value("lang_\(name)")) }
        self.languages = languages
        withITN = Int32(try value("with_itn")) ?? 14
        guard negMean.count == 560, invStd.count == 560 else { throw Failure(message: "unexpected normalization in the model") }
    }

    deinit {
        if let memory { api.ReleaseMemoryInfo(memory) }
        if let session { api.ReleaseSession(session) }
        if let env { api.ReleaseEnv(env) }
    }

    /// 16 kHz mono samples in −1…1.
    func scores(_ samples: [Float], language: String) throws -> Scores {
        var (x, frames) = lfr(fbank.compute(samples))
        guard frames > 0 else { return Scores(logp: [], frames: 0, vocabulary: pieces.count) }
        var length = Int32(frames), lang = languages[language] ?? 0, norm = withITN
        let api = self.api
        func check(_ status: OpaquePointer?) throws {
            guard let status else { return }
            defer { api.ReleaseStatus(status) }
            throw Failure(message: api.GetErrorMessage(status).map { String(cString: $0) } ?? "onnxruntime error")
        }

        var values: [OpaquePointer?] = []
        defer { values.forEach { api.ReleaseValue($0) } }
        func tensor<T>(_ data: UnsafeMutablePointer<T>, count: Int, shape: [Int64], type: ONNXTensorElementDataType) throws {
            var value: OpaquePointer?
            try shape.withUnsafeBufferPointer {
                try check(api.CreateTensorWithDataAsOrtValue(memory, data, count * MemoryLayout<T>.stride, $0.baseAddress, $0.count, type, &value))
            }
            values.append(value)
        }
        var output: OpaquePointer?
        try x.withUnsafeMutableBufferPointer { features in
            try tensor(features.baseAddress!, count: features.count, shape: [1, Int64(frames), 560], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            try tensor(&length, count: 1, shape: [1], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32)
            try tensor(&lang, count: 1, shape: [1], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32)
            try tensor(&norm, count: 1, shape: [1], type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32)
            let inputNames: [UnsafeMutablePointer<CChar>] = ["x", "x_length", "language", "text_norm"].map { (name: String) in strdup(name)! }
            let outputNames: [UnsafeMutablePointer<CChar>] = [strdup("logits")!]
            defer { (inputNames + outputNames).forEach { free($0) } }
            var inputs: [OpaquePointer?] = values
            try inputNames.map { UnsafePointer($0) }.withUnsafeBufferPointer { names in
                try outputNames.map { UnsafePointer($0) }.withUnsafeBufferPointer { outs in
                    try check(api.Run(session, nil, names.baseAddress, &inputs, 4, outs.baseAddress, 1, &output))
                }
            }
        }
        defer { api.ReleaseValue(output) }

        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(output, &info))
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var dims = [Int64](repeating: 0, count: 3)
        try check(api.GetDimensions(info, &dims, 3))
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &raw))
        guard let raw else { throw Failure(message: "no output") }
        let total = Int(dims[1]), vocabulary = Int(dims[2]), skip = 4
        let outFrames = max(0, total - skip)
        let logits = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self).advanced(by: skip * vocabulary),
                                         count: outFrames * vocabulary)
        // Log-softmax per frame.
        var logp = [Float](repeating: 0, count: outFrames * vocabulary)
        logp.withUnsafeMutableBufferPointer { out in
            for t in 0..<outFrames {
                let row = UnsafeBufferPointer(rebasing: logits[t * vocabulary..<(t + 1) * vocabulary])
                let top = vDSP.maximum(row)
                var shifted = vDSP.add(-top, row)
                vForce.exp(shifted, result: &shifted)
                let norm = log(vDSP.sum(shifted)) + top
                var dest = UnsafeMutableBufferPointer(rebasing: out[t * vocabulary..<(t + 1) * vocabulary])
                vDSP.add(-norm, row, result: &dest)
            }
        }
        return Scores(logp: logp, frames: outFrames, vocabulary: vocabulary)
    }

    /// Low frame rate: 7 frames stacked every 6 (the first repeated to fill the window), then normalized.
    private func lfr(_ fbank: (data: [Float], frames: Int)) -> ([Float], Int) {
        let (data, count) = fbank
        guard count > 0 else { return ([], 0) }
        let bins = Fbank.bins, window = 7, step = 6, pad = (window - 1) / 2, width = window * bins
        let n = (count + step - 1) / step
        var out = [Float](repeating: 0, count: n * width)
        for i in 0..<n {
            for j in 0..<window {
                // Rows of the padded matrix: copies of the first frame, then the frames; past the end, the last.
                let source = min(max(i * step + j - pad, 0), count - 1)
                for b in 0..<bins { out[i * width + j * bins + b] = data[source * bins + b] }
            }
            for k in 0..<width { out[i * width + k] = (out[i * width + k] + negMean[k]) * invStd[k] }
        }
        return (out, n)
    }

    // MARK: Text

    /// The best token of every frame, repeats merged and blanks dropped.
    static func greedy(_ scores: Scores) -> [Int] {
        var out: [Int] = []
        var previous = -1
        scores.logp.withUnsafeBufferPointer { logp in
            for t in 0..<scores.frames {
                let row = UnsafeBufferPointer(rebasing: logp[t * scores.vocabulary..<(t + 1) * scores.vocabulary])
                let best = Int(vDSP.indexOfMaximum(row).0)
                if best != previous && best != blank { out.append(best) }
                previous = best
            }
        }
        return out
    }

    func text(_ tokens: [Int]) -> String {
        tokens.map { pieces[$0] }.joined().replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Kaldi-style log mel filterbank, as sherpa-onnx computes it for SenseVoice: 25 ms Hamming windows every
/// 10 ms (whole windows only), DC removed, pre-emphasis 0.97, power spectrum, 80 mel bins from 20 Hz to
/// Nyquist; samples scaled to the 16-bit range first.
struct Fbank {
    static let bins = 80
    private static let length = 400, shift = 160, fftSize = 512

    private let window: [Float]
    /// For each mel bin: the first FFT bin it covers and its weights.
    private let filters: [(start: Int, weights: [Float])]
    private let dft = try! vDSP.DiscreteFourierTransform(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self)

    init() {
        let n = Self.length
        window = (0..<n).map { 0.54 - 0.46 * cos(2 * Float.pi * Float($0) / Float(n - 1)) }
        func mel(_ f: Float) -> Float { 1127 * log(1 + f / 700) }
        let low = mel(20), high = mel(8000), delta = (high - low) / Float(Self.bins + 1)
        let binWidth = Float(16000) / Float(Self.fftSize)
        filters = (0..<Self.bins).map { b in
            let left = low + Float(b) * delta, center = left + delta, right = center + delta
            var start = -1
            var weights: [Float] = []
            for i in 0..<(Self.fftSize / 2) {
                let m = mel(binWidth * Float(i))
                guard m > left, m < right else { continue }
                if start < 0 { start = i }
                weights.append(m <= center ? (m - left) / (center - left) : (right - m) / (right - center))
            }
            return (max(start, 0), weights)
        }
    }

    func compute(_ samples: [Float]) -> (data: [Float], frames: Int) {
        guard samples.count >= Self.length else { return ([], 0) }
        let frames = 1 + (samples.count - Self.length) / Self.shift
        var out = [Float](repeating: 0, count: frames * Self.bins)
        var frame = [Float](repeating: 0, count: Self.fftSize)
        let zeros = [Float](repeating: 0, count: Self.fftSize)
        var re = [Float](repeating: 0, count: Self.fftSize), im = re
        var power = [Float](repeating: 0, count: Self.fftSize / 2)
        for f in 0..<frames {
            let start = f * Self.shift
            for i in 0..<Self.length { frame[i] = samples[start + i] * 32768 }
            let mean = vDSP.mean(frame[0..<Self.length])
            for i in 0..<Self.length { frame[i] -= mean }
            for i in stride(from: Self.length - 1, to: 0, by: -1) { frame[i] -= 0.97 * frame[i - 1] }
            frame[0] -= 0.97 * frame[0]
            for i in 0..<Self.length { frame[i] *= window[i] }
            for i in Self.length..<Self.fftSize { frame[i] = 0 }
            dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
            for i in 0..<(Self.fftSize / 2) { power[i] = re[i] * re[i] + im[i] * im[i] }
            for (b, filter) in filters.enumerated() {
                var energy: Float = 0
                for (k, w) in filter.weights.enumerated() { energy += w * power[filter.start + k] }
                out[f * Self.bins + b] = log(max(energy, Float.ulpOfOne))
            }
        }
        return (out, frames)
    }
}
