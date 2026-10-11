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
    static let ink3 = Color(uiColor: .systemGray) // tertiaryLabel was too faint for captions and amounts on white cards
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
    // Home and number-first layout; mirrors the block at the end of preview/web/styles.css.
    static let spent = Color(light: 0xAEAEB2, dark: 0x636366)
    static let ok = Color(light: 0x248A3D, dark: 0x30D158)
    static let okSoft = Color.green.opacity(0.15)
    static let sky = Color(light: 0xD6EAFB, dark: 0x12324F)
    static let skyInk = Color(light: 0x0B2A45, dark: 0xEAF4FF)
    static let sky2 = Color(light: 0xE7F0FA, dark: 0x1A2633)
    static let inkCard = Color(light: 0x111113, dark: 0x1C1C1E)
    static let pillOnText = Color(light: 0xFFFFFF, dark: 0x000000)
    // Depth: a hairline edge that reads in dark mode (where shadows don't) and the one brand gradient.
    #if canImport(UIKit)
    static let edge = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.09) : UIColor(white: 0, alpha: 0.04) })
    #else
    static let edge = Color.primary.opacity(0.06)
    #endif
    static let skyDeep = Color(light: 0xB9DBF8, dark: 0x0C2540)
    static let lanaGradient = LinearGradient(colors: [Color(light: 0x3FA2FF, dark: 0x3FA2FF), Color(light: 0x5E5CE6, dark: 0x6E6CF0)], startPoint: .topLeading, endPoint: .bottomTrailing)

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

/// Lifts a surface off the background: contact shadow, soft ambient shadow, hairline edge.
struct Raised: ViewModifier {
    var radius: CGFloat = 12
    var tint: Color = .black
    var strength: Double = 1
    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
            .shadow(color: .black.opacity(0.05 * strength), radius: 1, y: 1)
            .shadow(color: tint.opacity(0.10 * strength), radius: 16, y: 8)
    }
}
extension View {
    func raised(_ radius: CGFloat = 12, tint: Color = .black, strength: Double = 1) -> some View { modifier(Raised(radius: radius, tint: tint, strength: strength)) }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .raised(16)
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

struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white).background(fill.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: fill.opacity(0.28), radius: 10, y: 5)
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
