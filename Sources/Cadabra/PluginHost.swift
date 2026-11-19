import AppKit
import WebKit
import os

private let log = Logger(subsystem: "com.peihongguo.Cadabra", category: "plugin")

/// Shows the agent plugin's page in a window near the text and tells it what the user says. The page
/// does everything else itself: it talks to its agent (only at the hosts its plugin.json declares; other
/// requests are blocked), and through `window.cadabra` (docs/plugins.md) keeps its own settings, resizes
/// and closes its window.
@MainActor
final class PluginHost: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let shared = PluginHost()

    private var plugin: AgentPlugin?
    private var panel: PluginPanel?
    private var view: WKWebView?
    private var loaded = false
    /// Events sent before the page finished loading, delivered once it has.
    private var queued: [String] = []
    private var anchor: NSRect?
    private var previous: NSRunningApplication?

    // MARK: From Cadabra

    /// The agent key went down: the plugin's window opens near the text.
    func listen(near anchor: NSRect?) {
        guard let plugin = AgentPlugin.selected else { return }
        if plugin != self.plugin { build(plugin) }
        self.anchor = anchor
        guard let panel else { return }
        place(panel, size: panel.frame.size == .zero ? NSSize(width: plugin.width, height: plugin.height) : panel.frame.size)
        // Cadabra comes to the front so the page gets the keyboard; the app before gets it back on close.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { previous = front }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if let view { panel.makeFirstResponder(view) }
        send(["type": "listen"])
    }

    /// What has been recognized so far.
    func partial(_ text: String) { send(["type": "partial", "text": text]) }

    /// The final words.
    func final(_ text: String) { send(["type": "final", "text": text]) }

    /// How loud the microphone is, 0…1, ten times a second while listening.
    func level(_ value: Float) { send(["type": "level", "value": Double(value)]) }

    /// The recording was cancelled or heard nothing: the window goes.
    func cancel() {
        send(["type": "cancel"])
        hide()
    }

    var isOpen: Bool { panel?.isVisible == true }

    // MARK: The window

    private func build(_ plugin: AgentPlugin) {
        panel?.orderOut(nil)
        self.plugin = plugin
        loaded = false
        queued = []

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // A page loaded from disk may call its agent (agents don't send CORS headers); which hosts it can
        // reach is up to the content rules below.
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "cadabra")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: plugin.width, height: plugin.height), configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        self.view = view

        let panel = PluginPanel(contentRect: NSRect(x: 0, y: 0, width: plugin.width, height: plugin.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        self.panel = panel

        // Nothing on the network but the plugin's own hosts. Without the rules the page isn't loaded at all.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "cadabra-plugin-\(plugin.id)", encodedContentRuleList: Self.rules(for: plugin)
        ) { list, error in
            MainActor.assumeIsolated {
                guard let list else { return log.error("plugin rules: \(error?.localizedDescription ?? "", privacy: .public)") }
                controller.add(list)
                view.loadFileURL(plugin.entry, allowingReadAccessTo: plugin.folder)
            }
        }
        log.notice("loaded plugin \(plugin.id, privacy: .public)")
    }

    func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        previous?.activate()
        previous = nil
    }

    /// Just above where the text was going, like the recording bar; otherwise high in the middle of the screen.
    /// A plugin that asks to be centered goes in the middle of the screen the text is on.
    private func place(_ panel: NSPanel, size: NSSize) {
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        var origin: NSPoint
        if plugin?.centered == true {
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        } else if let anchor {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
            if origin.y + size.height > frame.maxY { origin.y = anchor.minY - 10 - size.height }
        } else {
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62)
        }
        origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
        origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Talking to the page

    private func send(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event), let json = String(data: data, encoding: .utf8) else { return }
        guard loaded else { queued.append(json); return }
        view?.evaluateJavaScript("window.cadabra._receive(\(json))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        queued.forEach { view?.evaluateJavaScript("window.cadabra._receive(\($0))") }
        queued = []
        if panel?.isVisible == true { panel?.makeFirstResponder(webView) }
    }

    /// Content rules: block every http(s) and ws(s) request, then let the plugin's own hosts through.
    nonisolated static func rules(for plugin: AgentPlugin) -> String {
        var rules: [[String: Any]] = ["^https?://", "^wss?://"].map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        for origin in plugin.hosts {
            guard let url = URL(string: origin), let scheme = url.scheme, let host = url.host, let port = url.port else { continue }
            let socket = scheme == "https" ? "wss" : "ws"
            let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            for s in [scheme, socket] {
                for authority in standard ? ["\(host):\(port)", host] : ["\(host):\(port)"] {
                    rules.append(["trigger": ["url-filter": "^" + escape("\(s)://\(authority)") + "[/?#]"], "action": ["type": "ignore-previous-rules"]])
                    rules.append(["trigger": ["url-filter": "^" + escape("\(s)://\(authority)") + "$"], "action": ["type": "ignore-previous-rules"]])
                }
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func escape(_ text: String) -> String {
        text.reduce(into: "") { out, ch in
            if "\\.^$*+?()[]{}|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
    }

    /// What the page asks for: {op: close|resize|copy|get|set, …}.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String, let plugin else {
            return replyHandler(nil, "bad message")
        }
        switch op {
        case "close":
            hide()
            replyHandler(true, nil)
        case "resize":
            if let panel {
                let width = min(max((body["width"] as? NSNumber)?.doubleValue ?? panel.frame.width, 120), 900)
                let height = min(max((body["height"] as? NSNumber)?.doubleValue ?? panel.frame.height, 60), 900)
                place(panel, size: NSSize(width: width, height: height))
            }
            replyHandler(true, nil)
        case "copy":
            TextInjector.copy(body["text"] as? String ?? "")
            replyHandler(true, nil)
        case "get":
            replyHandler(PluginStorage.load(plugin.id)[body["key"] as? String ?? ""], nil)
        case "set":
            guard let key = body["key"] as? String else { return replyHandler(nil, "no key") }
            PluginStorage.set(plugin.id, key: key, value: body["value"])
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown op \(op)")
        }
    }

    /// `window.cadabra`, in the page before its own scripts run.
    static let bridge = """
        (() => {
          const listeners = {};
          const ask = (message) => window.webkit.messageHandlers.cadabra.postMessage(message);
          window.cadabra = {
            on(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
            _receive(event) { (listeners[event.type] || []).concat(listeners["*"] || []).forEach(fn => { try { fn(event); } catch (e) { console.error(e); } }); },
            close() { return ask({ op: "close" }); },
            resize(width, height) { return ask({ op: "resize", width, height }); },
            copy(text) { return ask({ op: "copy", text }); },
            storage: {
              get(key) { return ask({ op: "get", key }); },
              set(key, value) { return ask({ op: "set", key, value }); },
            },
          };
        })();
        """
}

/// A panel that takes the keyboard without bringing anything else along.
final class PluginPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Each plugin's own settings (a token, say), in Application Support/Cadabra/PluginData/<id>.json, owner-only.
enum PluginStorage {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Cadabra/PluginData")

    static func load(_ plugin: String, in directory: URL = directory) -> [String: Any] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(plugin).json")) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func set(_ plugin: String, key: String, value: Any?, in directory: URL = directory) {
        var values = load(plugin, in: directory)
        if let value, !(value is NSNull) { values[key] = value } else { values.removeValue(forKey: key) }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = directory.appendingPathComponent("\(plugin).json")
        Storage.queue.sync { Storage.write(data, to: url) }
    }
}
