import AVFoundation
import Testing
@testable import Cadabra

struct AudioProcessingTests {
    func sine(_ seconds: Double, rate: Double, amplitude: Float = 0.5, hz: Double = 440) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * hz / rate)) * amplitude }
    }

    func chunks(_ samples: [Float], of size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }

    /// The waveform ran 10× too fast when AUHAL started handing over 10 ms at a time.
    @Test(arguments: [48000.0, 44100, 24000, 16000], [1, 160, 441, 480, 4096, 48000])
    func tenLevelsASecondHoweverItIsChunked(rate: Double, size: Int) {
        var meter = LevelMeter(sampleRate: rate)
        let levels = chunks(sine(2, rate: rate), of: size).flatMap { meter.add($0) }
        #expect(levels.count == 20)
    }

    @Test func levelFollowsLoudness() {
        var meter = LevelMeter(sampleRate: 16000)
        #expect(meter.add([Float](repeating: 0, count: 1600)) == [0])
        let quiet = meter.add(sine(0.1, rate: 16000, amplitude: 0.01))[0]
        let loud = meter.add(sine(0.1, rate: 16000, amplitude: 0.5))[0]
        #expect(quiet > 0 && quiet < loud)
        #expect(meter.add(sine(0.1, rate: 16000, amplitude: 1)) == [1])
    }

    @Test(arguments: [48000.0, 44100, 24000], [480, 441, 4096])
    func resamplesChunksTo16k(rate: Double, size: Int) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let resampler = try #require(Resampler(from: format))
        let out = chunks(sine(1, rate: rate), of: size).flatMap { resampler.convert($0) }
        // The filter holds back a few milliseconds at the end; nothing is lost or doubled at the seams.
        #expect(abs(out.count - 16000) < 160, "\(out.count) samples")
        // Still a clean 440 Hz tone: compare with the ideal one, ignoring the filter's delay.
        let ideal = sine(1, rate: 16000)
        let best = (0..<64).map { lag in
            zip(out.dropFirst(lag).prefix(14000), ideal.prefix(14000)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / 14000
        }.min()!
        #expect(best < 1e-4, "mean squared error \(best)")
    }
}

struct PieceTests {
    /// Speech with a pause at 9 s and another at 19 s: the cuts land in the pauses, every piece at most 12 s.
    @Test func cutsAtThePauses() {
        let rate = ASREngine.sampleRate
        let samples = (0..<(25 * rate)).map { i -> Float in
            let t = Double(i) / Double(rate)
            let quiet = (8.8..<9.2).contains(t) || (18.8..<19.2).contains(t)
            return quiet ? 0 : Float(sin(Double(i) * 0.05)) * 0.3
        }
        let pieces = ASREngine.pieces(samples.count) { samples[$0] }
        #expect(pieces.count == 3)
        #expect(pieces.allSatisfy { $0.count <= Int(ASREngine.maxPiece) * rate })
        #expect(abs(Double(pieces[0].upperBound) / Double(rate) - 9) < 0.25)
        #expect(abs(Double(pieces[1].upperBound) / Double(rate) - 19) < 0.25)
        #expect(pieces.last?.upperBound == samples.count)
    }

    @Test func shortAudioIsOnePiece() {
        #expect(ASREngine.pieces(5 * ASREngine.sampleRate) { _ in 0.1 }.count == 1)
    }

    @Test func joinsPiecesLikeText() {
        #expect(ASREngine.join("开饭时间。", "下午五点") == "开饭时间。下午五点")
        #expect(ASREngine.join("for the boy.", "And then") == "for the boy. And then")
        #expect(ASREngine.join("pieces of", "gold") == "pieces of gold")
        #expect(ASREngine.join("of good", "开饭") == "of good开饭")
    }
}
