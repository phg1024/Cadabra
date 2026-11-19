import Foundation

/// An agent the agent key talks to, as a plugin: a folder in ~/Library/Application Support/Cadabra/Plugins/
/// with a `plugin.json` and a web page. Cadabra only listens: it records while the key is held,
/// recognizes the words, and hands them to the page (`PluginHost`). Everything else is the plugin's:
/// its window's contents, confirming, talking to its agent, showing the answer, reading it aloud, its
/// look, its token. See docs/plugins.md.
struct AgentPlugin: Identifiable, Equatable {
    let id: String
    let name: String
    let folder: URL
    let entry: URL
    /// The window's size to start with; the page can change it.
    let width: Double
    let height: Double
    /// The only places the page may reach (scheme, host and port), e.g. "http://localhost:8787".
    let hosts: [String]

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cadabra/Plugins")

    static func installed(in directory: URL = directory) -> [AgentPlugin] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap(load).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func named(_ id: String) -> AgentPlugin? {
        id.isEmpty ? nil : load(directory.appendingPathComponent(id))
    }

    /// The plugin chosen in Settings, or the only one installed.
    @MainActor static var selected: AgentPlugin? {
        named(Preferences.shared.agentPlugin) ?? (Preferences.shared.agentPlugin.isEmpty ? installed().first : nil)
    }

    /// `plugin.json`: {"name": "…", "entry": "index.html", "width": 440, "height": 180, "hosts": ["http://…"]}.
    static func load(_ folder: URL) -> AgentPlugin? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("plugin.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let entry = folder.appendingPathComponent(manifest["entry"] as? String ?? "index.html").standardizedFileURL
        // The page has to be inside the plugin's own folder.
        guard entry.path.hasPrefix(folder.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: entry.path) else { return nil }
        let size = { (key: String, fallback: Double) in min(max((manifest[key] as? NSNumber)?.doubleValue ?? fallback, 120), 900) }
        let hosts = (manifest["hosts"] as? [String] ?? []).compactMap(origin)
        return AgentPlugin(id: folder.lastPathComponent, name: manifest["name"] as? String ?? folder.lastPathComponent,
                           folder: folder, entry: entry, width: size("width", 440), height: size("height", 180), hosts: hosts)
    }

    /// "scheme://host:port" of an http(s) address, or nil.
    static func origin(_ address: String) -> String? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// Whether the plugin may send a request to `url`.
    func allows(_ url: URL) -> Bool {
        guard let origin = Self.origin(url.absoluteString) else { return false }
        return hosts.contains(origin)
    }
}
