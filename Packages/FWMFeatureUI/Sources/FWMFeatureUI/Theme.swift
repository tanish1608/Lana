import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// Apple-native palette: system grouped backgrounds, semantic label colors, one system accent (blue).
// Mirrors preview/web/styles.css.
enum Theme {
    #if canImport(UIKit)
    static let bg = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let ink = Color(uiColor: .label)
    static let ink2 = Color(uiColor: .secondaryLabel)
    static let ink3 = Color(uiColor: .tertiaryLabel)
    static let line = Color(uiColor: .tertiarySystemFill)
    #else
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let ink = Color(nsColor: .labelColor)
    static let ink2 = Color(nsColor: .secondaryLabelColor)
    static let ink3 = Color(nsColor: .tertiaryLabelColor)
    static let line = Color(nsColor: .quaternaryLabelColor)
    #endif
    static let accent = Color.blue
    static let accent2 = Color.blue.opacity(0.6)
    static let accent3 = Color.blue.opacity(0.3)
    static let accentSoft = Color.blue.opacity(0.12)
    static let goes = Color(light: 0xC7C7CC, dark: 0x48484A)
    static let warn = Color.orange
    static let warnSoft = Color.orange.opacity(0.15)
    static let bad = Color.red
    static let bubbleIn = Color(light: 0xE9E9EB, dark: 0x26252A)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

/// Formats integer cents at the display boundary. Whole dollars drop the cents unless `cents` is true.
func usd(_ cents: Int, cents showCents: Bool = false, plus: Bool = false) -> String {
    let neg = cents < 0, a = abs(cents)
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    let dollars = f.string(from: NSNumber(value: a / 100)) ?? String(a / 100)
    let frac = (showCents || a % 100 != 0) ? String(format: ".%02d", a % 100) : ""
    return (neg ? "−" : (plus ? "+" : "")) + "$" + dollars + frac
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.footnote).foregroundStyle(Theme.ink2)
            .padding(.top, 18).padding(.horizontal, 16)
    }
}

/// Visible marker for anything simulated in a fixture-backed build.
struct SimulatedNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "diamond.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.warn)
            .labelStyle(.titleAndIcon)
    }
}

struct Tag: View {
    let text: String
    var tone: Color = Theme.ink2
    var fill: Color = Theme.line
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tone).background(fill, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Left-to-right rows that wrap when the next item doesn't fit (status chips on a phone-width card).
struct WrapLayout: Layout {
    var spacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]], x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += (row.map(\.size.height).max() ?? 0) + spacing
        }
    }
}

struct MessagePreview: View {
    let question: String
    let answer: String
    var body: some View {
        VStack(spacing: 6) {
            Text("From Messages").font(.caption2).foregroundStyle(Theme.ink3)
            HStack { Spacer(minLength: 50); Text(question).padding(.horizontal, 13).padding(.vertical, 9).foregroundStyle(.white)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 18)) }
            HStack { Text(answer).padding(.horizontal, 13).padding(.vertical, 9).foregroundStyle(Theme.ink)
                .background(Theme.bubbleIn, in: RoundedRectangle(cornerRadius: 18)); Spacer(minLength: 40) }
        }
        .font(.subheadline)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white).background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).padding(.horizontal, 16).frame(minHeight: 44)
            .foregroundStyle(Theme.accent).background(Theme.line, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
