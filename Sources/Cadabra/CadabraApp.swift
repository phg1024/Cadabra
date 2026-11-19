import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        Rename.fromMyWisper()
        if CommandLineTools.run(CommandLine.arguments) { return }
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
        if files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) {
            do { try files.moveItem(at: old, to: new) } catch { NSLog("Cadabra: could not move \(old.path): \(error)") }
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "copiedMyWisperSettings") else { return }
        for (key, value) in defaults.persistentDomain(forName: "com.peihongguo.MyWisper") ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "copiedMyWisperSettings")
    }
}

struct CadabraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var prefs = Preferences.shared
    @StateObject private var history = HistoryStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(history)
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
                .id(prefs.uiLanguage)
        }

        Window(t("历史记录", "History"), id: "history") {
            HistoryWindow().environmentObject(history).environmentObject(model).id(prefs.uiLanguage)
        }
        .defaultSize(width: 520, height: 600)
        .defaultLaunchBehavior(.suppressed)

        Window(t("欢迎", "Welcome"), id: "welcome") {
            WelcomeView()
                .environmentObject(model)
                .environmentObject(prefs)
                .id(prefs.uiLanguage)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutDown() }
    }
}
