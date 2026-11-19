import SwiftUI

struct SettingsView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label(t("通用", "General"), systemImage: "gearshape") }
            VocabularySettings().tabItem { Label(t("词汇", "Vocabulary"), systemImage: "character.book.closed") }
            PermissionSettings().tabItem { Label(t("权限", "Permissions"), systemImage: "lock.shield") }
            AboutSettings().tabItem { Label(t("关于", "About"), systemImage: "info.circle") }
        }
        .frame(width: 520)
        .themedBackground(theme)
    }
}

/// The record button and the recording bar in a theme, under the theme picker.
private struct ThemePreview: View {
    var theme: Theme
    private let levels: [Float] = [0.2, 0.45, 0.8, 0.5, 0.95, 0.6, 0.3, 0.7, 0.9, 0.4, 0.25, 0.65, 0.85, 0.5, 0.3, 0.55]

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                AppGlyph(size: 22)
                Image(systemName: "mic.fill").font(.system(size: 12, weight: .semibold))
                Text(t("开始听写", "Start dictation")).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(theme.onAccent)
            .padding(.leading, 4).padding(.trailing, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.gradient))
            HStack(spacing: 8) {
                PulsingDot(color: theme.dot).frame(width: 8, height: 8).scaleEffect(0.8)
                Waveform(levels: levels, colors: theme.wave).frame(width: 70, height: 16)
                Text("0:04").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(theme.barText)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(theme.bar))
            .overlay(Capsule().strokeBorder(theme.barText.opacity(0.14), lineWidth: 1))
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.background ?? Color(nsColor: .windowBackgroundColor)))
        .environment(\.theme, theme)
        .fontDesign(theme.serif ? .serif : nil)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var history: HistoryStore
    @ObservedObject private var training = TrainingData.shared
    @State private var confirmClear = false
    @State private var confirmClearTraining = false

    var body: some View {
        Form {
            Section {
                Picker("界面语言 / Language", selection: $prefs.uiLanguage) {
                    ForEach(UILanguage.allCases) { Text($0.title).tag($0) }
                }
                Picker(t("主题", "Theme"), selection: $prefs.theme) {
                    ForEach(Theme.all) { theme in
                        Text(theme.title).tag(theme.id)
                    }
                }
                ThemePreview(theme: Theme.named(prefs.theme))
            }

            Section {
                Picker(t("快捷键", "Shortcut"), selection: $prefs.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent {
                    if model.capturingHotkey {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(t("请按一下要用的键…", "Press the key you want…")).foregroundStyle(.secondary)
                            Button(t("取消", "Cancel")) { model.endHotkeyCapture() }.controlSize(.small)
                        }
                    } else {
                        Button(t("按键设置…", "Record Key…")) { model.beginHotkeyCapture() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("直接按要用的键", "Set by pressing the key"))
                        if let note = model.captureNote {
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(t("用法", "Mode"), selection: $prefs.trigger) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(t("快捷键", "Shortcut"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prefs.trigger.detail(prefs.hotkey))
                    Text(t("刚按下快捷键就又按了别的键（比如 ⌃C、⌥E），算作组合键，不录音。录音时或识别中按 esc 取消。", "Pressing another key right after the shortcut (like ⌃C or ⌥E) counts as a key combination, not a dictation. Press esc to cancel while recording or recognizing."))
                    if prefs.hotkey == .fn {
                        Text(t("Fn 键默认会弹出表情或切换输入法：请在 系统设置 › 键盘 里把「按下 🌐 键时」改成「无操作」。", "By default Fn opens the emoji picker or switches input sources: set System Settings › Keyboard › “Press 🌐 key to” to “Do Nothing”."))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker(t("麦克风", "Microphone"), selection: $prefs.microphone) {
                    Text(t("自动（不用蓝牙耳机的麦克风）", "Automatic (not a Bluetooth headset’s)")).tag("")
                    let microphones = Microphones.all().filter { !$0.isVirtual }
                    ForEach(microphones) { Text($0.name).tag($0.uid) }
                    if !prefs.microphone.isEmpty, !microphones.contains(where: { $0.uid == prefs.microphone }) {
                        Text(t("（未连接的设备）", "(Not connected)")).tag(prefs.microphone)
                    }
                }
                Picker(t("语言提示", "Language hint"), selection: $prefs.language) {
                    ForEach(Language.allCases) { Text($0.title).tag($0) }
                }
                Toggle(t("去掉句末的句号", "Drop the final period"), isOn: $prefs.dropTrailingPeriod)
            } header: {
                Text(t("识别", "Recognition"))
            } footer: {
                Text(t("麦克风选「自动」时，戴着 AirPods 之类的蓝牙耳机也用电脑或摄像头的麦克风录音：用耳机的麦克风要先把耳机切到通话模式，开始录音会慢好几秒，耳机里的声音也会变闷。SenseVoice 会自己判断说的是哪种语言，语言提示多数时候选「自动」就好。常用的名字和术语在「词汇」页里填。", "With the microphone on Automatic, a Bluetooth headset such as AirPods only plays sound and the Mac’s or camera’s microphone records: using the headset’s microphone switches it to call mode, which delays the start by seconds and muffles what it plays. SenseVoice detects the language by itself; Auto is right most of the time. Names and terms you often say go in the Vocabulary tab."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(t("用本机大模型纠正听错的词", "Fix misheard words with a local language model"), isOn: $prefs.correction)
                if prefs.correction {
                    Picker(t("模型", "Model"), selection: $prefs.correctionModel) {
                        ForEach(CorrectionModel.allCases) { Text($0.title).tag($0) }
                    }
                    CorrectionStatus(choice: prefs.correctionModel)
                }
            } header: {
                Text(t("纠错（实验）", "Correction (experimental)"))
            } footer: {
                Text(t("识别完用一个 Qwen 模型按上下文改正同音字和专有名词（参考「词汇」页里的词），每句多花大约半秒。模型要先下载一次（来自 Hugging Face），之后纠错完全在这台 Mac 上运行，不联网。", "After recognition, a Qwen model fixes sound-alike words and names from context (using the Vocabulary tab). Adds about half a second. The model is downloaded once from Hugging Face; after that, correction runs entirely on this Mac with no network access."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle(isOn: $prefs.learnFromEdits) {
                    Text(t("从我的修改中学习", "Learn from my fixes"))
                    Text(t("文字输入后两分钟内，如果你在原处改了某个词，Cadabra 会记住。学到的词在「词汇」页里。", "If you fix a word in the typed text within two minutes, Cadabra remembers it. What it learned is in the Vocabulary tab."))
                }
                Toggle(isOn: $prefs.collectTraining) {
                    Text(t("保存录音，用来训练语音模型", "Keep recordings to train the speech model"))
                    Text(t("每次听写的录音和你最后确认的文字存在本机，以后用来让模型适应你的声音。每分钟约 2 MB。", "Each dictation’s audio and the text you settled on stay on this Mac, to adapt the model to your voice later. About 2 MB a minute."))
                }
                if prefs.collectTraining || !training.samples.isEmpty {
                    LabeledContent(t("已有 \(training.samples.count) 段，\(Int(training.totalDuration / 60)) 分钟", "\(training.samples.count) recordings, \(Int(training.totalDuration / 60)) min")) {
                        HStack {
                            Button(t("在访达中显示", "Show in Finder")) {
                                try? FileManager.default.createDirectory(at: training.directory, withIntermediateDirectories: true,
                                                                         attributes: [.posixPermissions: 0o700])
                                NSWorkspace.shared.activateFileViewerSelecting([training.directory])
                            }
                            Button(t("清空…", "Clear…")) { confirmClearTraining = true }.disabled(training.samples.isEmpty)
                        }
                    }
                }
            } header: {
                Text(t("学习", "Learning"))
            } footer: {
                Text(t("也可以在 全部记录 里右键一条 › 改正。学习只记改动的词，不保存周围的文字；输入密码的地方不会读。训练录音只在你打开时才保存，删掉一条历史记录会连带删掉它的录音。", "You can also right-click an entry in All history › Correct. Learning keeps only the changed words, never the text around them; password fields are never read. Training recordings are kept only when turned on; deleting a history entry deletes its recording too."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section(t("输入", "Input")) {
                Toggle(t("识别完自动粘贴到光标处", "Paste at the cursor when done"), isOn: $prefs.autoPaste)
                Toggle(t("粘贴后恢复原来的剪贴板", "Restore the clipboard after pasting"), isOn: $prefs.restoreClipboard)
                    .disabled(!prefs.autoPaste)
            }

            Section(t("其他", "Other")) {
                Toggle(t("提示音", "Sounds"), isOn: $prefs.sounds)
                Toggle(t("登录时自动启动", "Open at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                Toggle(t("保存历史记录", "Keep history"), isOn: $prefs.saveHistory)
                Toggle(isOn: $prefs.saveRecordings) {
                    Text(t("保存录音", "Save recordings"))
                    Text(t("用来排查识别问题，每次都存，不会自动清理。只为训练的话不用开：上面的「保存录音，用来训练语音模型」已经存了录音。只存在本机。", "For tracking down recognition problems; every dictation is kept until you delete it. Not needed for training: “Keep recordings to train the speech model” above already keeps the audio. Kept on this Mac only."))
                }
                if prefs.saveRecordings {
                    HStack {
                        Text(t("录音", "Recordings")).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("在访达中显示", "Show in Finder")) {
                            try? FileManager.default.createDirectory(at: RecordingArchive.directory, withIntermediateDirectories: true,
                                                                     attributes: [.posixPermissions: 0o700])
                            NSWorkspace.shared.activateFileViewerSelecting([RecordingArchive.directory])
                        }
                    }
                }
                HStack {
                    Text(t("历史记录", "History")).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("清空…", "Clear…")) { confirmClear = true }
                        .disabled(history.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .confirmationDialog(t("删除全部 \(training.samples.count) 段训练录音？", "Delete all \(training.samples.count) training recordings?"), isPresented: $confirmClearTraining) {
            Button(t("删除", "Delete"), role: .destructive) { training.clear() }
        } message: {
            Text(t("这一步不能撤销。", "This can’t be undone."))
        }
        .confirmationDialog(t("清空全部 \(history.entries.count) 条历史记录？", "Clear all \(history.entries.count) history entries?"), isPresented: $confirmClear) {
            Button(t("清空", "Clear"), role: .destructive) { history.clear() }
        } message: {
            Text(t("这一步不能撤销。", "This can’t be undone."))
        }
    }
}

/// Download prompt, progress or readiness of the correction model.
private struct CorrectionStatus: View {
    let choice: CorrectionModel
    @ObservedObject private var corrector = Corrector.shared

    var body: some View {
        switch corrector.state {
        case .off, .loading:
            HStack {
                Text(t("正在加载模型…", "Loading the model…")).foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            }
        case .needsDownload:
            HStack(alignment: .firstTextBaseline) {
                Text(t("需要下载 \(choice.fileName)（\(ByteCountFormatter.string(fromByteCount: choice.bytes, countStyle: .file))，来自 Hugging Face）", "Needs \(choice.fileName) (\(ByteCountFormatter.string(fromByteCount: choice.bytes, countStyle: .file)), from Hugging Face)"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(t("下载", "Download")) { corrector.startDownload(choice) }
            }
        case .downloading(let fraction):
            HStack {
                ProgressView(value: fraction) {
                    Text(t("正在下载 \(Int(fraction * 100))%", "Downloading \(Int(fraction * 100))%")).foregroundStyle(.secondary)
                }
                Button(t("取消", "Cancel")) { corrector.cancelDownload() }
            }
        case .ready:
            Label(t("模型已就绪", "Model ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .resting:
            Label(t("一段时间没用，已暂时卸载以腾出内存；开始录音时会自动加载", "Unloaded after a while unused to free memory; loads again when you start recording"),
                  systemImage: "moon.zzz").foregroundStyle(.secondary)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline) {
                Text(message).foregroundStyle(.orange)
                Spacer()
                Button(t("重试", "Retry")) {
                    if choice.isDownloaded { corrector.configure(enabled: true, model: choice) } else { corrector.startDownload(choice) }
                }
            }
        }
    }
}

private struct PermissionSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                PermissionRow(title: t("麦克风", "Microphone"), detail: t("录下你说的话。音频只在本机识别，不会上传。", "Records what you say. Audio is recognized on this Mac and never uploaded."),
                              granted: model.micStatus == .authorized) { model.requestMicrophone() }
                PermissionRow(title: t("辅助功能", "Accessibility"), detail: t("监听快捷键（全局），并模拟 ⌘V 把文字粘贴到光标处。", "Listens for the shortcut in every app and sends ⌘V to paste text at the cursor."),
                              granted: model.accessibilityGranted) { model.requestAccessibility() }
            } footer: {
                Text(t("重新编译过 Cadabra 后，系统会把它当成新程序：到 系统设置 › 隐私与安全性 › 辅助功能 里用「−」删掉旧的 Cadabra，再点这里的「授权」重新添加。", "If the shortcut stops working after an update, remove Cadabra with “−” in System Settings › Privacy & Security › Accessibility, then click Grant here to add it again."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }
}

/// Opened in the browser only when clicked; the app itself never connects anywhere.
enum Links {
    static let repository = URL(string: "https://github.com/phg1024/Cadabra")!
    static let sponsors = URL(string: "https://github.com/sponsors/phg1024")!
    static let coffee = URL(string: "https://buymeacoffee.com/phg1024")!
}

struct AboutSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 14) {
            AppGlyph(size: 72)
            VStack(spacing: 4) {
                Text("Cadabra").font(.system(size: 20, weight: .semibold))
                Text(t("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")", "Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(t("本地语音输入。识别模型是 SenseVoice-Small（int8，sherpa-onnx），音频和文字都不离开这台 Mac。", "On-device dictation with SenseVoice-Small (int8, sherpa-onnx). Audio and text never leave this Mac."))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text(t("模型", "Model")).foregroundStyle(.secondary)
                    Text(modelText).textSelection(.enabled)
                }
                GridRow {
                    Text(t("平均识别耗时", "Average recognition time")).foregroundStyle(.secondary)
                    Text(history.recentLatency.map { String(format: t("%.0f 毫秒（最近 %d 次）", "%.0f ms (last %d)"), $0 * 1000, min(20, history.entries.count)) } ?? t("还没有数据", "No data yet"))
                }
            }
            .font(.system(size: 12))
            updateRow
            HStack(spacing: 10) {
                Link(destination: Links.repository) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Links.sponsors) {
                    Label { Text("Sponsor") } icon: { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                }
                Link(destination: Links.coffee) {
                    Label("Buy Me a Coffee", systemImage: "cup.and.saucer.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text(t("Cadabra 免费开源。觉得好用的话，欢迎请我喝杯咖啡。", "Cadabra is free and open source. If it helps you, a coffee is always appreciated."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(t("SenseVoice-Small 模型来自 FunAudioLLM（阿里巴巴通义实验室），遵循 FunASR 模型开源协议；sherpa-onnx（Apache-2.0）、ONNX Runtime（MIT）、llama.cpp（MIT）。详见 App 包内的 THIRD_PARTY_NOTICES.md。", "SenseVoice-Small by FunAudioLLM (Tongyi Lab, Alibaba Group), under the FunASR Model Open Source License; sherpa-onnx (Apache-2.0), ONNX Runtime (MIT), llama.cpp (MIT). See THIRD_PARTY_NOTICES.md inside the app."))
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 400)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .frame(height: 500)
    }

    private var updateRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                switch updates.state {
                case .checking:
                    ProgressView().controlSize(.small)
                    Text(t("正在检查…", "Checking…")).foregroundStyle(.secondary)
                case .available(let release):
                    Text(t("有新版本 \(release.version)", "Version \(release.version) is available"))
                    Link(t("下载", "Download"), destination: release.page).buttonStyle(.borderedProminent).controlSize(.small)
                default:
                    Button(t("检查更新", "Check for Updates")) { Task { await updates.check() } }.controlSize(.small)
                    if updates.state == .upToDate {
                        Label(t("已是最新版本", "You're up to date"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if case .failed(let message) = updates.state {
                        Text(message).foregroundStyle(.orange)
                    }
                }
            }
            .font(.system(size: 12))
            Toggle(t("每周自动检查一次", "Check automatically once a week"), isOn: $prefs.checkUpdatesWeekly)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help(t("关着的时候，只有点「检查更新」才会访问 GitHub。", "While off, the app only contacts GitHub when you click Check for Updates."))
        }
    }

    private var modelText: String {
        switch model.modelState {
        case .loading: t("加载中…", "Loading…")
        case .failed(let message): message
        case .ready: ASREngine.defaultModelDirectory()?.lastPathComponent == "model" ? t("随 App 打包", "Bundled with the app") : (ASREngine.defaultModelDirectory()?.path ?? "")
        }
    }
}

struct HistoryWindow: View {
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var editing: HistoryEntry?

    var body: some View {
        let shown = query.isEmpty ? history.entries : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
        Group {
            if shown.isEmpty {
                ContentUnavailableView(query.isEmpty ? t("还没有记录", "No history yet") : t("没有找到", "No matches"),
                                       systemImage: query.isEmpty ? "text.bubble" : "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { entry in
                            HistoryRow(entry: entry, compact: false, onDelete: { model.delete(entry) },
                                       onEdit: { editing = entry })
                        }
                    }
                    .padding(10)
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: t("搜索", "Search"))
        .frame(minWidth: 420, minHeight: 360)
        .sheet(item: $editing) { entry in
            CorrectEntrySheet(entry: entry) { model.edit(entry, to: $0) }
        }
    }
}

/// Fixing a dictation by hand; Cadabra remembers the changed words.
private struct CorrectEntrySheet: View {
    let entry: HistoryEntry
    let onSave: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("改正识别结果", "Correct this dictation")).font(.headline)
            Text(t("把识别错的词改对。Cadabra 会记住改动的词，下次遇到同样的错就自动改好。", "Fix the words that came out wrong. Cadabra remembers the changed words and fixes the same mistake next time."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button(t("取消", "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("保存", "Save")) {
                    onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == entry.text)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { text = entry.text }
    }
}

/// What Cadabra has learned from the user's fixes.
/// The user's own words, and the fixes learned from their corrections.
struct VocabularySettings: View {
    @EnvironmentObject var prefs: Preferences
    @ObservedObject private var learned = LearnedFixes.shared
    @State private var newTerm = ""
    @State private var filter = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                let terms = prefs.vocabularyTerms
                if !terms.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(terms, id: \.self) { term in
                            TermChip(text: term) { prefs.vocabularyTerms.removeAll { $0 == term } }
                        }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    TextField(t("加一个词", "Add a term"), text: $newTerm,
                              prompt: Text(t("比如 GitHub、万豪 Bonvoy；可以一次粘贴多个，用逗号隔开", "e.g. GitHub, Marriott Bonvoy; paste several separated by commas")))
                        .labelsHidden()
                        .onSubmit(add)
                    Button(t("添加", "Add"), action: add).disabled(Preferences.terms(in: newTerm).isEmpty)
                }
            } header: {
                Text(t("常用词（\(prefs.vocabularyTerms.count)）", "Your vocabulary (\(prefs.vocabularyTerms.count))"))
            } footer: {
                note(t("你常说的名字和术语。纠错模型会参考它们，也不会把它们改成别的词。", "Names and terms you say often. The correction model uses them and leaves them as they are."))
            }

            Section {
                if learned.fixes.isEmpty {
                    Text(t("还没有学到什么。听写完在原处改错的词，这里就会出现。", "Nothing learned yet. Fix a word right after dictating it and it shows up here."))
                        .foregroundStyle(.secondary)
                } else {
                    if learned.fixes.count > 8 {
                        TextField(t("筛选", "Filter"), text: $filter, prompt: Text(t("找一个词", "Find a word")))
                            .labelsHidden()
                    }
                    ForEach(shown) { fix in
                        LearnedFixRow(fix: fix) { learned.delete(fix) }
                    }
                }
            } header: {
                HStack {
                    Text(t("学到的改正（\(learned.fixes.count)）", "Learned fixes (\(learned.fixes.count))"))
                    Spacer()
                    if !learned.fixes.isEmpty {
                        Button(t("全部忘掉…", "Forget all…")) { confirmClear = true }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
            } footer: {
                note(t("只记读音相近的改动（听错了），改写内容的不记。改过两次（或在历史记录里改过一次）的会直接替换，标为「自动替换」；被替换的是普通英文单词时只做提示。其余的只给纠错模型做参考。学错了的点 × 忘掉。", "Only changes that sound like what was heard are learned (mishearings), not rewording. Fixes made twice (or once in History) are applied directly, unless they would replace an ordinary English word; the rest are hints for the correction model. Click × to forget a wrong one."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .confirmationDialog(t("忘掉全部 \(learned.fixes.count) 条改正？", "Forget all \(learned.fixes.count) learned fixes?"), isPresented: $confirmClear) {
            Button(t("全部忘掉", "Forget all"), role: .destructive) { learned.clear() }
        }
    }

    /// Applied ones first, then the most recent.
    private var shown: [LearnedFix] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return learned.fixes
            .filter { query.isEmpty || $0.heard.lowercased().contains(query) || $0.meant.lowercased().contains(query) }
            .sorted { ($0.applies ? 1 : 0, $0.lastSeen) > ($1.applies ? 1 : 0, $1.lastSeen) }
    }

    private func add() {
        var seen = Set(prefs.vocabularyTerms.map { $0.lowercased() })
        let new = Preferences.terms(in: newTerm).filter { seen.insert($0.lowercased()).inserted }
        if !new.isEmpty { prefs.vocabularyTerms += new }
        newTerm = ""
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TermChip: View {
    var text: String
    var onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12))
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0.5)
                .help(t("删掉这个词", "Remove this term"))
        }
        .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
        .onHover { hovering = $0 }
    }
}

private struct LearnedFixRow: View {
    let fix: LearnedFix
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(fix.heard).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(fix.meant)
            Spacer()
            Text(t("\(fix.count) 次", "×\(fix.count)")).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            Text(fix.applies ? t("自动替换", "applied") : t("提示", "hint"))
                .font(.system(size: 11))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(fix.applies ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                .foregroundStyle(fix.applies ? Color.accentColor : Color.secondary)
            Button(action: onDelete) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.tertiary)
                .help(t("忘掉这条", "Forget this one"))
        }
    }
}

/// Lays its children out in rows, wrapping like words.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(i)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else {
                rows.append(([i], size.width, size.height))
            }
        }
        return rows
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                AppGlyph(size: 64)
                Text(t("欢迎使用 Cadabra", "Welcome to Cadabra")).font(.system(size: 22, weight: .semibold))
                Text(t("说话，文字就出现在光标处。全部在本机完成。", "Talk, and the text appears at your cursor. Everything stays on this Mac."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(title: t("1. 允许使用麦克风", "1. Allow the microphone"), detail: t("点「授权」，在弹窗里选「允许」。", "Click Grant, then Allow in the dialog."),
                              granted: model.micStatus == .authorized) { model.requestMicrophone() }
                PermissionRow(title: t("2. 允许辅助功能", "2. Allow Accessibility"),
                              detail: t("点「授权」后会打开系统设置，在列表里打开 Cadabra 的开关。用来监听快捷键和粘贴文字。", "Click Grant to open System Settings, then turn on Cadabra in the list. It’s used for the shortcut and for pasting."),
                              granted: model.accessibilityGranted) { model.requestAccessibility() }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "keyboard").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("3. 试一下", "3. Try it")).font(.system(size: 13, weight: .medium))
                        (Text(prefs.trigger.detail(prefs.hotkey) + t(" 菜单栏的 ", " The ")) + Text(Image(systemName: "waveform"))
                            + Text(t(" 里可以看历史、改设置。", " menu bar icon has history and settings.")))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

            Button {
                prefs.onboarded = true
                dismissWindow(id: "welcome")
            } label: {
                Text(model.needsPermissions ? t("稍后再说", "Later") : t("开始使用", "Get Started")).frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 460)
    }
}
