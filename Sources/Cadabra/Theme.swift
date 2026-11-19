import SwiftUI

/// A color theme, like an editor's: the menu, the recording bar and the windows. The editor themes use
/// their published palettes (see THIRD_PARTY_NOTICES.md).
struct Theme: Identifiable, Hashable {
    let id: String
    let zh: String
    let en: String
    /// Light or dark; nil follows the system.
    var scheme: ColorScheme?
    /// Behind the menu and the windows; nil keeps the system's.
    var background: Color?
    var text: Color?
    /// Links, switches, pickers.
    var link: Color = .accentColor
    /// The record button and the little app glyph, as a gradient from first to last.
    var accent: [Color]
    var onAccent: Color = .white
    /// The recording bar at the bottom of the screen.
    var bar: Color = .black.opacity(0.84)
    var barText: Color = .white
    var wave: [Color] = [.white]
    var dot: Color = .red
    /// Behind the recording bar instead of `bar`, as a gradient.
    var barGradient: [Color]?
    /// A gold star instead of the dot while recording.
    var star = false
    /// Notices on the bar ("Didn't hear anything"); nil uses `barText`.
    var notice: Color?
    var serif = false

    var title: String { t(zh, en) }
    var gradient: LinearGradient { LinearGradient(colors: accent, startPoint: .topLeading, endPoint: .bottomTrailing) }
    var barIsDark: Bool { NSColor(bar).usingColorSpace(.sRGB).map { $0.brightnessComponent < 0.5 } ?? true }
    var barFill: AnyShapeStyle {
        barGradient.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .topLeading, endPoint: .bottomTrailing)) } ?? AnyShapeStyle(bar)
    }

    /// The recording bar. The Cadabra theme's follows the system (docs/visual-language.md): in dark mode a
    /// dark bar with the wave in the mark's sky-to-violet, in light mode the pale stage with a clay purple
    /// wave; a gold star either way. Other themes keep their own.
    func forBar(dark: Bool) -> Theme {
        guard id == Theme.cadabra.id else { return self }
        var bar = self
        bar.star = true
        if dark {
            bar.notice = Color(hex: 0xFFA94D)
            bar.bar = Color(hex: 0x17142B).opacity(0.92)
            bar.wave = Theme.ramp([0x47A3FB, 0x546BFA, 0x9E52F2], count: 28)  // one per bar: AppModel.levelCount
        } else {
            bar.notice = Color(hex: 0xE8590C)
            bar.bar = Color(hex: 0xD4DAFE)
            bar.barGradient = [Color(hex: 0xD1E8FE), Color(hex: 0xD4DAFE), Color(hex: 0xE7D4FC)]
            bar.barText = Color(hex: 0x17142B)
            bar.wave = [Color(hex: 0x8B74E8)]
        }
        return bar
    }

    /// `count` colors evenly along the stops, so a waveform shades from the first to the last.
    static func ramp(_ stops: [UInt32], count: Int) -> [Color] {
        let rgb = stops.map { [Double($0 >> 16 & 0xFF), Double($0 >> 8 & 0xFF), Double($0 & 0xFF)] }
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1)) * Double(rgb.count - 1)
            let k = min(Int(t), rgb.count - 2), u = t - Double(k)
            let c = (0..<3).map { rgb[k][$0] * (1 - u) + rgb[k + 1][$0] * u }
            return Color(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255)
        }
    }

    static let cadabra = Theme(id: "cadabra", zh: "Cadabra（跟随系统）", en: "Cadabra (follows the system)",
                               accent: [Color(hex: 0x546BFA), Color(hex: 0x9E52F2)])

    static let all: [Theme] = [
        cadabra,
        Theme(id: "starlight", zh: "星夜", en: "Starlight", scheme: .dark,
              background: Color(hex: 0x1D1840), text: Color(hex: 0xECE8FF), link: Color(hex: 0xF5C451),
              accent: [Color(hex: 0x6E56CF), Color(hex: 0x9B6CF0)],
              bar: Color(hex: 0x1D1840), barText: Color(hex: 0xECE8FF), wave: [Color(hex: 0xF5C451), Color(hex: 0xB9A6FF)],
              dot: Color(hex: 0xF5C451)),
        Theme(id: "paper", zh: "纸墨", en: "Paper and ink", scheme: .light,
              background: Color(hex: 0xFAF6EE), text: Color(hex: 0x2B2622), link: Color(hex: 0xC23B2A),
              accent: [Color(hex: 0x2B2622)], onAccent: Color(hex: 0xFAF6EE),
              bar: Color(hex: 0xFAF6EE), barText: Color(hex: 0x2B2622), wave: [Color(hex: 0x2B2622)],
              dot: Color(hex: 0xC23B2A), serif: true),
        Theme(id: "candy", zh: "糖果", en: "Candy", scheme: .light,
              background: Color(hex: 0xFFF6F1), text: Color(hex: 0x3A2A2A), link: Color(hex: 0xE5533F),
              accent: [Color(hex: 0xFF6B5B), Color(hex: 0xFF9A6B)],
              bar: .white, barText: Color(hex: 0x3A2A2A), wave: [Color(hex: 0xFF6B5B), Color(hex: 0x3CCFA9)],
              dot: Color(hex: 0xFF6B5B)),
        Theme(id: "dracula", zh: "Dracula", en: "Dracula", scheme: .dark,
              background: Color(hex: 0x282A36), text: Color(hex: 0xF8F8F2), link: Color(hex: 0xBD93F9),
              accent: [Color(hex: 0xBD93F9), Color(hex: 0xFF79C6)], onAccent: Color(hex: 0x282A36),
              bar: Color(hex: 0x282A36), barText: Color(hex: 0xF8F8F2), wave: [Color(hex: 0x50FA7B), Color(hex: 0x8BE9FD)],
              dot: Color(hex: 0xFF5555)),
        Theme(id: "nord", zh: "Nord", en: "Nord", scheme: .dark,
              background: Color(hex: 0x2E3440), text: Color(hex: 0xECEFF4), link: Color(hex: 0x88C0D0),
              accent: [Color(hex: 0x5E81AC), Color(hex: 0x88C0D0)],
              bar: Color(hex: 0x3B4252), barText: Color(hex: 0xECEFF4), wave: [Color(hex: 0x88C0D0)],
              dot: Color(hex: 0xBF616A)),
        Theme(id: "onedark", zh: "One Dark", en: "One Dark", scheme: .dark,
              background: Color(hex: 0x282C34), text: Color(hex: 0xABB2BF), link: Color(hex: 0x61AFEF),
              accent: [Color(hex: 0x61AFEF), Color(hex: 0xC678DD)], onAccent: Color(hex: 0x282C34),
              bar: Color(hex: 0x21252B), barText: Color(hex: 0xABB2BF), wave: [Color(hex: 0x61AFEF), Color(hex: 0x98C379)],
              dot: Color(hex: 0xE06C75)),
        Theme(id: "monokai", zh: "Monokai", en: "Monokai", scheme: .dark,
              background: Color(hex: 0x272822), text: Color(hex: 0xF8F8F2), link: Color(hex: 0x66D9EF),
              accent: [Color(hex: 0xA6E22E)], onAccent: Color(hex: 0x272822),
              bar: Color(hex: 0x272822), barText: Color(hex: 0xF8F8F2), wave: [Color(hex: 0xA6E22E), Color(hex: 0xFD971F)],
              dot: Color(hex: 0xF92672)),
        Theme(id: "solarized-light", zh: "Solarized 浅色", en: "Solarized Light", scheme: .light,
              background: Color(hex: 0xFDF6E3), text: Color(hex: 0x586E75), link: Color(hex: 0x268BD2),
              accent: [Color(hex: 0x268BD2), Color(hex: 0x2AA198)],
              bar: Color(hex: 0xEEE8D5), barText: Color(hex: 0x586E75), wave: [Color(hex: 0x268BD2), Color(hex: 0x2AA198)],
              dot: Color(hex: 0xDC322F)),
        Theme(id: "solarized-dark", zh: "Solarized 深色", en: "Solarized Dark", scheme: .dark,
              background: Color(hex: 0x002B36), text: Color(hex: 0x93A1A1), link: Color(hex: 0x2AA198),
              accent: [Color(hex: 0x268BD2), Color(hex: 0x2AA198)],
              bar: Color(hex: 0x073642), barText: Color(hex: 0x93A1A1), wave: [Color(hex: 0xB58900), Color(hex: 0x2AA198)],
              dot: Color(hex: 0xDC322F)),
        Theme(id: "github-light", zh: "GitHub Light", en: "GitHub Light", scheme: .light,
              background: .white, text: Color(hex: 0x1F2328), link: Color(hex: 0x0969DA),
              accent: [Color(hex: 0x1F883D)],
              bar: .white, barText: Color(hex: 0x1F2328), wave: [Color(hex: 0x0969DA)],
              dot: Color(hex: 0xCF222E)),
        Theme(id: "gruvbox", zh: "Gruvbox", en: "Gruvbox", scheme: .dark,
              background: Color(hex: 0x282828), text: Color(hex: 0xEBDBB2), link: Color(hex: 0xFABD2F),
              accent: [Color(hex: 0xD79921), Color(hex: 0xFE8019)], onAccent: Color(hex: 0x282828),
              bar: Color(hex: 0x32302F), barText: Color(hex: 0xEBDBB2), wave: [Color(hex: 0xB8BB26), Color(hex: 0xFABD2F)],
              dot: Color(hex: 0xFB4934)),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? cadabra }
}

extension EnvironmentValues {
    @Entry var theme = Theme.cadabra
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Colors a window's (or the menu's) root view.
    func themed(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .tint(theme.link)
            .foregroundStyle(theme.text.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
            .fontDesign(theme.serif ? .serif : nil)
            .modifier(Scheme(scheme: theme.scheme))
    }

    /// A window's content on the theme's background; forms keep their grouped rows on top of it.
    func themedBackground(_ theme: Theme) -> some View {
        scrollContentBackground(theme.background == nil ? .automatic : .hidden)
            .background(theme.background ?? .clear)
    }
}

private struct Scheme: ViewModifier {
    var scheme: ColorScheme?

    func body(content: Content) -> some View {
        if let scheme {
            content.environment(\.colorScheme, scheme).preferredColorScheme(scheme)
        } else {
            content.preferredColorScheme(nil)
        }
    }
}
