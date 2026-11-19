import Foundation

/// A recording with the text the user ended up with, for fine-tuning the speech model on their voice.
struct TrainingSample: Codable, Identifiable {
    enum Label: String, Codable {
        /// The user fixed the text: the most reliable.
        case edited
        /// Typed as recognized (plus learned fixes) and left alone.
        case unchanged
        /// The correction model changed it and the user left it alone: probably right, not certain.
        case modelChanged
    }

    var id: UUID
    var date: Date
    var audio: String
    var duration: Double
    /// SenseVoice's own output.
    var recognized: String
    var text: String
    var label: Label
}

/// ~/Library/Application Support/Cadabra/Training/: one WAV per dictation and samples.json (owner-only).
@MainActor
final class TrainingData: ObservableObject {
    static let shared = TrainingData()
    nonisolated static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cadabra/Training")

    @Published private(set) var samples: [TrainingSample] = []
    let directory: URL
    let limit: Int
    private var indexURL: URL { directory.appendingPathComponent("samples.json") }

    init(directory: URL = TrainingData.defaultDirectory, limit: Int = 5000) {
        self.directory = directory
        self.limit = limit
        samples = Storage.load([TrainingSample].self, from: indexURL) ?? []
    }

    var totalDuration: Double { samples.reduce(0) { $0 + $1.duration } }

    func add(id: UUID, audio: [Float], recognized: String, text: String, label: TrainingSample.Label) {
        let name = "\(id.uuidString).wav"
        let url = directory.appendingPathComponent(name)
        // On the storage queue, so the WAV is written before the index that names it.
        Storage.queue.async { Storage.write(AudioFile.wav(audio), to: url) }
        samples.append(TrainingSample(id: id, date: Date(), audio: name,
                                      duration: Double(audio.count) / Double(ASREngine.sampleRate),
                                      recognized: recognized, text: text, label: label))
        // Over the limit: the oldest samples the user never confirmed go first.
        while samples.count > limit, let i = samples.firstIndex(where: { $0.label != .edited }) ?? samples.indices.first {
            removeFile(samples.remove(at: i))
        }
        save()
    }

    /// The user's fixed version of a sample.
    func update(_ id: UUID, text: String) {
        guard let i = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[i].text = text
        samples[i].label = .edited
        save()
    }

    func remove(_ id: UUID) {
        guard let i = samples.firstIndex(where: { $0.id == id }) else { return }
        removeFile(samples.remove(at: i))
        save()
    }

    func clear() {
        samples.forEach(removeFile)
        samples.removeAll()
        save()
    }

    private func removeFile(_ sample: TrainingSample) {
        let url = directory.appendingPathComponent(sample.audio)
        Storage.queue.async { try? FileManager.default.removeItem(at: url) }
    }

    private func save() {
        Storage.save(samples, to: indexURL, sortedKeys: true)
    }
}
