import CoreGraphics
import Foundation

/// A modifier key used on its own as the dictation key.
enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, leftOption, rightCommand, rightControl, leftControl, fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: t("右 Option ⌥", "Right Option ⌥")
        case .leftOption: t("左 Option ⌥", "Left Option ⌥")
        case .rightCommand: t("右 Command ⌘", "Right Command ⌘")
        case .rightControl: t("右 Control ⌃", "Right Control ⌃")
        case .leftControl: t("左 Control ⌃", "Left Control ⌃")
        case .fn: "Fn 🌐"
        }
    }

    var keycap: String {
        switch self {
        case .rightOption: t("右⌥", "right ⌥")
        case .leftOption: t("左⌥", "left ⌥")
        case .rightCommand: t("右⌘", "right ⌘")
        case .rightControl: t("右⌃", "right ⌃")
        case .leftControl: t("左⌃", "left ⌃")
        case .fn: "fn"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .leftOption: 58
        case .rightCommand: 54
        case .rightControl: 62
        case .leftControl: 59
        case .fn: 63
        }
    }

    init?(keyCode: Int64) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// The device-dependent flag bit that is set only while this physical key is down
    /// (so holding the left Option does not count as the right one).
    var heldMask: UInt64 {
        switch self {
        case .rightOption: 0x40
        case .leftOption: 0x20
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .leftControl: 0x01
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    /// The ordinary modifier flag, for keyboards that don't report which side is down.
    var genericMask: UInt64 {
        switch self {
        case .rightOption, .leftOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightControl, .leftControl: CGEventFlags.maskControl.rawValue
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    static let deviceSideMasks: UInt64 = 0x207F

    func isHeld(in flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        if raw & heldMask != 0 { return true }
        return raw & Self.deviceSideMasks == 0 && raw & genericMask != 0
    }
}

enum LivePreview: String, CaseIterable, Identifiable {
    case off, bar, field

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: t("不显示", "Off")
        case .bar: t("在录音浮窗里", "In the recording bar")
        case .field: t("直接打进输入框", "Typed into the field")
        }
    }
}

enum TriggerMode: String, CaseIterable, Identifiable {
    case auto, pushToTalk, toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: t("自适应", "Adaptive")
        case .pushToTalk: t("按住说话", "Push to talk")
        case .toggle: t("单击开始 / 结束", "Press to start / stop")
        }
    }

    func detail(_ key: Hotkey) -> String {
        switch self {
        case .auto: t("按住 \(key.keycap) 说话、松开结束；或者短按一下开始，说完再按一下结束。", "Hold \(key.keycap) while you talk and release to finish, or tap it to start and tap again when you’re done.")
        case .pushToTalk: t("按住 \(key.keycap) 说话，松开就识别并输入。", "Hold \(key.keycap) while you talk; release to transcribe and insert.")
        case .toggle: t("按一下 \(key.keycap) 开始，再按一下结束。", "Press \(key.keycap) to start and again to finish.")
        }
    }
}

enum Language: String, CaseIterable, Identifiable {
    case auto, zh, en, yue, ja, ko

    var id: String { rawValue }

    var short: String {
        switch self {
        case .auto: t("自动", "Auto")
        case .zh: t("中文", "Chinese")
        case .en: t("英文", "English")
        case .yue: t("粤语", "Cantonese")
        case .ja: t("日语", "Japanese")
        case .ko: t("韩语", "Korean")
        }
    }

    var title: String {
        switch self {
        case .auto: t("自动识别（中英混说也行）", "Automatic (mixed Chinese and English works)")
        case .zh: t("中文（普通话）", "Chinese (Mandarin)")
        case .en: "English"
        case .yue: t("粤语", "Cantonese")
        case .ja: t("日本語", "日本語")
        case .ko: "한국어"
        }
    }
}

/// The language of Cadabra's own windows, menus and messages (not what it recognizes).
enum UILanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: t("跟随系统", "Same as system")
        case .zh: "简体中文"
        case .en: "English"
        }
    }
}

/// Picks the Chinese or English text for the current interface language.
func t(_ zh: String, _ en: String) -> String {
    Preferences.shared.usesEnglish ? en : zh
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey {
        didSet {
            defaults.set(hotkey.rawValue, forKey: "hotkey")
            if editHotkey == hotkey { editHotkey = nil }
            if agentHotkey == hotkey { agentHotkey = nil }
        }
    }
    /// The key for rewriting the selection by voice (`AppModel`); nil when turned off.
    @Published var editHotkey: Hotkey? {
        didSet {
            defaults.set(editHotkey?.rawValue ?? "off", forKey: "editHotkey")
            if editHotkey != nil, agentHotkey == editHotkey { agentHotkey = nil }
        }
    }
    /// The key for talking to the agent (`Agent`); nil when turned off, which it is until set.
    @Published var agentHotkey: Hotkey? {
        didSet {
            defaults.set(agentHotkey?.rawValue ?? "off", forKey: "agentHotkey")
            if agentHotkey != nil, editHotkey == agentHotkey { editHotkey = nil }
        }
    }
    /// The agent's address: an endpoint that takes POST /text {"text"} and answers {"reply"}.
    @Published var agentURL: String { didSet { defaults.set(agentURL, forKey: "agentURL") } }
    @Published var agentName: String { didSet { defaults.set(agentName, forKey: "agentName") } }
    /// Read the agent's replies aloud (its POST /speech).
    @Published var agentSpeaks: Bool { didSet { defaults.set(agentSpeaks, forKey: "agentSpeaks") } }
    @Published var trigger: TriggerMode { didSet { defaults.set(trigger.rawValue, forKey: "trigger") } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "language") } }
    /// An input device's UID, or empty for automatic (the default input, but not a Bluetooth headset's).
    @Published var microphone: String { didSet { defaults.set(microphone, forKey: "microphone") } }
    /// Names and terms the user says often, for the corrector.
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }

    /// The vocabulary one term at a time; it is kept as text separated by commas.
    var vocabularyTerms: [String] {
        get { Self.terms(in: vocabulary) }
        set { vocabulary = newValue.joined(separator: ", ") }
    }

    static func terms(in vocabulary: String) -> [String] {
        vocabulary.split(whereSeparator: { ",，、;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    @Published var correction: Bool { didSet { defaults.set(correction, forKey: "correction") } }
    /// Favour the vocabulary and learned English words while recognizing (`HotwordDecoder`).
    @Published var hotwords: Bool { didSet { defaults.set(hotwords, forKey: "hotwords") } }
    /// Read the text around the cursor (`FocusContext`) for the decoder and the correction model.
    @Published var useContext: Bool { didSet { defaults.set(useContext, forKey: "useContext") } }
    @Published var correctionModel: CorrectionModel { didSet { defaults.set(correctionModel.rawValue, forKey: "correctionModel") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var dropTrailingPeriod: Bool { didSet { defaults.set(dropTrailingPeriod, forKey: "dropTrailingPeriod") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    /// Show the words recognized so far while the user talks: typed into the field, or in the recording bar.
    @Published var livePreview: LivePreview { didSet { defaults.set(livePreview.rawValue, forKey: "livePreviewMode") } }
    /// Put the recording bar next to where the text goes rather than at the bottom of the screen.
    @Published var barNearText: Bool { didSet { defaults.set(barNearText, forKey: "barNearText") } }
    @Published var saveHistory: Bool { didSet { defaults.set(saveHistory, forKey: "saveHistory") } }
    @Published var saveRecordings: Bool { didSet { defaults.set(saveRecordings, forKey: "saveRecordings") } }
    /// Learn from the user fixing a dictation right after it was typed.
    @Published var learnFromEdits: Bool { didSet { defaults.set(learnFromEdits, forKey: "learnFromEdits") } }
    /// Keep each recording with its final text, for fine-tuning the speech model.
    @Published var collectTraining: Bool { didSet { defaults.set(collectTraining, forKey: "collectTraining") } }
    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    /// Look for a new release once a week. Off unless the user turns it on: otherwise the app only asks
    /// GitHub when they click Check for Updates.
    @Published var checkUpdatesWeekly: Bool { didSet { defaults.set(checkUpdatesWeekly, forKey: "checkUpdatesWeekly") } }
    /// A `Theme` id.
    @Published var theme: String { didSet { defaults.set(theme, forKey: "theme") } }
    @Published var uiLanguage: UILanguage {
        didSet {
            defaults.set(uiLanguage.rawValue, forKey: "uiLanguage")
            // System-provided text (the Settings window title, standard menus and alerts) follows
            // AppleLanguages, which macOS reads at launch.
            switch uiLanguage {
            case .system: defaults.removeObject(forKey: "AppleLanguages")
            case .zh: defaults.set(["zh-Hans"], forKey: "AppleLanguages")
            case .en: defaults.set(["en"], forKey: "AppleLanguages")
            }
        }
    }

    /// For --snapshot: renders a language without touching the saved setting.
    static var languageOverride: UILanguage?

    var usesEnglish: Bool {
        switch Self.languageOverride ?? uiLanguage {
        case .zh: false
        case .en: true
        case .system: !(Self.systemLanguages.first?.hasPrefix("zh") ?? false)
        }
    }

    var locale: Locale { Locale(identifier: usesEnglish ? "en" : "zh-Hans") }

    /// The user's languages from the system, ignoring our own AppleLanguages override.
    private static let systemLanguages: [String] =
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        ?? Locale.preferredLanguages

    init() {
        let key = Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        hotkey = key
        let edit = defaults.string(forKey: "editHotkey").map { Hotkey(rawValue: $0) } ?? .rightCommand
        let editKey = edit == key ? nil : edit
        editHotkey = editKey
        let agent = defaults.string(forKey: "agentHotkey").flatMap { Hotkey(rawValue: $0) }
        agentHotkey = agent == key || agent == editKey ? nil : agent
        agentURL = defaults.string(forKey: "agentURL") ?? ""
        agentName = defaults.string(forKey: "agentName") ?? "Agent"
        agentSpeaks = defaults.bool(forKey: "agentSpeaks")
        trigger = TriggerMode(rawValue: defaults.string(forKey: "trigger") ?? "") ?? .auto
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        microphone = defaults.string(forKey: "microphone") ?? ""
        vocabulary = defaults.string(forKey: "vocabulary") ?? ""
        correction = defaults.bool(forKey: "correction")
        hotwords = defaults.object(forKey: "hotwords") as? Bool ?? true
        useContext = defaults.object(forKey: "useContext") as? Bool ?? true
        correctionModel = CorrectionModel(rawValue: defaults.string(forKey: "correctionModel") ?? "") ?? .recommended
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        dropTrailingPeriod = defaults.object(forKey: "dropTrailingPeriod") as? Bool ?? false
        sounds = defaults.object(forKey: "sounds") as? Bool ?? true
        livePreview = LivePreview(rawValue: defaults.string(forKey: "livePreviewMode") ?? "") ?? .field
        barNearText = defaults.object(forKey: "barNearText") as? Bool ?? true
        saveHistory = defaults.object(forKey: "saveHistory") as? Bool ?? true
        saveRecordings = defaults.bool(forKey: "saveRecordings")
        learnFromEdits = defaults.object(forKey: "learnFromEdits") as? Bool ?? true
        collectTraining = defaults.bool(forKey: "collectTraining")
        onboarded = defaults.bool(forKey: "onboarded")
        theme = defaults.string(forKey: "theme") ?? Theme.cadabra.id
        checkUpdatesWeekly = defaults.bool(forKey: "checkUpdatesWeekly")
        uiLanguage = UILanguage(rawValue: defaults.string(forKey: "uiLanguage") ?? "") ?? .system
    }
}
