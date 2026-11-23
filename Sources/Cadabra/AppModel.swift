import AppKit
import AVFoundation
import Combine
import os
import ServiceManagement

private let log = Logger(subsystem: "com.peihongguo.Cadabra", category: "dictation")

/// The one place that knows whether we are recording. The hotkey, the menu button and the HUD
/// all go through it, so they can never disagree about the state.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(prefs: .shared, history: .shared)

    enum ModelState: Equatable {
        case loading, ready, failed(String)
    }

    let prefs: Preferences
    let history: HistoryStore
    let hud: HUDController

    @Published private(set) var modelState: ModelState = .loading
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart = Date()
    /// Recording keeps going after the key is released; the next press ends it.
    @Published private(set) var latched = false
    /// What the recording is for: dictation, an instruction for rewriting the selection (the rewrite key),
    /// or a request for the agent (the agent key).
    enum Mode { case dictate, rewrite, agent }
    @Published private(set) var mode = Mode.dictate
    var editing: Bool { mode == .rewrite }
    /// What has been recognized so far, while recording (`preview()`).
    @Published private(set) var liveText = ""
    @Published private(set) var pending = 0
    @Published private(set) var levels = [Float](repeating: 0, count: AppModel.levelCount)
    @Published private(set) var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var hotkeyActive = false
    /// Settings is waiting for the user to press the key they want.
    @Published private(set) var capturingHotkey = false
    @Published private(set) var captureNote: String?

    static let levelCount = 28
    static let maxRecording: TimeInterval = 300
    static let holdThreshold: TimeInterval = 0.35
    /// The microphone opens this long after the key goes down, so ⌃C or ⌥E never touches it.
    static let armDelay: TimeInterval = 0.12
    /// Another key or a click this soon after the dictation key means it was a modifier (⌥E, ⌥-click)
    /// and the recording is dropped. Later ones are the user doing something else while talking.
    static let chordWindow: TimeInterval = 0.5
    /// While recording, the words so far are recognized this often, from at most the last `previewWindow`
    /// seconds: the bar shows only the end of them, and a long recording shouldn't cost more each time.
    static let previewEvery: TimeInterval = 0.8
    static let previewWindow: TimeInterval = 15
    /// Typed into the field, the words are kept up to date for this long; the rest comes at the end.
    static let fieldLimit: TimeInterval = 90

    private let engine = ASREngine()
    private let recorder = AudioRecorder()
    private let hotkeys: HotkeyMonitor
    private var subscriptions = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var feedback: DispatchWorkItem?
    private var pressTime = Date()
    private var pressStartedRecording = false
    private var pendingStart: DispatchWorkItem?
    private var captureTimeout: DispatchWorkItem?
    /// Dictations being recognized and corrected; esc cancels them.
    private var jobs: [UUID: Task<Void, Never>] = [:]
    /// While rewriting: the selection, read when the recording started.
    private var selection: Task<String, Never>?
    private var previewTimer: Timer?
    private var previewBusy = false
    /// Types the words so far into the field while recording (`LivePreview.field`).
    private let typer = LiveTyper()
    /// This recording's words go into the field as they come.
    private var typingLive = false

    init(prefs: Preferences, history: HistoryStore) {
        self.prefs = prefs
        self.history = history
        self.hotkeys = HotkeyMonitor(hotkey: prefs.hotkey)
        self.hud = HUDController()
        hud.model = self
    }

    // MARK: Launch

    func launch() {
        // Accessibility calls into a hung app would otherwise wait seconds on the main thread, and the
        // hotkey's event tap (and so the keyboard) with it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
        history.persist = prefs.saveHistory
        _ = LearnedFixes.shared   // loads (and cleans up) now rather than in the middle of the first dictation
        loadModel()
        recorder.onLevel = { [weak self] level in self?.push(level: level) }
        Microphones.noteDefault()

        hotkeys.onDown = { [weak self] in MainActor.assumeIsolated { self?.hotkeyDown() } }
        hotkeys.onUp = { [weak self] in MainActor.assumeIsolated { self?.hotkeyUp() } }
        hotkeys.editHotkey = prefs.editHotkey
        hotkeys.onEditDown = { [weak self] in MainActor.assumeIsolated { self?.hotkeyDown(.rewrite) } }
        hotkeys.onEditUp = { [weak self] in MainActor.assumeIsolated { self?.hotkeyUp(.rewrite) } }
        hotkeys.agentHotkey = prefs.agentHotkey
        hotkeys.onAgentDown = { [weak self] in MainActor.assumeIsolated { self?.hotkeyDown(.agent) } }
        hotkeys.onAgentUp = { [weak self] in MainActor.assumeIsolated { self?.hotkeyUp(.agent) } }
        hotkeys.onChord = { [weak self] in MainActor.assumeIsolated { self?.hotkeyChord() } }
        hotkeys.onEscape = { [weak self] in MainActor.assumeIsolated { self?.cancel() ?? false } }
        if accessibilityGranted { hotkeyActive = hotkeys.start() }

        prefs.$hotkey.dropFirst().sink { [weak self] key in self?.hotkeys.hotkey = key }.store(in: &subscriptions)
        prefs.$editHotkey.dropFirst().sink { [weak self] key in self?.hotkeys.editHotkey = key }.store(in: &subscriptions)
        prefs.$agentHotkey.dropFirst().sink { [weak self] key in self?.hotkeys.agentHotkey = key }.store(in: &subscriptions)
        prefs.$checkUpdatesWeekly.sink { UpdateChecker.shared.scheduleWeekly($0) }.store(in: &subscriptions)
        prefs.$language.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.loadModel() }   // after the new value is stored
        }.store(in: &subscriptions)
        prefs.$correction.combineLatest(prefs.$correctionModel).sink { on, choice in
            Corrector.shared.configure(enabled: on, model: choice)
        }.store(in: &subscriptions)
        prefs.$saveHistory.sink { [weak self] on in self?.history.persist = on }.store(in: &subscriptions)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    /// The user fixed a dictation in History.
    func edit(_ entry: HistoryEntry, to text: String) {
        LearnedFixes.shared.learn(typed: entry.text, edited: text, weight: LearnedFixes.confirmAt)
        history.update(entry.id, text: text)
        TrainingData.shared.update(entry.id, text: text)
    }

    /// Deleting a dictation also deletes its recording, if one was kept for training.
    func delete(_ entry: HistoryEntry) {
        history.delete(entry)
        TrainingData.shared.remove(entry.id)
    }

    func shutDown() {
        EditWatcher.shared.finish()
        Storage.flush()
        Corrector.shared.shutDown()   // ggml's Metal device crashes in its exit-time cleanup otherwise
    }

    private func loadModel() {
        modelState = .loading
        engine.load(modelDirectory: ASREngine.defaultModelDirectory(), language: prefs.language) { [weak self] error in
            DispatchQueue.main.async {
                self?.modelState = error.map { .failed($0.localizedDescription) } ?? .ready
            }
        }
    }

    // MARK: Permissions

    var needsPermissions: Bool { micStatus != .authorized || !accessibilityGranted }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micStatus { micStatus = mic }   // every second: publish only changes
        hotkeys.catchUp()
        let trusted = AXIsProcessTrusted()
        guard trusted != accessibilityGranted || trusted != hotkeys.isRunning else { return }
        accessibilityGranted = trusted
        // A tap made without Accessibility only ever sees our own app's keys, so build a fresh one
        // whenever the grant changes rather than keeping the old one.
        hotkeys.stop()
        hotkeyActive = trusted && hotkeys.start()
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        default:
            openSettings("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { openSettings("Privacy_Accessibility") }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Hotkey

    /// `edit`: the rewrite key rather than the dictation key.
    private func hotkeyDown(_ pressed: Mode = .dictate) {
        pressTime = Date()
        if isRecording {
            // Held-to-talk never sees a second press, unless the release went missing: stop then too,
            // rather than leaving only esc.
            if pressed == mode {
                if prefs.trigger == .auto && !latched { log.notice("pressed again while held: the release was missed") }
                stop()
            }
            return
        }
        if pressed == .agent, AgentPlugin.selected == nil {
            hud.flash(.message(t("先装一个 agent 插件，在 设置 › Agent 里选它", "Install an agent plugin and pick it in Settings › Agent first"), symbol: "sparkles"))
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingStart = nil
            self.pressStartedRecording = self.start(latched: self.prefs.trigger == .toggle, mode: pressed)
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armDelay, execute: work)
    }

    private func hotkeyUp(_ pressed: Mode = .dictate) {
        if let work = pendingStart {
            // Released before the microphone opened: a quick tap, which starts a hands-free recording.
            work.cancel()
            pendingStart = nil
            if prefs.trigger != .pushToTalk { start(latched: true, mode: pressed) }
            return
        }
        defer { pressStartedRecording = false }
        guard isRecording, pressStartedRecording, pressed == mode else { return }
        switch prefs.trigger {
        case .pushToTalk:
            stop()
        case .toggle:
            break
        case .auto:
            if Date().timeIntervalSince(pressTime) >= Self.holdThreshold {
                stop()
            } else {
                latched = true   // a tap: keep listening until the next press
            }
        }
    }

    /// ⌥E, ⌘C, ⌥-click...: the key was a modifier for something else, not a dictation.
    private func hotkeyChord() {
        pendingStart?.cancel()
        pendingStart = nil
        guard Date().timeIntervalSince(pressTime) < Self.chordWindow else { return }
        if isRecording && pressStartedRecording { cancel(silently: true) }
        pressStartedRecording = false
    }

    // MARK: Choosing the key

    /// Settings' "press the key" button. Goes through the same event tap, so it also proves the tap works.
    func beginHotkeyCapture() {
        captureNote = nil
        guard hotkeys.isRunning else {
            captureNote = t("快捷键监听还没启动：先在「权限」里授权辅助功能", "The shortcut listener isn’t running yet: grant Accessibility under Permissions first")
            return
        }
        cancel(silently: true)
        capturingHotkey = true
        hotkeys.onCapture = { [weak self] type, code, flags in
            MainActor.assumeIsolated { self?.captured(type, code, flags) ?? false }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.endHotkeyCapture(note: t("没等到按键，再试一次", "No key pressed. Try again")) }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    func endHotkeyCapture(note: String? = nil) {
        captureTimeout?.cancel()
        hotkeys.onCapture = nil
        capturingHotkey = false
        captureNote = note
    }

    private func captured(_ type: CGEventType, _ code: Int64, _ flags: CGEventFlags) -> Bool {
        if type == .keyDown {
            if code == 53 { endHotkeyCapture() } else { captureNote = t("要用单独的修饰键：Option、Control、右 Command 或 Fn", "Use a modifier key on its own: Option, Control, right Command or Fn") }
            return true
        }
        guard let key = Hotkey(keyCode: code) else {
            if flags.rawValue & Hotkey.deviceSideMasks != 0 || flags.contains(.maskShift) || flags.contains(.maskCommand) {
                captureNote = t("这个键不行：Shift 和左 Command 太常用，请换一个", "Not that one: Shift and left Command are used too often. Pick another key")
            }
            return true
        }
        guard key.isHeld(in: flags) else { return true }   // the release
        prefs.hotkey = key
        endHotkeyCapture(note: t("已设为 \(key.title)", "Set to \(key.title)"))
        return true
    }

    // MARK: Recording

    /// From the menu or HUD: start (ends with the next hotkey press) or finish.
    func toggleFromUI() {
        if isRecording {
            stop()
        } else {
            NSApp.hide(nil)   // give focus back to the app the text should go into
            start(latched: true)
        }
    }

    @discardableResult
    private func start(latched: Bool, mode: Mode = .dictate) -> Bool {
        guard !isRecording else { return false }
        guard micStatus == .authorized else {
            requestMicrophone()
            hud.flash(.message(t("需要麦克风权限", "Microphone access needed"), symbol: "mic.slash"))
            return false
        }
        do {
            try recorder.start(device: Microphones.choose(uid: prefs.microphone)?.device)
        } catch {
            hud.flash(.message(error.localizedDescription, symbol: "mic.slash"))
            return false
        }
        EditWatcher.shared.finish()
        if prefs.correction { Corrector.shared.wake() }
        self.mode = mode
        selection = mode == .rewrite ? Task { await TextInjector.selection() } : nil
        hud.anchor = prefs.barNearText ? TextInjector.caretRect() : nil
        self.latched = latched
        isRecording = true
        recordingStart = Date()
        // Into the field only when nothing earlier is still on its way there.
        typingLive = prefs.livePreview == .field && prefs.autoPaste && mode == .dictate && pending == 0
        if typingLive { typer.begin(in: TextInjector.Target.current()) }
        if mode == .agent { PluginHost.shared.listen(near: hud.anchor) }
        if prefs.livePreview != .off || mode == .agent {
            previewTimer = Timer.scheduledTimer(withTimeInterval: Self.previewEvery, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.preview() }
            }
        }
        levels = Array(repeating: 0, count: Self.levelCount)
        // Sound and HUD wait a moment, so a ⌥E typed with the dictation key shows nothing at all.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            if self.prefs.sounds { Sounds.start() }
            if self.mode != .agent { self.hud.show(.recording) }   // the agent's panel shows it instead
        }
        feedback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        return true
    }

    func stop() {
        guard isRecording else { return }
        let target = TextInjector.Target.current()
        let context = prefs.useContext && (prefs.hotwords || prefs.correction) ? FocusContext.read() : nil
        let mode = self.mode
        let samples = finishRecording()
        let duration = Double(samples.count) / Double(ASREngine.sampleRate)
        let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard duration >= 0.3, rms >= 0.001 else {
            if typingLive { typer.clear() }
            if mode == .agent { PluginHost.shared.cancel() }
            if prefs.sounds { Sounds.error() }
            hud.flash(.message(duration < 0.3 ? t("录音太短", "Too short") : t("没有听到声音", "Didn’t hear anything"), symbol: "waveform.slash"))
            return
        }
        if prefs.sounds { Sounds.stop() }
        if mode == .rewrite, let selection {
            return rewrite(samples, selection: selection, target: target, context: context)
        }
        if mode == .agent { return ask(samples) }
        pending += 1
        hud.show(.transcribing)
        let job = UUID()
        jobs[job] = Task {
            defer { pending -= 1; jobs[job] = nil }
            do {
                let hotwords = prefs.hotwords ? prefs.vocabularyTerms + LearnedFixes.shared.hotwords + (context?.words() ?? []) : []
                let transcript = try await engine.transcribe(samples, hotwords: hotwords)
                guard !Task.isCancelled else { return }
                let learned = LearnedFixes.shared
                let recognized = learned.apply(RepeatedEnding.fix(transcript.text))
                var corrected: String?
                if prefs.correction, !recognized.isEmpty {
                    if Corrector.shared.isReady {
                        let vocabulary = ([prefs.vocabulary] + learned.terms.prefix(30)).filter { !$0.isEmpty }.joined(separator: ", ")
                        let began = Date()
                        Corrector.shared.scheduleRest()
                        corrected = try? await Corrector.shared.correct(recognized, vocabulary: vocabulary, learned: learned.hints(for: recognized),
                                                                        keep: learned.keep(vocabulary: prefs.vocabulary), context: context)
                        log.notice("recognized in \(Int(transcript.latency * 1000)) ms, corrected in \(Int(Date().timeIntervalSince(began) * 1000)) ms, changed: \(corrected.map { $0 != recognized } ?? false), context: \(context.map { $0.before.count + $0.after.count } ?? 0) chars")
                    } else {
                        // Never wait for a model that is still loading (it can take many seconds).
                        log.notice("recognized in \(Int(transcript.latency * 1000)) ms, correction skipped: model not loaded")
                    }
                } else {
                    log.notice("recognized in \(Int(transcript.latency * 1000)) ms")
                }
                guard !Task.isCancelled else { return }
                let (text, id) = deliver(transcript, text: corrected ?? recognized, to: target, live: typingLive)
                if prefs.collectTraining, let id {
                    TrainingData.shared.add(id: id, audio: samples, recognized: transcript.text, text: text,
                                            label: corrected.map { $0 != recognized } == true ? .modelChanged : .unchanged)
                }
                if prefs.saveRecordings {
                    RecordingArchive.save(samples, recognized: transcript.text, corrected: corrected, typed: text,
                                          language: prefs.language)
                }
            } catch {
                if typingLive { typer.clear() }
                if !isRecording { hud.flash(.message(error.localizedDescription, symbol: "exclamationmark.triangle")) }
            }
        }
    }

    /// Cancels the recording or, with esc after it, the dictations still being recognized. Returns
    /// whether anything was cancelled (esc then goes no further).
    @discardableResult
    func cancel(silently: Bool = false) -> Bool {
        pendingStart?.cancel()
        pendingStart = nil
        selection = nil
        if isRecording {
            if mode == .agent { PluginHost.shared.cancel() }
            _ = finishRecording()
            if typingLive { typer.clear() }
            if silently { hud.hide() } else { hud.flash(.message(t("已取消", "Cancelled"), symbol: "xmark.circle")) }
            return true
        }
        guard !silently, !jobs.isEmpty else { return false }
        jobs.values.forEach { $0.cancel() }
        jobs.removeAll()
        if typingLive { typer.clear() }
        hud.flash(.message(t("已取消", "Cancelled"), symbol: "xmark.circle"))
        return true
    }

    /// Recognizes what has been said so far, for the recording bar. Skipped while the last one is still
    /// running, so it never queues up in front of the final recognition.
    private func preview() {
        guard isRecording, !previewBusy else { return }
        // In the field the whole text is needed (it's edited in place); past `fieldLimit` it waits for the end.
        let inField = typingLive && typer.isTyping
        let whole = inField || mode == .agent   // the panel shows all of it, like the field
        if whole, Date().timeIntervalSince(recordingStart) > Self.fieldLimit { return }
        let audio = recorder.recent(seconds: whole ? Self.fieldLimit : Self.previewWindow)
        guard audio.count >= ASREngine.sampleRate / 2 else { return }
        let session = recordingStart
        let hotwords = prefs.hotwords ? prefs.vocabularyTerms + LearnedFixes.shared.hotwords : []
        previewBusy = true
        Task {
            defer { previewBusy = false }
            guard let transcript = try? await engine.transcribe(audio, hotwords: hotwords),
                  isRecording, recordingStart == session else { return }
            let text = LearnedFixes.shared.apply(transcript.text)
            if mode == .agent { return PluginHost.shared.partial(text) }
            // Typed into the field; where that stopped working, shown in the bar instead.
            if inField, typer.show(text) { liveText = "" } else { liveText = text }
        }
    }

    private func finishRecording() -> [Float] {
        previewTimer?.invalidate()
        previewTimer = nil
        liveText = ""
        feedback?.cancel()
        feedback = nil
        let samples = recorder.stop()
        isRecording = false
        mode = .dictate
        latched = false
        pressStartedRecording = false
        return samples
    }

    private func push(level: Float) {
        guard isRecording else { return }
        if mode == .agent { PluginHost.shared.level(level) }
        levels.removeFirst()
        levels.append(level)
        if Date().timeIntervalSince(recordingStart) > Self.maxRecording { stop() }
    }

    /// The agent key: the final words go to the agent plugin's page; what happens to them is up to it.
    private func ask(_ samples: [Float]) {
        pending += 1
        let job = UUID()
        jobs[job] = Task {
            defer { pending -= 1; jobs[job] = nil }
            do {
                let hotwords = prefs.hotwords ? prefs.vocabularyTerms + LearnedFixes.shared.hotwords : []
                let transcript = try await engine.transcribe(samples, hotwords: hotwords)
                guard !Task.isCancelled else { return }
                let words = LearnedFixes.shared.apply(RepeatedEnding.fix(transcript.text))
                guard !words.isEmpty else {
                    PluginHost.shared.cancel()
                    hud.flash(.message(t("没有识别出文字", "No speech recognized"), symbol: "questionmark.circle"))
                    return
                }
                PluginHost.shared.final(words)
            } catch {
                PluginHost.shared.cancel()
                hud.flash(.message(error.localizedDescription, symbol: "exclamationmark.triangle"))
            }
        }
    }

    /// The rewrite key: the recording is an instruction for the selection (or, with none, for new text at
    /// the cursor), carried out by the correction model; the answer replaces the selection.
    private func rewrite(_ samples: [Float], selection: Task<String, Never>, target: TextInjector.Target?, context: FocusContext?) {
        self.selection = nil
        guard prefs.correction, CorrectionModel.allCases.contains(where: \.isDownloaded) || Corrector.shared.state == .ready else {
            hud.flash(.message(t("改写要用本机大模型：先在 设置 › 通用 › 纠错 里打开并下载", "Rewriting needs the local model: turn on Correction in Settings › General and download it"),
                               symbol: "sparkles"))
            return
        }
        pending += 1
        hud.show(.transcribing)
        let job = UUID()
        jobs[job] = Task {
            defer { pending -= 1; jobs[job] = nil }
            do {
                let hotwords = prefs.hotwords ? prefs.vocabularyTerms + LearnedFixes.shared.hotwords + (context?.words() ?? []) : []
                let instruction = try await engine.transcribe(samples, hotwords: hotwords)
                let selected = await selection.value
                guard !Task.isCancelled, !instruction.text.isEmpty else { return }
                hud.show(.thinking(selected.isEmpty ? t("正在写：\(instruction.text)", "Writing: \(instruction.text)")
                                                    : t("正在改：\(instruction.text)", "Rewriting: \(instruction.text)")))
                try await Corrector.shared.ready()
                let began = Date()
                Corrector.shared.scheduleRest()
                let result = try await Corrector.shared.rewrite(selected.isEmpty ? nil : selected, instruction: instruction.text,
                                                                context: selected.isEmpty ? context : nil)
                log.notice("rewrote \(selected.count) characters into \(result.count) in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
                guard !Task.isCancelled else { return }
                deliver(instruction, text: result, to: target, dictated: false)
            } catch {
                if !isRecording { hud.flash(.message(error.localizedDescription, symbol: "exclamationmark.triangle")) }
            }
        }
    }

    /// Types or copies the text; returns it and its history entry.
    @discardableResult
    /// `dictated`: the user's own words (learned from, trailing period setting applied), not a rewrite.
    /// `live`: the words may already be in the field (`LiveTyper`); they are turned into the final text there.
    private func deliver(_ transcript: Transcript, text recognized: String, to target: TextInjector.Target?, dictated: Bool = true,
                         live: Bool = false) -> (String, UUID?) {
        var text = recognized
        if dictated, prefs.dropTrailingPeriod, let last = text.last, "。.".contains(last) { text.removeLast() }
        guard !text.isEmpty else {
            if live { typer.clear() }
            if !isRecording { hud.flash(.message(t("没有识别出文字", "No speech recognized"), symbol: "questionmark.circle")) }
            return (text, nil)
        }
        let id = history.add(transcript, text: text)
        var refusal: TextInjector.Refusal? = .noAccess
        var leftBehind = false
        if live, !typer.typed.isEmpty {
            if typer.finish(with: text, restoreClipboard: prefs.restoreClipboard) {
                refusal = nil
            } else {
                // Part of it is already in a field that can't be reached now: pasting all of it on top
                // would write the start twice, so it only goes on the clipboard.
                leftBehind = true
                refusal = .focusMoved
            }
        } else if prefs.autoPaste {
            typer.end()
            refusal = TextInjector.paste(text, restoreClipboard: prefs.restoreClipboard, into: target)
        }
        let pasted = refusal == nil
        if !pasted { TextInjector.copy(text) }
        if pasted {
            // The user's clipboard goes back once the text shows up in the field; if the field can be read
            // and the text isn't there, the paste didn't take and the dictation stays on the clipboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                let landed = TextInjector.landed(text)
                ClipboardSwap.general.settle(restore: landed != false)
                if landed == false, self?.isRecording == false { self?.hud.flash(.done(text, pasted: false)) }
            }
        }
        if pasted && dictated && prefs.learnFromEdits {
            EditWatcher.shared.begin(typed: text) { [weak self] edited in
                let fixes = LearnedFixes.shared.learn(typed: text, edited: edited)
                guard !fixes.isEmpty else { return }
                self?.history.update(id, text: edited)
                // Only the fixed words: anything the user went on to type isn't what they said.
                TrainingData.shared.update(id, text: TextDiff.substitutions(from: text, to: edited))
            }
        }
        if !isRecording {
            switch refusal {
            case .focusMoved where leftBehind:
                hud.flash(.message(t("输入框换了：完整结果已复制，⌘V 粘贴", "The field changed: the whole text is copied, press ⌘V"), symbol: "doc.on.clipboard"))
            case .focusMoved: hud.flash(.message(t("窗口换了，没有粘贴：已复制，⌘V 粘贴", "Focus moved, so nothing was pasted. Copied: press ⌘V"), symbol: "doc.on.clipboard"))
            case .secureField: hud.flash(.message(t("密码框里不粘贴：已复制", "Not pasted into a password field. Copied"), symbol: "lock"))
            default: hud.flash(.done(text, pasted: pasted))
            }
        }
        return (text, id)
    }

    // MARK: Menu text

    var statusLine: String {
        if isRecording { return latched ? t("正在听… 再按 \(prefs.hotkey.keycap) 结束", "Listening… press \(prefs.hotkey.keycap) again to finish") : t("正在听…", "Listening…") }
        if pending > 0 { return t("识别中…", "Transcribing…") }
        switch modelState {
        case .loading: return t("正在加载模型…", "Loading model…")
        case .failed(let message): return message
        case .ready:
            if !hotkeyActive { return t("快捷键还不能用：需要辅助功能权限", "Shortcut not working yet: needs Accessibility access") }
            return prefs.trigger == .toggle ? t("按 \(prefs.hotkey.keycap) 开始说话", "Press \(prefs.hotkey.keycap) to start talking") : t("按住 \(prefs.hotkey.keycap) 说话", "Hold \(prefs.hotkey.keycap) and talk")
        }
    }

    // MARK: Login item

    /// Asked of macOS once and then remembered: Settings redraws with every level update while recording,
    /// and each question is a round trip to another process on the main thread (30 a second held up the
    /// hotkey's event tap). Settings asks again when it opens.
    private lazy var loginItemEnabled = SMAppService.mainApp.status == .enabled

    var launchAtLogin: Bool {
        get { loginItemEnabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Cadabra login item: \(error)")
            }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    func refreshLoginItem() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != loginItemEnabled {
            objectWillChange.send()
            loginItemEnabled = enabled
        }
    }

    // MARK: Previews

    /// A model in a fixed state, for --snapshot.
    static func preview(recording: Bool = false, latched: Bool = false, permissions: Bool = true, live: String = "",
                        history: HistoryStore) -> AppModel {
        let model = AppModel(prefs: Preferences(), history: history)
        model.modelState = .ready
        model.isRecording = recording
        model.latched = latched
        model.liveText = live
        model.recordingStart = Date().addingTimeInterval(-4.2)
        model.levels = (0..<levelCount).map { i in Float(0.25 + 0.6 * abs(sin(Double(i) * 0.7))) }
        model.micStatus = permissions ? .authorized : .notDetermined
        model.accessibilityGranted = permissions
        model.hotkeyActive = permissions
        return model
    }
}

enum Sounds {
    static func start() { play("Tink") }
    static func stop() { play("Pop") }
    static func error() { play("Funk") }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.35
        sound.play()
    }
}
