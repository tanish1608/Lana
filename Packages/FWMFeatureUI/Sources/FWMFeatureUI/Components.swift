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
            return (off + inset, max(off + inset, off + frac - inset), s.color)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            ForEach(Array(arcs.enumerated()), id: \.offset) { _, a in
                Circle().trim(from: a.start, to: grown ? a.end : a.start)
                    .stroke(a.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
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
                }
                .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// The question this screen answers, as it was asked in Messages.
struct AskChip: View {
    let question: String
    init(_ question: String) { self.question = question }
    var body: some View {
        Label(question, systemImage: "message.fill").font(.footnote.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .foregroundStyle(Theme.accent).background(Theme.accentSoft, in: Capsule())
            .accessibilityLabel("Asked in Messages: \(question)")
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
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
