import AppKit
import SwiftUI

final class HUDState: ObservableObject {
    enum Kind: Equatable {
        case hidden
        case recording
        case transcribing
        /// The language model at work (rewriting by voice).
        case thinking(String)
        case done(String, pasted: Bool)
        case message(String, symbol: String)
    }

    @Published var kind: Kind = .hidden
}

/// A click-through capsule near the bottom of the screen the mouse is on. It never takes focus,
/// so the app being typed into stays frontmost.
@MainActor
final class HUDController {
    let state = HUDState()
    weak var model: AppModel?
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var generation = 0
    /// Where the text goes, in screen coordinates: the bar sits just above it (or below, without room).
    /// Set when a recording starts; nil puts the bar at the bottom of the screen.
    var anchor: NSRect?

    static let size = NSSize(width: 620, height: 96)
    /// The bar inside the panel: its bottom edge and height (see HUDView).
    private static let barBottom: CGFloat = 14, barHeight: CGFloat = 46, gap: CGFloat = 8

    func show(_ kind: HUDState.Kind) {
        hideWork?.cancel()
        generation += 1
        state.kind = kind
        guard let panel = panel ?? makePanel() else { return }
        place(panel)
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Shows a result or message, then fades out.
    func flash(_ kind: HUDState.Kind, for seconds: TimeInterval = 1.8) {
        show(kind)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { state.kind = .hidden; return }
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }   // shown again meanwhile
                panel.orderOut(nil)
                self.state.kind = .hidden
            }
        })
    }

    private func makePanel() -> NSPanel? {
        guard let model else { return nil }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView()
            .environmentObject(state)
            .environmentObject(model)
            .environmentObject(model.prefs))
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel) {
        if let anchor, let frame = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame {
            panel.setFrameOrigin(Self.origin(near: anchor, in: frame))
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 36))
    }

    /// The panel's origin with the bar just above `anchor`, or below it when the screen ends first,
    /// centred on it and kept on the screen.
    static func origin(near anchor: NSRect, in frame: NSRect) -> NSPoint {
        var y = anchor.maxY + gap - barBottom
        if y + barBottom + barHeight > frame.maxY { y = anchor.minY - gap - barHeight - barBottom }
        y = min(max(y, frame.minY - barBottom), frame.maxY - barBottom - barHeight)
        let x = min(max(anchor.midX - size.width / 2, frame.minX), frame.maxX - size.width)
        return NSPoint(x: x, y: y)
    }
}

struct HUDView: View {
    @EnvironmentObject var hud: HUDState
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    /// For --snapshot: a theme other than the chosen one.
    var themeOverride: Theme?
    /// The system's light or dark, before the bar sets its own below.
    @Environment(\.colorScheme) private var systemScheme
    private var theme: Theme { (themeOverride ?? Theme.named(prefs.theme)).forBar(dark: systemScheme == .dark) }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if hud.kind != .hidden {
                content
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .background(Capsule().fill(theme.barFill))
                    .overlay(Capsule().strokeBorder(theme.barText.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(theme.barIsDark ? 0.35 : 0.2), radius: 14, y: 6)
                    .foregroundStyle(theme.barText)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .padding(.bottom, 14)
        .frame(width: HUDController.size.width, height: HUDController.size.height)
        .animation(.spring(duration: 0.28, bounce: 0.2), value: hud.kind)
        .environment(\.colorScheme, theme.barIsDark ? .dark : .light)
        .environment(\.theme, theme)
        .fontDesign(theme.serif ? .serif : nil)
    }

    @ViewBuilder
    private var content: some View {
        switch hud.kind {
        case .hidden:
            EmptyView()
        case .recording:
            HStack(spacing: 12) {
                PulsingDot(color: theme.dot, star: theme.star)
                Waveform(levels: model.levels, colors: theme.wave)
                    .frame(width: 120, height: 24)
                ElapsedText(start: model.recordingStart)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(minWidth: 34, alignment: .leading)
                if model.liveText.isEmpty {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.barText.opacity(0.6))
                        .fixedSize()
                } else {
                    // The end of what was said so far; the start scrolls off to the left.
                    Text(model.liveText)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 330, alignment: .leading)
                        .fixedSize(horizontal: model.liveText.count < 20, vertical: false)
                        .animation(.easeOut(duration: 0.15), value: model.liveText)
                }
            }
        case .thinking(let text):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.barText)
                Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(theme.barText)
                Text(t("识别中…", "Transcribing…")).font(.system(size: 13, weight: .medium))
            }
        case .done(_, let pasted):
            // Just the outcome: the words themselves are in the field (or on the clipboard) already.
            HStack(spacing: 8) {
                Image(systemName: pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .foregroundStyle(pasted ? .green : .yellow)
                    .font(.system(size: 16))
                Text(pasted ? t("已输入", "Done") : t("已复制，⌘V 粘贴", "Copied. Press ⌘V to paste"))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
            }
        case .message(let text, let symbol):
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.orange)
                Text(text).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
        }
    }

    private var hint: String {
        if model.mode == .agent {
            return model.latched || prefs.trigger == .toggle
                ? t("说给 agent · 再按一下结束", "Talk to the agent · press again to finish")
                : t("说给 agent · 松开结束", "Talk to the agent · release to finish")
        }
        if model.editing {
            return model.latched || prefs.trigger == .toggle
                ? t("说要怎么改 · 再按一下结束", "Say how to change it · press again to finish")
                : t("说要怎么改 · 松开结束", "Say how to change it · release to finish")
        }
        if model.latched || prefs.trigger == .toggle { return t("再按 \(prefs.hotkey.keycap) 结束 · esc 取消", "Press \(prefs.hotkey.keycap) again to finish · esc to cancel") }
        return t("松开结束 · esc 取消", "Release to finish · esc to cancel")
    }
}

struct PulsingDot: View {
    var color: Color = .red
    var star = false

    var body: some View {
        Group {
            if star {
                Canvas { context, size in
                    MagicMark.star(&context, center: CGPoint(x: size.width / 2, y: size.height / 2 + 0.5), radius: size.width * 0.42)
                }
                .frame(width: 14, height: 14)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
        }
            .phaseAnimator([1.0, 0.35]) { dot, phase in
                dot.opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.7) }
    }
}

struct Waveform: View {
    var levels: [Float]
    /// Taken in turn, bar by bar.
    var colors: [Color]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { i, level in
                    Capsule()
                        .fill(colors[i % colors.count].opacity(0.35 + 0.65 * Double(level)))
                        .frame(height: max(3, geo.size.height * CGFloat(level)))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}

struct ElapsedText: View {
    var start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.5)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
}
