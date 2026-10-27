import AGUsageCore
import AppKit
import SwiftUI

// MARK: - Background

/// Native translucent HUD background (blurs what's behind the window).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// MARK: - Colors

enum Palette {
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let running = Color(red: 0.30, green: 0.85, blue: 0.55)

    static let input = Color(red: 0.40, green: 0.62, blue: 1.0)
    static let cache = Color(red: 0.55, green: 0.48, blue: 0.95)
    static let output = Color(red: 0.32, green: 0.85, blue: 0.75)

    /// Stable color per model family / name.
    static func model(_ name: String) -> Color {
        let lower = name.lowercased()
        let hue: Double
        if lower.contains("claude") || lower.contains("opus") || lower.contains("sonnet") {
            hue = 0.06 // warm orange
        } else if lower.contains("gemini") {
            hue = lower.contains("pro") ? 0.72 : 0.60 // purple for Pro, blue for Flash
        } else if lower.contains("gpt") || lower.contains("oss") {
            hue = 0.42
        } else if name == unknownModel {
            return .gray
        } else {
            // Deterministic hash → hue (avoid Swift's randomized hashValue).
            let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            hue = Double(sum % 360) / 360
        }
        // Vary brightness by effort level so variants of the same family differ.
        let brightness: Double = lower.contains("high") ? 1.0 : lower.contains("low") ? 0.72 : 0.86
        return Color(hue: hue, saturation: 0.62, brightness: brightness)
    }

    static func source(_ source: AgySource) -> Color {
        switch source {
        case .cli: return Color(red: 0.36, green: 0.80, blue: 0.60)
        case .app: return Color(red: 0.95, green: 0.60, blue: 0.35)
        case .ide: return Color(red: 0.45, green: 0.60, blue: 1.0)
        }
    }
}

// MARK: - Small building blocks

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct Pill: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

struct StatBlock: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Horizontal stacked bar showing the input / cached / output split.
struct TokenSplitBar: View {
    let totals: TokenTotals

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(totals.total), 1)
            HStack(spacing: 1.5) {
                segment(totals.input, Palette.input, total, geo.size.width)
                segment(totals.cacheRead, Palette.cache, total, geo.size.width)
                segment(totals.output, Palette.output, total, geo.size.width)
            }
        }
        .frame(height: 5)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func segment(_ value: Int, _ color: Color, _ total: Double, _ width: CGFloat) -> some View {
        if value > 0 {
            color.frame(width: max(2, width * CGFloat(Double(value) / total)))
        }
    }
}

/// A row with a label, a proportional bar and trailing numbers.
struct ProportionRow: View {
    let color: Color
    let title: String
    let value: String
    let detail: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                Text(detail)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(color.opacity(0.85))
                    .frame(width: max(3, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
            .frame(height: 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }
}

/// Minimal 14-day bar chart (no Charts dependency so it stays crisp at tiny sizes).
struct DailyBars: View {
    let days: [DailyUsage]
    @State private var hovered: Date?

    var body: some View {
        let maxValue = max(days.map(\.totals.total).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days) { day in
                    let isToday = Calendar.current.isDateInToday(day.day)
                    let fraction = CGFloat(Double(day.totals.total) / Double(maxValue))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isToday ? Palette.accent : Palette.accent.opacity(hovered == day.day ? 0.8 : 0.45))
                        .frame(height: max(2, 34 * fraction))
                        .frame(maxWidth: .infinity)
                        .onHover { inside in hovered = inside ? day.day : (hovered == day.day ? nil : hovered) }
                        .help("\(Self.dayFormatter.string(from: day.day)): \(UsageFormat.tokens(day.totals.total)) tokens · \(day.totals.requests) requests")
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack {
                if let hovered, let day = days.first(where: { $0.day == hovered }) {
                    Text("\(Self.dayFormatter.string(from: day.day)) · \(UsageFormat.tokens(day.totals.total)) · \(day.totals.requests) req")
                } else if let first = days.first {
                    Text(Self.dayFormatter.string(from: first.day))
                    Spacer()
                    Text("Today")
                }
            }
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f
    }()
}

struct PulsingDot: View {
    let color: Color
    var active = true
    @State private var pulse = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse ? 1.25 : 0.6)
                    .opacity(pulse ? 0 : 1)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            guard active else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

enum RelativeTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<10: return "now"
        case ..<60: return "\(s)s ago"
        case ..<3600: return "\(s / 60)m ago"
        case ..<86_400: return "\(s / 3600)h ago"
        default: return "\(s / 86_400)d ago"
        }
    }
}
