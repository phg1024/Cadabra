import Foundation
import Testing
@testable import Cadabra

/// Answers requests to agent.test from a handler, so the agent's requests can be checked without a network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) -> (Int, [String: Any]))?

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
        let (status, json) = Self.handler?(request, body) ?? (500, [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
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
}
