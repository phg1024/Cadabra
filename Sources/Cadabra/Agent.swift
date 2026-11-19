import AppKit
import AVFoundation
import Security
import SwiftUI
import os

private let log = Logger(subsystem: "com.peihongguo.Cadabra", category: "agent")

/// An agent the user talks to with the agent key: an HTTP endpoint that takes `POST /text {"text"}` and
/// answers `{"reply"}`, and optionally `POST /speech {"text", "language"}` with a WAV (a small JSON API).
/// What it can do is up to the agent. Nothing is sent until the user confirms the words with Return.
@MainActor
final class Agent: ObservableObject {
    static let shared = Agent()

    enum Phase: Equatable {
        case confirm, waiting, reply(String), failed(String)
    }

    @Published var text = ""
    @Published private(set) var phase = Phase.confirm
    @Published private(set) var speaking = false

    private var panel: NSPanel?
    private var anchor: NSRect?
    private var request: Task<Void, Never>?
    private var conversation: (id: String, last: Date)?
    private let speaker = Speaker()
    private let prefs = Preferences.shared

    /// A conversation goes on while the next question comes within this long.
    static let followUp: TimeInterval = 5 * 60

    // MARK: Panel

    /// Shows the recognized words for the user to check (and edit) before they go anywhere.
    func present(_ words: String, near anchor: NSRect?) {
        cancelRequest()
        speaker.stop()
        text = words
        phase = .confirm
        self.anchor = anchor
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func send() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, phase == .confirm || isFailed else { return }
        guard let url = Self.endpoint(prefs.agentURL, "text") else {
            phase = .failed(t("先在 设置 › Agent 里填好地址", "Set the address in Settings › Agent first"))
            return
        }
        phase = .waiting
        if let last = conversation?.last, Date().timeIntervalSince(last) > Self.followUp { conversation = nil }
        let id = conversation?.id
        request = Task {
            do {
                let (reply, newID) = try await Self.ask(words, url: url, conversation: id)
                guard !Task.isCancelled else { return }
                conversation = newID.map { ($0, Date()) } ?? conversation
                phase = .reply(reply)
                place(panel)
                if prefs.agentSpeaks { speak(reply) }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func close() {
        cancelRequest()
        speaker.stop()
        speaking = false
        panel?.orderOut(nil)
    }

    func speak(_ reply: String) {
        guard let url = Self.endpoint(prefs.agentURL, "speech") else { return }
        speaking = true
        speaker.say(reply, url: url) { [weak self] in self?.speaking = false }
    }

    func stopSpeaking() {
        speaker.stop()
        speaking = false
    }

    /// For --snapshot.
    func preview(_ words: String, _ phase: Phase) {
        text = words
        self.phase = phase
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    private func cancelRequest() {
        request?.cancel()
        request = nil
    }

    private func makePanel() -> NSPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onResign = { [weak self] in
            // Clicking elsewhere puts it away, unless an answer is still on its way.
            guard let self, self.phase != .waiting else { return }
            self.close()
        }
        let host = NSHostingView(rootView: AgentView().environmentObject(self).environmentObject(prefs)
            .themed(Theme.named(prefs.theme)))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        return panel
    }

    /// Just above where the text was going, like the recording bar; otherwise high in the middle of the screen.
    private func place(_ panel: NSPanel?) {
        guard let panel else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        var origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
            if origin.y + size.height > frame.maxY { origin.y = anchor.minY - 10 - size.height }
        } else {
            origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62)
        }
        origin.x = min(max(origin.x, frame.minX + 8), frame.maxX - size.width - 8)
        origin.y = min(max(origin.y, frame.minY + 8), frame.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: Requests

    /// `base` + "/" + `path`, or nil when `base` isn't an http(s) address.
    nonisolated static func endpoint(_ base: String, _ path: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url.appendingPathComponent(path)
    }

    private nonisolated static func authorized(_ url: URL, method: String = "POST", timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if let token = Keychain.token(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// The reply, and the conversation it belongs to.
    nonisolated static func ask(_ words: String, url: URL, conversation: String?) async throws -> (String, String?) {
        var request = authorized(url, timeout: 180)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let conversation { request.setValue(conversation, forHTTPHeaderField: "X-Conversation-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": words])
        let (data, response) = try await URLSession.shared.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            log.error("agent answered \(status, privacy: .public)")
            throw Failure(object["error"] as? String ?? t("Agent 返回了错误（\(status)）", "The agent returned an error (\(status))"))
        }
        let reply = (object["reply"] as? String ?? object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw Failure(t("Agent 没有回复", "The agent didn't reply")) }
        let id = (object["conversation_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (reply, id)
    }

    /// For Settings: whether the address answers (GET /health) with this token.
    nonisolated static func check(_ base: String) async -> String {
        guard let url = endpoint(base, "health") else { return t("地址不对：要以 http:// 或 https:// 开头", "Not an address: it should start with http:// or https://") }
        do {
            let (_, response) = try await URLSession.shared.data(for: authorized(url, method: "GET", timeout: 8))
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return t("连上了", "Connected")
            case 401, 403: return t("连上了，但口令不对", "Reached it, but the token was refused")
            case let code: return t("连上了，但返回 \(code)", "Reached it, but it answered \(code)")
            }
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated static func speech(_ text: String, url: URL) async throws -> Data {
        var request = authorized(url, timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let language = text.unicodeScalars.contains { $0.properties.isIdeographic } ? "zh" : "en"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "language": language])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(t("朗读失败", "Couldn't read it aloud")) }
        return data
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// A panel that takes the keyboard without bringing Cadabra to the front, and says when it loses it.
private final class KeyPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// Reads a reply aloud a sentence or two at a time, fetching the next while one plays.
@MainActor
final class Speaker: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var queue: [Task<Data?, Never>] = []
    private var done: (() -> Void)?
    private var generation = 0

    func say(_ text: String, url: URL, done: @escaping () -> Void) {
        stop()
        self.done = done
        queue = Self.chunks(text).map { chunk in Task { try? await Agent.speech(chunk, url: url) } }
        playNext(generation)
    }

    func stop() {
        generation += 1
        queue.forEach { $0.cancel() }
        queue = []
        player?.stop()
        player = nil
    }

    private func playNext(_ current: Int) {
        guard current == generation else { return }
        guard !queue.isEmpty else { done?(); done = nil; return }
        let next = queue.removeFirst()
        Task {
            let data = await next.value
            guard current == generation else { return }
            guard let data, let player = try? AVAudioPlayer(data: data) else { return playNext(current) }
            self.player = player
            player.delegate = self
            player.play()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { playNext(generation) }
    }

    /// Sentences, joined up to about 60 characters (the speech model's comfortable length).
    nonisolated static func chunks(_ text: String, limit: Int = 60) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if "。！？!?；;\n".contains(ch) || (ch == "." && current.count > 1) {
                sentences.append(current); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sentences.append(current) }
        var out: [String] = []
        for s in sentences.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !s.isEmpty {
            if let last = out.last, last.count + s.count <= limit { out[out.count - 1] = last + s } else { out.append(s) }
        }
        return out
    }
}

/// The agent's token, in the login keychain; never shown or logged.
enum Keychain {
    private static let service = "com.peihongguo.Cadabra.agent"

    static func token() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "token", kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var hasToken: Bool { !(token() ?? "").isEmpty }

    static func setToken(_ token: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "token"]
        SecItemDelete(match as CFDictionary)
        guard !token.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct AgentView: View {
    @EnvironmentObject var agent: Agent
    @EnvironmentObject var prefs: Preferences
    @Environment(\.theme) private var theme
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(prefs.agentName).font(.system(size: 13, weight: .semibold))
                Spacer()
                if agent.phase == .waiting { ProgressView().controlSize(.small) }
            }
            switch agent.phase {
            case .confirm:
                TextField("", text: $agent.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($editing)
                    .onSubmit { agent.send() }
                hint(t("⏎ 发送 · esc 取消 · 可以先改字", "⏎ send · esc cancel · edit first if needed"))
            case .waiting:
                Text(agent.text).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(3)
                hint(t("正在等回复… esc 关闭", "Waiting for the reply… esc to close"))
            case .reply(let reply):
                Text(agent.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                ScrollView {
                    Text(reply).font(.system(size: 14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    hint(t("esc 关闭", "esc to close"))
                    Spacer()
                    Button { agent.speaking ? agent.stopSpeaking() : agent.speak(reply) } label: {
                        Image(systemName: agent.speaking ? "stop.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(.borderless)
                    .help(agent.speaking ? t("停止朗读", "Stop reading") : t("朗读", "Read aloud"))
                    Button { TextInjector.copy(reply) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(t("复制", "Copy"))
                }
            case .failed(let message):
                Text(agent.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Text(message).font(.system(size: 13)).foregroundStyle(.orange)
                hint(t("⏎ 重试 · esc 关闭", "⏎ retry · esc to close"))
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.background ?? Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .focusable(agent.phase != .confirm)
        .onKeyPress(.escape) { agent.close(); return .handled }
        .onKeyPress(.return) {
            guard case .failed = agent.phase else { return .ignored }
            agent.send()
            return .handled
        }
        .onAppear { editing = true }
        .onChange(of: agent.phase) { if agent.phase == .confirm { editing = true } }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
    }
}
