import Foundation
import Testing
@testable import Cadabra

struct UpdateCheckerTests {
    @Test(arguments: [
        ("1.2.0", "1.1.0", true), ("1.10.0", "1.9.2", true), ("1.2", "1.2.0", false), ("1.2.1", "1.2", true),
        ("1.1.0", "1.2.0", false), ("2.0.0", "2.0.0", false),
    ])
    func comparesVersions(candidate: String, current: String, newer: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: current) == newer)
    }

    @Test func readsGitHubRelease() throws {
        let json = #"{"tag_name": "v1.3.0", "html_url": "https://github.com/phg1024/Cadabra/releases/tag/v1.3.0", "body": null}"#
        let release = try JSONDecoder().decode(UpdateChecker.Release.self, from: Data(json.utf8))
        #expect(release.version == "1.3.0")
        #expect(release.page.absoluteString.hasSuffix("/v1.3.0"))
        #expect(release.notes.isEmpty)
    }
}
