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

    /// Why a check failed, worded for the user.
    enum Failure: Error, Equatable {
        case offline, rateLimited, server(Int), unreadable

        var message: String {
            switch self {
            case .offline: t("没连上 GitHub，检查一下网络再试。", "Couldn't reach GitHub. Check your connection and try again.")
            case .rateLimited: t("GitHub 暂时限制了查询次数，过一会儿再试。", "GitHub is limiting requests for now. Try again in a while.")
            case .server(let status): t("GitHub 出错了（\(status)），稍后再试。", "GitHub returned an error (\(status)). Try again later.")
            case .unreadable: t("读不懂 GitHub 的回复，稍后再试。", "Couldn't read GitHub's reply. Try again later.")
            }
        }
    }

    /// Redirects to the latest release's page, ".../releases/tag/v1.4.3".
    static let latestReleasePage = URL(string: "https://github.com/phg1024/Cadabra/releases/latest")!

    /// The release a redirect landed on, from the tag at the end of its address.
    nonisolated static func release(fromPage page: URL) -> Release? {
        let parts = page.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "tag" else { return nil }
        let version = parts[parts.count - 1].trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard version.first?.isNumber == true else { return nil }
        return Release(version: version, page: page, notes: "")
    }

    /// The API gives the notes too, but allows 60 requests an hour per address, which a household
    /// behind one IP can use up; the release page has no such limit and says the version in its address.
    private func latest() async throws -> Release {
        do {
            return try await fromAPI()
        } catch {
            log.error("update check via the API failed: \(String(describing: error), privacy: .public); trying the release page")
            return try await fromPage(apiFailure: error as? Failure ?? .offline)
        }
    }

    private func fromAPI() async throws -> Release {
        var request = URLRequest(url: Self.latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard http.statusCode == 200 else {
            let limited = http.statusCode == 429
                || (http.statusCode == 403 && http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0")
            throw limited ? Failure.rateLimited : Failure.server(http.statusCode)
        }
        do { return try JSONDecoder().decode(Release.self, from: data) } catch { throw Failure.unreadable }
    }

    private func fromPage(apiFailure: Failure) async throws -> Release {
        var request = URLRequest(url: Self.latestReleasePage, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        let (_, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let page = http.url, let release = Self.release(fromPage: page) else {
            // The page didn't help either: the API's reason is the more telling one.
            throw apiFailure
        }
        return release
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await URLSession.shared.data(for: request) } catch { throw Failure.offline }
    }

    func check() async {
        state = .checking
        do {
            let release = try await latest()
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
            state = .failed((error as? Failure ?? .offline).message)
            log.error("update check failed: \(String(describing: error), privacy: .public)")
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
