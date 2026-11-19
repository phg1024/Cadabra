import AppKit
import SwiftUI
import WebKit

/// A look for the agent's panel, made by someone else: a folder in
/// ~/Library/Application Support/Cadabra/Plugins/ with a `plugin.json` and a web page. The page is shown
/// at the top of the panel and told what is happening many times a second (`window.cadabra.update`, see
/// docs/plugins.md); it draws whatever it likes. It may read only its own folder and nothing from the
/// network.
struct VisualPlugin: Identifiable, Equatable {
    let id: String
    let name: String
    let folder: URL
    let entry: URL
    /// The height it takes at the top of the panel, in points.
    let height: CGFloat
    /// Colours for the whole panel, so it looks of a piece with the plugin; nil keeps the theme's.
    let background: Color?
    let foreground: Color?

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cadabra/Plugins")

    static func installed(in directory: URL = directory) -> [VisualPlugin] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap(load).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func named(_ id: String) -> VisualPlugin? {
        id.isEmpty ? nil : load(directory.appendingPathComponent(id))
    }

    /// `plugin.json`: {"name": "Echo", "entry": "index.html", "height": 140, "background": "#0b141c", "foreground": "#e6f1f5"}.
    static func load(_ folder: URL) -> VisualPlugin? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("plugin.json")),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let entry = folder.appendingPathComponent(manifest["entry"] as? String ?? "index.html").standardizedFileURL
        // The page has to be inside the plugin's own folder.
        guard entry.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: entry.path) else { return nil }
        let height = (manifest["height"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 120
        return VisualPlugin(id: folder.lastPathComponent, name: manifest["name"] as? String ?? folder.lastPathComponent,
                            folder: folder, entry: entry, height: min(max(height, 40), 400),
                            background: (manifest["background"] as? String).flatMap(Color.init(hex:)),
                            foreground: (manifest["foreground"] as? String).flatMap(Color.init(hex:)))
    }

    /// The event a plugin gets: what the panel is doing, what the agent says it is doing, how loud.
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

/// The plugin's page, fed an event `perSecond` times while it is on screen.
struct PluginView: NSViewRepresentable {
    let plugin: VisualPlugin
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
            view.loadFileURL(plugin.entry, allowingReadAccessTo: plugin.folder)
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
