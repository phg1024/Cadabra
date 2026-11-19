import SwiftUI

enum Brand {
    /// Sky, indigo, violet: the app icon's tile (docs/visual-language.md).
    static let gradient = LinearGradient(
        colors: [Color(hex: 0x47A3FB), Color(hex: 0x546BFA), Color(hex: 0x9E52F2)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The mark inside the app icon, drawn on a unit tile: six sound bars, the wave of the first Cadabra
/// mark, with a big gold star at the top right, a small one at the bottom left and a gold dot in each of
/// the other corners (see docs/visual-language.md).
struct MagicMark: View {
    var bars: Color = .white

    static let gold = Color(hex: 0xF7C548)
    static let goldEdge = Color(hex: 0xE09A1F)

    var body: some View {
        Canvas { context, size in
            let s = size.width
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            // Six bars of uneven height, centered.
            let heights: [CGFloat] = [0.158, 0.414, 0.66, 0.344, 0.521, 0.221]
            let width: CGFloat = 0.06
            let xs: [CGFloat] = [0.240, 0.349, 0.450, 0.549, 0.655, 0.759]
            for (x, h) in zip(xs, heights) {
                let rect = CGRect(x: (x - width / 2) * s, y: (0.5 - h / 2) * s, width: width * s, height: h * s)
                context.fill(Path(roundedRect: rect, cornerRadius: width * s / 2), with: .color(bars))
            }
            Self.star(&context, center: p(0.80, 0.20), radius: 0.075 * s)
            Self.star(&context, center: p(0.21, 0.80), radius: 0.045 * s)
            for (x, y, r) in [(0.21, 0.22, 0.017), (0.80, 0.80, 0.015)] as [(CGFloat, CGFloat, CGFloat)] {
                context.fill(Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s)), with: .color(Self.gold))
            }
        }
    }

    /// A plump five-pointed star: rounded corners from a round-joined stroke in the same gold.
    static func star(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat) {
        var path = Path()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? radius : radius * 0.5
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        context.stroke(path, with: .color(goldEdge), style: StrokeStyle(lineWidth: radius * 0.42, lineJoin: .round))
        context.stroke(path, with: .color(gold), style: StrokeStyle(lineWidth: radius * 0.28, lineJoin: .round))
        context.fill(path, with: .color(gold))
    }
}

struct AppGlyph: View {
    var size: CGFloat
    /// The theme's version of the mark; nil (the menu bar, the Cadabra theme) is the brand's own.
    var theme: Theme?
    @Environment(\.theme) private var environmentTheme

    var body: some View {
        let theme = self.theme ?? environmentTheme
        let brand = theme.id == Theme.cadabra.id
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(brand ? Brand.gradient : theme.gradient)
            .overlay(MagicMark(bars: brand ? .white : theme.onAccent))
            .frame(width: size, height: size)
    }
}

/// The macOS app icon: a squircle on the standard 1024 grid with a little room for the shadow.
struct AppIconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Brand.gradient)
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .center)))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            MagicMark()
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct Keycap: View {
    var text: String
    var onColor = false
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(onColor ? theme.onAccent.opacity(0.22) : Color.primary.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(onColor ? theme.onAccent.opacity(0.35) : Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}

struct SectionLabel: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var compact = true
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.text)
                    .font(.system(size: 13))
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .opacity(hovering || copied ? 1 : 0)
                .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { copy() }
        .help(t("点击复制", "Click to copy"))
        .contextMenu {
            Button(t("复制", "Copy")) { copy() }
            if let onEdit { Button(t("改正…", "Correct…"), action: onEdit) }
            if let onDelete { Button(t("删除", "Delete"), role: .destructive, action: onDelete) }
        }
    }

    private var caption: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Preferences.shared.locale
        let when = Date().timeIntervalSince(entry.date) < 60 ? t("刚才", "just now") : formatter.localizedString(for: entry.date, relativeTo: Date())
        return t("\(when) · \(String(format: "%.1f", entry.duration)) 秒", "\(when) · \(String(format: "%.1f", entry.duration)) s")
    }

    private func copy() {
        TextInjector.copy(entry.text)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
    }
}

struct PermissionRow: View {
    var title: String
    var detail: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button(t("授权", "Grant"), action: action).controlSize(.small)
            }
        }
    }
}
