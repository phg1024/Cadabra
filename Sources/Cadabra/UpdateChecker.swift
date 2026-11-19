import Foundation
import os

private let log = Logger(subsystem: "com.peihongguo.Cadabra", category: "update")

/// Asks GitHub for the latest release. The only request the app makes besides the optional model
/// download, and only when the user clicks Check for Updates, or turned on the weekly check.
/// It never downloads or installs anything: a new version links to its release page.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let latestRelease = URL(string: "https://api.github.com/repos/phg1024/Cadabra/releases/latest")!
    private static let week: TimeInterval = 7 * 24 * 3600

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case failed(String)
    }

    struct Release: Equatable, Decodable {
        let version: String
        let page: URL
        let notes: String

        enum CodingKeys: String, CodingKey { case tag = "tag_name", page = "html_url", notes = "body" }

        init(version: String, page: URL, notes: String) {
            self.version = version; self.page = page; self.notes = notes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(String.self, forKey: .tag).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            page = try c.decode(URL.self, forKey: .page)
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        }
    }

    @Published private(set) var state = State.idle
    /// A newer release found by the weekly check that the user hasn't dismissed: shown in the menu.
    @Published private(set) var notice: Release?

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// 1.10.0 is newer than 1.9.2; missing parts count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func check() async {
        state = .checking
        do {
            var request = URLRequest(url: Self.latestRelease, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            defaults.set(Date(), forKey: "lastUpdateCheck")
            if Self.isNewer(release.version, than: Self.currentVersion) {
                state = .available(release)
                if defaults.string(forKey: "dismissedUpdate") != release.version { notice = release }
            } else {
                state = .upToDate
                notice = nil
            }
            log.notice("latest release \(release.version, privacy: .public), running \(Self.currentVersion, privacy: .public)")
        } catch {
            state = .failed(t("没连上 GitHub，稍后再试。", "Couldn't reach GitHub. Try again later."))
            log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "Not now" for this version: the menu stops mentioning it until a newer one comes out.
    func dismissNotice() {
        if let notice { defaults.set(notice.version, forKey: "dismissedUpdate") }
        notice = nil
    }

    /// The weekly check, if the user turned it on: at launch and then once a day it checks whether a
    /// week has passed since the last check.
    func scheduleWeekly(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        let due = { [weak self] in
            guard let self else { return }
            let last = self.defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
            if Date().timeIntervalSince(last) >= Self.week { Task { await self.check() } }
        }
        due()
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in MainActor.assumeIsolated { due() } }
    }
}
