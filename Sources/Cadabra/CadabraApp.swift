import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        // Not in the command-line modes: build.sh runs one while the old app may still be writing.
        if CommandLineTools.run(CommandLine.arguments) { return }
        Rename.fromMyWisper()
        CadabraApp.main()
    }
}

/// The app was called MyWisper (com.peihongguo.MyWisper) until 1.2. Its folder in Application Support
/// (models, recordings, training data, learned fixes, history) is moved over, and its settings copied,
/// the first time Cadabra starts.
enum Rename {
    static func fromMyWisper() {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("MyWisper"), new = support.appendingPathComponent("Cadabra")
        // The old app, if still installed and running (say as a login item), would fight over the shortcut
        // and keep writing to its own folder: quit it.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.peihongguo.MyWisper")
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if files.fileExists(atPath: old.path) {
            if !files.fileExists(atPath: new.path) {
                do { try files.moveItem(at: old, to: new) } catch { NSLog("Cadabra: could not move \(old.path): \(error)") }
            } else {
                merge(old, into: new)   // both: say a development build of Cadabra ran first
            }
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "copiedMyWisperSettings") else { return }
        for (key, value) in defaults.persistentDomain(forName: "com.peihongguo.MyWisper") ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "copiedMyWisperSettings")
    }

    /// Moves what only the old folder has; of a file in both, the newer stays and the other is kept
    /// next to it as `<name>.older-<date>`. Nothing is deleted.
    static func merge(_ old: URL, into new: URL) {
        let files = FileManager.default
        let stamp = Date().formatted(.iso8601.year().month().day())
        for name in (try? files.contentsOfDirectory(atPath: old.path)) ?? [] {
            let from = old.appendingPathComponent(name), to = new.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            files.fileExists(atPath: from.path, isDirectory: &isFolder)
            if !files.fileExists(atPath: to.path) {
                try? files.moveItem(at: from, to: to)
            } else if isFolder.boolValue {
                merge(from, into: to)
            } else if modified(from) > modified(to) {
                try? files.moveItem(at: to, to: new.appendingPathComponent("\(name).older-\(stamp)"))
                try? files.moveItem(at: from, to: to)
            }
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Once: if MyWisper.app is still installed, say that it can go (it would fight over the shortcut,
    /// and may still be a login item) and that Open at Login needs turning on again for Cadabra.
    @MainActor
    static func mentionOldApp() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "mentionedOldApp") else { return }
        let places = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/MyWisper.app"),
                      URL(fileURLWithPath: "/Applications/MyWisper.app")]
        guard let app = places.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        defaults.set(true, forKey: "mentionedOldApp")
        let alert = NSAlert()
        alert.messageText = t("MyWisper 改名叫 Cadabra 了", "MyWisper is now Cadabra")
        alert.informativeText = t("你的设置、历史记录、学到的词和模型都已经搬过来了。旧的 MyWisper.app 还在 \(app.deletingLastPathComponent().path)，可以把它移到废纸篓；如果它设了登录时启动，删掉后就不会再启动了。Cadabra 的「登录时自动启动」请在 设置 › 通用 里重新打开。",
                                  "Your settings, history, learned words and models have moved over. The old MyWisper.app is still in \(app.deletingLastPathComponent().path); you can move it to the Trash, which also stops it opening at login. Turn on Open at Login for Cadabra again in Settings › General.")
        alert.addButton(withTitle: t("在访达中显示", "Show in Finder"))
        alert.addButton(withTitle: t("好", "OK"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([app]) }
    }
}

struct CadabraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var prefs = Preferences.shared
    @StateObject private var history = HistoryStore.shared

    private var theme: Theme { Theme.named(prefs.theme) }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(history)
                .themed(theme)
                .id(prefs.uiLanguage)   // rebuild every view, so all text switches language at once
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(history)
                .themed(theme)
                .id(prefs.uiLanguage)
        }

        Window(t("历史记录", "History"), id: "history") {
            HistoryWindow().environmentObject(history).environmentObject(model).themedBackground(theme).themed(theme).id(prefs.uiLanguage)
        }
        .defaultSize(width: 520, height: 600)
        .defaultLaunchBehavior(.suppressed)

        Window(t("欢迎", "Welcome"), id: "welcome") {
            WelcomeView()
                .environmentObject(model)
                .environmentObject(prefs)
                .themedBackground(theme)
                .themed(theme)
                .id(prefs.uiLanguage)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.launch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Rename.mentionOldApp() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutDown() }
    }
}
