import SwiftUI
import Charts
import FinanceAI

/// A compact chart of a tool result's own figures, drawn under a chat reply.
struct ChatChartView: View {
    let chart: ChatChart
    private var maxCents: Int { chart.points.map { max($0.cents, $0.secondCents ?? 0) }.max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chart.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink2)
            switch chart.style {
            case .bars:
                Chart(Array(chart.points.enumerated()), id: \.offset) { i, p in
                    BarMark(x: .value("Amount", Double(p.cents) / 100), y: .value("Label", p.label))
                        .foregroundStyle(Self.palette[i % Self.palette.count].gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(usd(p.cents)).font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.ink2)
                        }
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...(Double(maxCents) / 100 * 1.3))
                .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: CGFloat(chart.points.count) * 24 + 8)
            case .columns:
                Chart(Array(chart.points.enumerated()), id: \.offset) { _, p in
                    BarMark(x: .value("Month", p.label), y: .value("Amount", Double(p.cents) / 100))
                        .foregroundStyle(Theme.lanaGradient).cornerRadius(4)
                        .annotation(position: .top) { Text(usd(p.cents)).font(.caption2).monospacedDigit().foregroundStyle(Theme.ink2) }
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .frame(height: 130)
            case .comparison:
                let names = chart.series ?? ["Now", "Plan"]
                Chart {
                    ForEach(Array(chart.points.enumerated()), id: \.offset) { _, p in
                        BarMark(x: .value("Amount", Double(p.cents) / 100), y: .value("Category", p.label))
                            .foregroundStyle(by: .value("Series", names[0])).position(by: .value("Series", names[0]))
                        BarMark(x: .value("Amount", Double(p.secondCents ?? p.cents) / 100), y: .value("Category", p.label))
                            .foregroundStyle(by: .value("Series", names[1])).position(by: .value("Series", names[1]))
                            .annotation(position: .trailing, alignment: .leading) {
                                Text(usd((p.secondCents ?? p.cents) - p.cents, plus: true)).font(.caption2.weight(.semibold)).foregroundStyle(Theme.ok)
                            }
                    }
                }
                .chartForegroundStyleScale([names[0]: Theme.spent, names[1]: Theme.accent])
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...(Double(maxCents) / 100 * 1.3))
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: CGFloat(chart.points.count) * 40 + 30)
            }
        }
        .padding(10)
        .background(Theme.card.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chart.title): " + chart.points.map { "\($0.label) \(usd($0.cents))" + ($0.secondCents.map { " to \(usd($0))" } ?? "") }.joined(separator: ", "))
    }

    static let palette: [Color] = [Theme.accent, Color(light: 0x5E5CE6, dark: 0x7D7AFF), Color(light: 0x30B0C7, dark: 0x40C8E0),
                                   Color(light: 0x34C759, dark: 0x30D158), Color(light: 0xFF9F0A, dark: 0xFFB340), Color(light: 0xFF375F, dark: 0xFF6482)]
}

/// A change the chat proposed. Confirm performs it through the host; nothing happens before that.
struct ChatActionCard: View {
    let action: ChatAction
    var busy: Bool
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.white).frame(width: 30, height: 30)
                    .background(Theme.lanaGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.subheadline.weight(.semibold))
                    Text(action.detail).font(.caption).foregroundStyle(Theme.ink2)
                }
            }
            switch action.status {
            case .proposed:
                HStack(spacing: 8) {
                    Button { confirm() } label: {
                        Label(action.confirmLabel, systemImage: action.requiresAuthentication ? "faceid" : "checkmark")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 14).frame(minHeight: 34)
                            .background(Theme.accent.gradient, in: Capsule())
                    }
                    Button("Not now", action: cancel).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink2).padding(.horizontal, 10).frame(minHeight: 34)
                }
                .disabled(busy)
            case .done:
                Label(action.result ?? "Done", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.ok)
            case .cancelled:
                Label(action.result ?? "Cancelled", systemImage: "xmark.circle").font(.caption).foregroundStyle(Theme.ink3)
            case .failed:
                Label(action.result ?? "Couldn’t do that", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.warn)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(action.status == .proposed ? 0.45 : 0.12), lineWidth: 1))
    }

    private var icon: String {
        switch action.kind {
        case "keep_idea": return "hand.thumbsup.fill"
        case "skip_idea": return "hand.thumbsdown.fill"
        case "adopt_plan": return "checkmark.seal.fill"
        case "mark_request": return "person.crop.circle.badge.checkmark"
        case "recategorize": return "tag.fill"
        case "remove_account": return "minus.circle.fill"
        default: return "arrow.up.forward.app.fill"
        }
    }
}
