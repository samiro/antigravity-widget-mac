import AGUsageCore
import AppKit
import SwiftUI

// MARK: - Apple Refined Palette

enum Palette {
    static let accent = Color(red: 0.20, green: 0.55, blue: 1.0)        // System Blue
    static let warning = Color(red: 1.0, green: 0.62, blue: 0.10)       // System Orange
    static let alert = Color(red: 1.0, green: 0.27, blue: 0.27)         // System Red
    static let running = Color(red: 0.20, green: 0.82, blue: 0.48)       // System Green

    // Token telemetry split: Blue (input) -> Purple (cache) -> Mint (output)
    static let input = Color(red: 0.25, green: 0.58, blue: 1.0)
    static let cache = Color(red: 0.62, green: 0.42, blue: 0.95)
    static let output = Color(red: 0.18, green: 0.82, blue: 0.72)

    /// Stable color per model family in clean Apple design language
    static func model(_ name: String) -> Color {
        let lower = name.lowercased()
        if lower.contains("claude") || lower.contains("opus") || lower.contains("sonnet") {
            return Color(red: 0.96, green: 0.55, blue: 0.28) // Warm coral
        } else if lower.contains("argon") {
            return Color(red: 0.18, green: 0.75, blue: 0.98) // Azure
        } else if lower.contains("flash") {
            return Color(red: 0.25, green: 0.60, blue: 1.0)  // Blue
        } else if lower.contains("gemini") {
            return Color(red: 0.65, green: 0.45, blue: 0.95) // Purple
        } else if lower.contains("gpt") || lower.contains("oss") {
            return Color(red: 0.20, green: 0.78, blue: 0.60) // Mint
        } else if name == unknownModel {
            return Color.gray
        } else {
            let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
            let hues = [0.58, 0.08, 0.78, 0.38, 0.88]
            return Color(hue: hues[sum % hues.count], saturation: 0.65, brightness: 0.95)
        }
    }

    static func source(_ source: AgySource) -> Color {
        switch source {
        case .cli: return Color(red: 0.22, green: 0.80, blue: 0.52)
        case .app: return Color(red: 0.98, green: 0.60, blue: 0.25)
        case .ide: return Color(red: 0.30, green: 0.62, blue: 1.0)
        }
    }
}

// MARK: - Quota Badge & UI Elements

/// Segmented bar indicating consumed vs remaining time window in neon blue.
struct SegmentedQuotaBar: View {
    let totalBars: Int
    let filledBars: Int
    var size: WidgetSize = .normal
    var activeColor: Color = Color(red: 0.30, green: 0.82, blue: 1.0) // light neon blue (consumed time)
    var inactiveColor: Color = Color(red: 0.22, green: 0.55, blue: 0.85).opacity(0.25) // opaque/dim blue (remaining time)

    var body: some View {
        HStack(spacing: size.progressBarSpacing) {
            ForEach(0..<totalBars, id: \.self) { index in
                let isFilled = index < filledBars
                RoundedRectangle(cornerRadius: size.progressBarCornerRadius, style: .continuous)
                    .fill(
                        isFilled
                            ? LinearGradient(
                                colors: [
                                    activeColor.opacity(0.95),
                                    activeColor
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [
                                    inactiveColor,
                                    inactiveColor.opacity(0.8)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    .frame(width: size.progressBarWidth, height: size.progressBarHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: size.progressBarCornerRadius, style: .continuous)
                            .strokeBorder(
                                isFilled ? Color.white.opacity(size == .large ? 0.35 : 0.15) : Color.clear,
                                lineWidth: size == .large ? 0.7 : 0.5
                            )
                    )
                    .shadow(
                        color: isFilled && size == .large ? activeColor.opacity(0.4) : Color.clear,
                        radius: 2,
                        x: 0,
                        y: 0
                    )
            }
        }
    }
}

/// Clean macOS-styled quota badge with segmented time-elapsed bars and quota percentage.
struct QuotaBadge: View {
    let label: String
    let percent: Int
    let reset: Date?
    var size: WidgetSize = .normal

    private var totalBars: Int {
        label.contains("Wk") ? 7 : 5
    }

    private var filledBars: Int {
        let totalSeconds: Double = label.contains("Wk") ? (7 * 86400) : (5 * 3600)
        let fraction: Double
        if let reset {
            let remaining = max(0, reset.timeIntervalSince(Date()))
            let elapsed = max(0, totalSeconds - remaining)
            fraction = min(max(elapsed / totalSeconds, 0.0), 1.0)
        } else {
            fraction = min(max(Double(100 - percent) / 100.0, 0.0), 1.0)
        }
        return min(totalBars, max(0, Int(round(fraction * Double(totalBars)))))
    }

    var body: some View {
        HStack(spacing: size == .large ? 5 : 3.5) {
            Text(label)
                .font(.system(size: size.badgeLabelFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))

            SegmentedQuotaBar(
                totalBars: totalBars,
                filledBars: filledBars,
                size: size
            )

            Text("\(percent)%")
                .font(.system(size: size.badgePercentFontSize, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(percentColor)
        }
        .padding(.horizontal, size == .large ? 8 : (size == .small ? 5 : 6))
        .padding(.vertical, size == .large ? 3.5 : (size == .small ? 2 : 2.5))
        .background(Color.white.opacity(0.06), in: Capsule())
        .help(tooltipText)
    }

    private var percentColor: Color {
        if percent > 40 { return Palette.running }
        if percent >= 15 { return Palette.warning }
        return Palette.alert
    }

    private var tooltipText: String {
        let unit = label.contains("Wk") ? "day(s)" : "hour(s)"
        let resetStr = reset.map { " (resets in \(ModelQuotaLimits.formatCountdown($0)))" } ?? ""
        return "\(label): \(filledBars)/\(totalBars) \(unit) elapsed · \(percent)% remaining\(resetStr)"
    }
}

typealias GlassQuotaBadge = QuotaBadge

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

struct Pill: View {
    let systemImage: String
    let text: String
    var tint: Color = Palette.accent
    var size: WidgetSize = .normal

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: size.badgeLabelFontSize, weight: .bold))
            Text(text).font(.system(size: size.badgePercentFontSize, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, size == .large ? 8 : (size == .small ? 5 : 6.5))
        .padding(.vertical, size == .large ? 3.5 : (size == .small ? 2 : 2.5))
        .background(tint.opacity(0.16), in: Capsule())
    }
}

struct StatBlock: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Horizontal stacked bar showing the input / cached / output split with liquid sheen.
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
        .background(Color.white.opacity(0.08), in: Capsule())
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func segment(_ value: Int, _ color: Color, _ total: Double, _ width: CGFloat) -> some View {
        if value > 0 {
            color.frame(width: max(2, width * CGFloat(Double(value) / total)))
        }
    }
}

/// A row with a label, a proportional liquid bar and trailing numbers.
struct ProportionRow: View {
    let color: Color
    let title: String
    let value: String
    let detail: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 9.5, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(minWidth: 44, alignment: .trailing)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.9), color.opacity(0.6)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(3, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
            .frame(height: 3.5)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
    }
}

/// Clean 14-day equalizer spectrum analyzer chart.
struct DailyBars: View {
    let days: [DailyUsage]
    @State private var hovered: Date?

    var body: some View {
        let maxValue = max(days.map(\.totals.total).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3.5) {
                ForEach(days) { day in
                    let isToday = Calendar.current.isDateInToday(day.day)
                    let fraction = CGFloat(Double(day.totals.total) / Double(maxValue))
                    let barColor = isToday ? Palette.accent : Color.white.opacity(hovered == day.day ? 0.75 : 0.40)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(barColor)
                        .frame(height: max(3, 34 * fraction))
                        .frame(maxWidth: .infinity)
                        .onHover { inside in hovered = inside ? day.day : (hovered == day.day ? nil : hovered) }
                        .help("\(Self.dayFormatter.string(from: day.day)): \(UsageFormat.tokens(day.totals.total)) tokens · \(day.totals.requests) requests")
                }
            }
            .frame(height: 34, alignment: .bottom)
            HStack {
                if let hovered, let day = days.first(where: { $0.day == hovered }) {
                    Text("\(Self.dayFormatter.string(from: day.day)) · \(UsageFormat.tokens(day.totals.total)) · \(day.totals.requests) req")
                        .foregroundStyle(.white.opacity(0.9))
                } else if let first = days.first {
                    Text(Self.dayFormatter.string(from: first.day))
                    Spacer()
                    Text("Today")
                        .foregroundStyle(Palette.accent)
                }
            }
            .font(.system(size: 9, weight: .regular, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return f
    }()
}

/// Liquid Glass Sonar Ping Dot.
struct PulsingDot: View {
    let color: Color
    var active = true
    var size: WidgetSize = .normal
    @State private var pulse = false

    private var diameter: CGFloat { size.dotDiameter }
    private var containerSize: CGFloat { size == .large ? 18 : (size == .small ? 12 : 14) }

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: size == .large ? 1.5 : 1)
                    .frame(width: containerSize, height: containerSize)
                    .scaleEffect(pulse ? 1.4 : 0.8)
                    .opacity(pulse ? 0 : 0.9)
            }
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
        .frame(width: containerSize, height: containerSize)
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
