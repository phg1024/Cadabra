import Foundation
import os

private let log = Logger(subsystem: "com.peihongguo.Cadabra", category: "storage")

/// Reading and writing the app's own files (history, learned fixes, training data). Writes happen in
/// order on one background queue, so a big save never holds up the main thread (and with it the
/// keyboard, which the hotkey's event tap runs through).
enum Storage {
    static let queue = DispatchQueue(label: "com.peihongguo.Cadabra.storage", qos: .utility)

    /// Decodes a JSON file. A file that is there but can't be read is set aside as
    /// `<name>.corrupt-<date>` rather than overwritten by the next save.
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let aside = url.appendingPathExtension("corrupt-\(formatter.string(from: Date()))")
            try? FileManager.default.moveItem(at: url, to: aside)
            log.error("could not read \(url.lastPathComponent, privacy: .public), kept it as \(aside.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Encodes and writes atomically, owner-only, in the background.
    static func save<T: Encodable & Sendable>(_ value: T, to url: URL, sortedKeys: Bool = false) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = sortedKeys ? [.prettyPrinted, .sortedKeys] : [.prettyPrinted]
            guard let data = try? encoder.encode(value) else { return }
            write(data, to: url)
        }
    }

    /// On the queue: creates the folder (owner-only) and writes the file (owner-only).
    static func write(_ data: Data, to url: URL) {
        dispatchPrecondition(condition: .onQueue(queue))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("could not write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Waits for pending writes: at quit, and in tests.
    static func flush() {
        queue.sync {}
    }
}
