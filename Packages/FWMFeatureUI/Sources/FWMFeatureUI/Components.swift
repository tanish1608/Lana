import SwiftUI

/// One big amount with a small currency sign and small cents. The number is the headline; keep copy around it short.
struct HeroAmount: View {
    let cents: Int
    var size: CGFloat = 56
    var body: some View {
        let a = abs(cents)
        HStack(alignment: .top, spacing: 1) {
            Text((cents < 0 ? "−" : "") + "$").font(.system(size: size * 0.42, weight: .bold)).padding(.top, size * 0.12)
            Text(String(usd((a / 100) * 100).dropFirst())).font(.system(size: size, weight: .bold)).tracking(-size * 0.04)
            Text(String(format: ".%02d", a % 100)).font(.system(size: size * 0.38, weight: .bold)).opacity(0.75).padding(.top, size * 0.14)
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        .accessibilityElement().accessibilityLabel(usd(cents, cents: true))
    }
}

/// Ring of proportional segments with rounded ends and content in the middle.
struct RingChart<Center: View>: View {
    struct Segment: Identifiable { var id: String { label }; let label: String; let cents: Int; let color: Color }
    let segments: [Segment]
    let total: Int
    var diameter: CGFloat = 200
    var lineWidth: CGFloat = 22
    @ViewBuilder var center: Center
    @State private var grown = false

    private var arcs: [(start: CGFloat, end: CGFloat, color: Color)] {
        // Round caps overhang each end by half the line width; inset so neighbours don't overlap.
        let inset = (lineWidth / 2 + 2) / (.pi * (diameter - lineWidth))
        let t = CGFloat(max(total, 1))
        var off: CGFloat = 0
        return segments.map { s in
            let frac = CGFloat(s.cents) / t
            defer { off += frac }
            if segments.count == 1 && frac >= 1 { return (0, 1, s.color) } // a full ring closes with no gap
            return (off + inset, max(off + inset, off + frac - inset), s.color)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, a in
                Circle().trim(from: a.start, to: grown ? a.end : a.start)
                    .stroke(a.color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: a.color.opacity(0.3), radius: 5, y: 3)
            }
            center
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .onAppear { withAnimation(.spring(duration: 0.9)) { grown = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(segments.map { "\($0.label) \(usd($0.cents))" }.joined(separator: ", "))
    }
}

/// Capsule tabs; the selected pill is label-colored (black on light, white on dark).
struct PillPicker<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { o in
                let on = o.value == selection
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = o.value } } label: {
                    Text(o.label).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(on ? Theme.pillOnText : Theme.ink)
                        .background(on ? Theme.ink : Theme.card, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.glassEdge))
                        .shadow(color: .black.opacity(on ? 0.18 : 0.04), radius: on ? 8 : 3, y: on ? 4 : 1)
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// One-line reconciliation, shown only when the numbers actually add up.
struct CheckLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "checkmark").font(.footnote.weight(.semibold)).monospacedDigit()
            .foregroundStyle(Theme.ok).padding(.horizontal, 4)
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink2) }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A PNG bundled with the package (Resources/).
private func brandImage(_ name: String) -> Image? {
    #if canImport(UIKit)
    UIImage(named: name, in: .module, with: nil).map { Image(uiImage: $0) }
    #else
    Bundle.module.image(forResource: name).map { Image(nsImage: $0) }
    #endif
}

/// The Lana mark (Resources/LanaMark.png).
struct LanaMark: View {
    var size: CGFloat = 30
    var body: some View {
        Group { if let i = brandImage("LanaMark") { i.resizable().interpolation(.high) } }
            .scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Mark plus wordmark, for the top of Home. The wordmark is a template: navy on light, white on dark.
struct LanaLogo: View {
    var body: some View {
        HStack(spacing: 7) {
            LanaMark(size: 30)
            if let w = brandImage("LanaWordmark") {
                w.renderingMode(.template).resizable().interpolation(.high).scaledToFit().frame(height: 24).foregroundStyle(Theme.logoInk)
            }
        }
        .accessibilityElement().accessibilityLabel("Lana").accessibilityAddTraits(.isHeader)
    }
}
