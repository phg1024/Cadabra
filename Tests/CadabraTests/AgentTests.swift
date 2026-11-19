import Foundation
import Testing
import WebKit
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

struct PluginHostTests {
    func plugin(_ hosts: [String]) -> AgentPlugin {
        AgentPlugin(id: "test", name: "Test", folder: URL(fileURLWithPath: "/tmp"), entry: URL(fileURLWithPath: "/tmp/index.html"),
                    width: 440, height: 180, hosts: hosts.compactMap(AgentPlugin.origin))
    }

    /// The rules have to compile: when they don't, the page isn't loaded at all (and before, a rule that
    /// didn't compile silently let everything through).
    @Test @MainActor func theRulesCompile() async throws {
        let rules = PluginHost.rules(for: plugin(["http://localhost:8787", "https://agent.example"]))
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "cadabra-test-\(UUID().uuidString)",
                                                                    encodedContentRuleList: rules) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
        #expect(list != nil)
    }

    @Test func blockEverythingThenLetItsHostsThrough() throws {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(PluginHost.rules(for: plugin(["http://localhost:8787"])).utf8)) as? [[String: Any]])
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        let actions = rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        #expect(Array(actions.prefix(2)) == ["block", "block"])
        #expect(actions.dropFirst(2).allSatisfy { $0 == "ignore-previous-rules" })
        #expect(filters.contains(#"^http://localhost:8787[/?#]"#))
        #expect(filters.contains(#"^ws://localhost:8787[/?#]"#))
        #expect(!filters.contains { $0.contains("8788") })
        let none = try #require(try JSONSerialization.jsonObject(with: Data(PluginHost.rules(for: plugin([])).utf8)) as? [Any])
        #expect(none.count == 2)   // nothing declared: nothing gets out
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ state: String) { lock.withLock { list.append(state) } }
    var states: [String] { lock.withLock { list } }
}

struct AgentPluginTests {
    func folder(_ manifest: String?, page: String? = "index.html") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest { try Data(manifest.utf8).write(to: dir.appendingPathComponent("plugin.json")) }
        if let page { try Data("<html></html>".utf8).write(to: dir.appendingPathComponent(page)) }
        return dir
    }

    @Test func theExamplePluginLoads() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("examples/echo-agent/plugin")
        let plugin = try #require(AgentPlugin.load(folder))
        #expect(plugin.allows(URL(string: "http://localhost:8787/text")!))
    }

    @Test func readsTheManifest() throws {
        let dir = try folder(#"{"name": "Echo", "width": 480, "height": 200, "hosts": ["http://localhost:8787", "https://agent.example"]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plugin = try #require(AgentPlugin.load(dir))
        #expect(plugin.name == "Echo")
        #expect(plugin.width == 480 && plugin.height == 200)
        #expect(plugin.hosts == ["http://localhost:8787", "https://agent.example:443"])
    }

    @Test func offersThePagesSettings() throws {
        let dir = try folder(#"{"name": "Echo", "settings": true}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try #require(AgentPlugin.load(dir)).settings)
        let plain = try folder(#"{"name": "Echo"}"#)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(try #require(AgentPlugin.load(plain)).settings == false)
    }

    @Test func whereTheWindowGoes() throws {
        let dir = try folder(#"{"name": "Echo", "position": "center"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try #require(AgentPlugin.load(dir)).centered)
        let plain = try folder(#"{"name": "Echo"}"#)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(try #require(AgentPlugin.load(plain)).centered == false)
    }

    @Test func onlyItsOwnHosts() throws {
        let dir = try folder(#"{"name": "Echo", "hosts": ["http://localhost:8787"]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plugin = try #require(AgentPlugin.load(dir))
        #expect(plugin.allows(URL(string: "http://localhost:8787/text")!))
        #expect(plugin.allows(URL(string: "http://LOCALHOST:8787/speech")!))
        #expect(!plugin.allows(URL(string: "http://localhost:8788/text")!))
        #expect(!plugin.allows(URL(string: "https://localhost:8787/text")!))
        #expect(!plugin.allows(URL(string: "http://evil.example/text")!))
        #expect(!plugin.allows(URL(string: "file:///etc/hosts")!))
    }

    @Test func thePageMustBeInsideTheFolder() throws {
        let sneaky = try folder(#"{"name": "Sneaky", "entry": "../../etc/hosts"}"#)
        defer { try? FileManager.default.removeItem(at: sneaky) }
        #expect(AgentPlugin.load(sneaky) == nil)
        let none = try folder(nil)
        defer { try? FileManager.default.removeItem(at: none) }
        #expect(AgentPlugin.load(none) == nil)
    }

    @Test func eachPluginKeepsItsOwnSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugindata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        PluginStorage.set("echo", key: "token", value: "abc", in: dir)
        PluginStorage.set("other", key: "token", value: "xyz", in: dir)
        #expect(PluginStorage.load("echo", in: dir)["token"] as? String == "abc")
        PluginStorage.set("echo", key: "token", value: nil, in: dir)
        #expect(PluginStorage.load("echo", in: dir)["token"] == nil)
        #expect(PluginStorage.load("other", in: dir)["token"] as? String == "xyz")
        let permissions = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("echo.json").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
