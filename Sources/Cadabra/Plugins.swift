import AppKit
import SwiftUI
import WebKit

/// An agent the agent key can talk to, packaged by someone else: a folder in
/// ~/Library/Application Support/Cadabra/Plugins/ with a `plugin.json` that says how to talk to it (an
/// HTTP API, see docs/plugins.md) and, optionally, a web page for its look at the top of the panel. The
/// page is told what is happening many times a second (`window.cadabra.update`); it may read only its
/// own folder and nothing from the network, and never sees the words or the replies.
struct AgentPlugin: Identifiable, Equatable {
    let id: String
    let name: String
    let folder: URL
    let api: API
    let look: Look?

    /// How to talk to the agent. Paths are relative to the address.
    struct API: Equatable {
        /// The default address; the user can set another in Settings.
        var address: String
        /// POST here with {textField: words}; the answer has {replyField: …}.
        var ask = "/text"
        var textField = "text"
        var replyField = "reply"
        /// A conversation id goes out in this header and comes back in this field, to continue it.
        var conversationHeader: String? = "X-Conversation-Id"
        var conversationField = "conversation_id"
        /// The answer may stream as newline-delimited JSON ({"type": "activity"|"result"|"error"}).
        var streams = false
        /// POST {"text", "language"} here for a WAV of the reply; nil if the agent can't speak.
        var speech: String?
        /// GET here to check the address and token; nil skips the check.
        var health: String?
        /// "bearer": the token goes in an Authorization header; "none": no token.
        var token = "bearer"
    }

    struct Look: Equatable {
        let entry: URL
        /// The height it takes at the top of the panel, in points.
        let height: CGFloat
        /// Colours for the whole panel, so it looks of a piece with the plugin; nil keeps the theme's.
        let background: Color?
        let foreground: Color?
    }

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

    /// Where requests go: the user's address if set, else the plugin's.
    @MainActor var address: String {
        let own = Preferences.shared.agentURL.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? api.address : own
    }

    static func load(_ folder: URL) -> AgentPlugin? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("plugin.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let agent = manifest["agent"] as? [String: Any] else { return nil }
        var api = API(address: agent["address"] as? String ?? "")
        if let v = agent["ask"] as? String { api.ask = v }
        if let v = agent["text_field"] as? String { api.textField = v }
        if let v = agent["reply_field"] as? String { api.replyField = v }
        if let conversation = agent["conversation"] as? [String: Any] {
            api.conversationHeader = conversation["header"] as? String
            if let v = conversation["field"] as? String { api.conversationField = v }
        } else if agent["conversation"] is NSNull {
            api.conversationHeader = nil
        }
        api.streams = (agent["stream"] as? String) == "ndjson"
        api.speech = agent["speech"] as? String
        api.health = agent["health"] as? String
        if let v = agent["token"] as? String { api.token = v }

        var look: Look?
        if let spec = manifest["look"] as? [String: Any] {
            let entry = folder.appendingPathComponent(spec["entry"] as? String ?? "index.html").standardizedFileURL
            // The page has to be inside the plugin's own folder.
            if entry.path.hasPrefix(folder.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: entry.path) {
                let height = (spec["height"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 120
                look = Look(entry: entry, height: min(max(height, 40), 400),
                            background: (spec["background"] as? String).flatMap(Color.init(hex:)),
                            foreground: (spec["foreground"] as? String).flatMap(Color.init(hex:)))
            }
        }
        return AgentPlugin(id: folder.lastPathComponent, name: manifest["name"] as? String ?? folder.lastPathComponent,
                           folder: folder, api: api, look: look)
    }

    /// The event a look gets: what the panel is doing, what the agent says it is doing, how loud.
    static func event(phase: Agent.Phase, activity: String?, speaking: Bool, level: Float) -> String {
        let name: String
        switch phase {
        case .listening: name = "listening"
        case .confirm: name = "confirm"
        case .waiting: name = "waiting"
        case .reply: name = "reply"
        case .failed: name = "failed"
        }
        let object: [String: Any] = ["phase": name, "activity": activity ?? NSNull(), "speaking": speaking,
                                     "level": Double((min(max(level, 0), 1) * 1000).rounded() / 1000)]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension Color {
    /// "#rrggbb".
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// A plugin's look, fed an event `perSecond` times while it is on screen.
struct PluginView: NSViewRepresentable {
    let plugin: AgentPlugin
    let look: AgentPlugin.Look
    let event: () -> String
    static let perSecond = 20.0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        // Nothing from the network: a look has no business there.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "cadabra-plugin-offline",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^(https?|wss?)://"},"action":{"type":"block"}}]"#
        ) { list, _ in
            if let list { view.configuration.userContentController.add(list) }
            view.loadFileURL(look.entry, allowingReadAccessTo: plugin.folder)
        }
        context.coordinator.start(view, event: event)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.event = event
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        var event: (() -> String)?
        private var timer: Timer?
        private weak var view: WKWebView?

        func start(_ view: WKWebView, event: @escaping () -> String) {
            self.view = view
            self.event = event
            timer = Timer.scheduledTimer(withTimeInterval: 1 / PluginView.perSecond, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func tick() {
            guard let view, let event, view.window?.isVisible == true else { return }
            view.evaluateJavaScript("window.cadabra && window.cadabra.update && window.cadabra.update(\(event()))")
        }
    }
}
