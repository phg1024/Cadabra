import Foundation
import Testing
@testable import Cadabra

/// Answers requests to agent.test from a handler, so the agent's requests can be checked without a network.
final class StubProtocol: URLProtocol {
    /// The body is JSON for a dictionary, or sent as it is (newline-delimited JSON) for a string.
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, Any))?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "agent.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let (status, answer) = Self.handler?(request, body) ?? (500, [String: Any]())
        let streamed = answer is String
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": streamed ? "application/x-ndjson; charset=utf-8" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: streamed ? Data((answer as! String).utf8) : try! JSONSerialization.data(withJSONObject: answer))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct AgentTests {
    init() { URLProtocol.registerClass(StubProtocol.self) }

    @Test func endpoints() {
        #expect(Agent.endpoint("http://localhost:8787", "text")?.absoluteString == "http://localhost:8787/text")
        #expect(Agent.endpoint(" http://192.168.1.20:8080/ ", "speech")?.path == "/speech")
        #expect(Agent.endpoint("localhost:8787", "text") == nil)
        #expect(Agent.endpoint("", "text") == nil)
    }

    @Test func asksWithTheTextAndTheConversation() async throws {
        StubProtocol.handler = { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/text")
            #expect(sent?["text"] as? String == "明天的会几点")
            #expect(request.value(forHTTPHeaderField: "X-Conversation-Id") == "c-abc")
            return (200, ["text": "明天的会几点", "reply": " 十点半。 ", "conversation_id": "c-abc"])
        }
        let (reply, id) = try await Agent.ask("明天的会几点", url: URL(string: "http://agent.test/text")!, conversation: "c-abc")
        #expect(reply == "十点半。")
        #expect(id == "c-abc")
    }

    @Test func anErrorFromTheAgentIsShownAsItSaysIt() async {
        StubProtocol.handler = { _, _ in (503, ["error": "正在处理其他请求，请稍后再试"]) }
        await #expect(throws: Agent.Failure.self) {
            _ = try await Agent.ask("你好", url: URL(string: "http://agent.test/text")!, conversation: nil)
        }
        do { _ = try await Agent.ask("你好", url: URL(string: "http://agent.test/text")!, conversation: nil) } catch {
            #expect(error.localizedDescription == "正在处理其他请求，请稍后再试")
        }
    }

    @Test func repliesAreReadASentenceOrTwoAtATime() {
        #expect(Speaker.chunks("关着呢。要我打开吗？") == ["关着呢。要我打开吗？"])
        let long = String(repeating: "这是一句挺长的话，", count: 5) + "结束。" + "下一句也很长很长很长很长很长很长很长很长很长很长很长很长。"
        let chunks = Speaker.chunks(long)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { !$0.isEmpty })
        #expect(Speaker.chunks("It's closed. Want me to open it?") == ["It's closed.Want me to open it?"])
    }

    @Test func aStreamingAgentSaysWhatItIsDoing() async throws {
        StubProtocol.handler = { request, _ in
            #expect(request.value(forHTTPHeaderField: "Accept")?.contains("application/x-ndjson") == true)
            return (200, """
                {"type": "activity", "state": "thinking"}
                {"type": "activity", "state": "researching"}
                {"type": "result", "text": "明天天气", "reply": "明天晴。", "conversation_id": "c-x"}

                """)
        }
        let seen = Seen()
        let (reply, id) = try await Agent.ask("明天天气", url: URL(string: "http://agent.test/text")!, conversation: nil) { seen.add($0) }
        #expect(reply == "明天晴。")
        #expect(id == "c-x")
        #expect(seen.states == ["thinking", "researching"])
    }

    @Test func aStreamedErrorIsAnError() async {
        StubProtocol.handler = { _, _ in (200, "{\"type\": \"activity\", \"state\": \"thinking\"}\n{\"type\": \"error\", \"error\": \"回复超时了\"}\n") }
        do {
            _ = try await Agent.ask("你好", url: URL(string: "http://agent.test/text")!, conversation: nil)
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription == "回复超时了")
        }
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ state: String) { lock.withLock { list.append(state) } }
    var states: [String] { lock.withLock { list } }
}

struct VisualPluginTests {
    func folder(_ manifest: String?, entry: String = "index.html") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest { try Data(manifest.utf8).write(to: dir.appendingPathComponent("plugin.json")) }
        try Data("<html></html>".utf8).write(to: dir.appendingPathComponent(entry))
        return dir
    }

    @Test func readsTheManifest() throws {
        let dir = try folder(##"{"name": "Echo", "height": 150, "background": "#0b141c", "foreground": "#e6f1f5"}"##)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plugin = try #require(VisualPlugin.load(dir))
        #expect(plugin.name == "Echo")
        #expect(plugin.height == 150)
        #expect(plugin.background != nil && plugin.foreground != nil)
        #expect(plugin.entry.lastPathComponent == "index.html")
    }

    @Test func thePageMustBeInsideTheFolder() throws {
        let dir = try folder(#"{"name": "Sneaky", "entry": "../../etc/hosts"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(VisualPlugin.load(dir) == nil)
        let none = try folder(nil)
        defer { try? FileManager.default.removeItem(at: none) }
        #expect(VisualPlugin.load(none) == nil)   // no plugin.json
    }

    @Test @MainActor func theEventSaysWhatIsHappening() throws {
        let event = VisualPlugin.event(phase: .waiting, activity: "coding", speaking: false, level: 1.7)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any])
        #expect(object["phase"] as? String == "waiting")
        #expect(object["activity"] as? String == "coding")
        #expect(object["level"] as? Double == 1)
        let quiet = VisualPlugin.event(phase: .listening, activity: nil, speaking: false, level: 0.25)
        #expect(quiet.contains("\"activity\":null"))
    }
}
