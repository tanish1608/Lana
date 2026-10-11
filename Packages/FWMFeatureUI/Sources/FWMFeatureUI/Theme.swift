import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// One restrained accent on warm neutrals; mirrors preview/web/styles.css.
enum Theme {
    static let bg = Color(light: 0xFAF8F4, dark: 0x161614)
    static let card = Color(light: 0xFFFFFF, dark: 0x1F1E1B)
    static let ink = Color(light: 0x1B1A17, dark: 0xF3F0EA)
    static let ink2 = Color(light: 0x5B574F, dark: 0xB5B0A6)
    static let ink3 = Color(light: 0x8C877D, dark: 0x7F7A71)
    static let line = Color(light: 0xE4DFD6, dark: 0x2D2B27)
    static let accent = Color(light: 0x12664F, dark: 0x5CC29F)
    static let accent2 = Color(light: 0x3E8E74, dark: 0x3E9C7D)
    static let accent3 = Color(light: 0x8FC2AE, dark: 0x2B6E58)
    static let accentSoft = Color(light: 0xE2F0EA, dark: 0x16302A)
    static let goes = Color(light: 0xB9B2A6, dark: 0x5A5650)
    static let warn = Color(light: 0xA35A12, dark: 0xE8A65C)
    static let warnSoft = Color(light: 0xFBEBD8, dark: 0x33261A)
    static let bad = Color(light: 0xA3322A, dark: 0xEE8A80)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .medium, design: .serif) }
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
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Theme.ink3)
            .padding(.top, 18).padding(.horizontal, 4)
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
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line)); Spacer(minLength: 40) }
        }
        .font(.subheadline)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(.white).background(fill, in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
            .foregroundStyle(Theme.ink).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
