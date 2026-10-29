import AGUsageCore
import AppKit
import SwiftUI

/// Lets the root view tell the panel how big it wants to be.
@MainActor
final class SizeRelay {
    var onChange: ((CGSize) -> Void)?
}

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct WidgetRootView: View {
    @ObservedObject var model: WidgetModel
    let sizeRelay: SizeRelay
    var actions: WidgetActions

    var body: some View {
        Group {
            if model.expanded {
                ExpandedView(model: model, actions: actions)
                    .frame(width: 345)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                CompactView(model: model)
                    .background(.regularMaterial, in: Capsule())
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .opacity(model.opacity)
        .fixedSize()
        .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
        .onPreferenceChange(SizeKey.self) { size in
            MainActor.assumeIsolated { sizeRelay.onChange?(size) }
        }
        .contextMenu { WidgetMenuItems(model: model, actions: actions) }
        .environment(\.colorScheme, .dark)
    }
}

/// Callbacks into AppKit-land (implemented by the app delegate).
struct WidgetActions {
    var hide: () -> Void = {}
    var quit: () -> Void = {}
    var refresh: () -> Void = {}
    var openDataFolder: () -> Void = {}
    var resetPosition: () -> Void = {}
    var openTranscript: (ConversationInfo) -> Void = { _ in }
}

// MARK: - Compact View (Translucent Liquid Glass Pill)

struct CompactView: View {
    @ObservedObject var model: WidgetModel

    var body: some View {
        let snap = model.snapshot
        let activeModel = model.activeCompactModelName
        let usage = model.activeCompactModelUsage
        let limits = model.activeModelQuota

        HStack(spacing: 9) {
            PulsingDot(color: statusColor, active: !snap.running.isEmpty || !snap.pendingApprovals.isEmpty)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Palette.model(activeModel))
                        .frame(width: 6.5, height: 6.5)

                    Text(UsageFormat.shortModel(activeModel))
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    // 5-Hour Limit Remaining
                    if let fiveH = limits.fiveHourPercent {
                        GlassQuotaBadge(label: "5H", percent: fiveH, reset: limits.fiveHourReset)
                    }

                    // Weekly Limit Remaining
                    if let weekly = limits.weeklyPercent {
                        GlassQuotaBadge(label: "Wk", percent: weekly, reset: limits.weeklyReset)
                    }
                }

                HStack(spacing: 4) {
                    Text(usage.total > 0 ? UsageFormat.tokens(usage.total) : "0")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.95))
                    Text("tokens")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("·")
                        .foregroundStyle(.white.opacity(0.3))

                    if usage.requests > 0 {
                        Text("\(usage.requests)")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.95))
                        Text("req")
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                        Text("·")
                            .foregroundStyle(.white.opacity(0.3))
                    }

                    if let countdown = limits.resetCountdownString {
                        Text(countdown)
                            .font(.system(size: 9, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .lineLimit(1)
            }

            if !snap.running.isEmpty {
                Pill(systemImage: "bolt.fill", text: "\(snap.running.count)", tint: Palette.running)
                    .help("\(snap.running.count) conversation(s) running")
            }
            if !snap.pendingApprovals.isEmpty {
                Pill(systemImage: "hand.raised.fill", text: "\(snap.pendingApprovals.count)", tint: Palette.warning)
                    .help("\(snap.pendingApprovals.count) tool call(s) waiting for approval")
            }

            Menu {
                Section("Select Model for Compact View") {
                    ForEach(model.availableModelOptions) { opt in
                        Button {
                            model.selectedCompactModel = opt.name
                        } label: {
                            let prefix = opt.isSelected ? "✓ " : "   "
                            let usageInfo = opt.tokens > 0 ? " (\(UsageFormat.tokens(opt.tokens)))" : ""
                            Text("\(prefix)\(opt.name) — \(opt.limitsDescription)\(usageInfo)")
                        }
                    }
                }

                if model.selectedCompactModel != nil {
                    Divider()
                    Button("Auto-follow Active CLI Model") {
                        model.selectedCompactModel = nil
                    }
                }

                Divider()
                Button("Expand Detailed View") {
                    withAnimation(.snappy(duration: 0.2)) { model.expanded = true }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose model for compact view (or expand)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .contentShape(Capsule())
        .onTapGesture(count: 2) { withAnimation(.snappy(duration: 0.2)) { model.expanded = true } }
    }

    private var statusColor: Color {
        if !model.snapshot.pendingApprovals.isEmpty { return Palette.warning }
        if !model.snapshot.running.isEmpty { return Palette.running }
        return .white.opacity(0.4)
    }
}

// MARK: - Expanded View (Translucent Liquid Glass Card)

struct ExpandedView: View {
    @ObservedObject var model: WidgetModel
    var actions: WidgetActions

    var body: some View {
        let snap = model.snapshot
        let summary = model.summary

        VStack(alignment: .leading, spacing: 13) {
            header(snap)

            rangeSelector

            if !snap.pendingApprovals.isEmpty {
                approvals(snap.pendingApprovals)
            }

            totals(summary)

            quotaSection(snap)

            if summary.daily.contains(where: { $0.totals.total > 0 || $0.totals.requests > 0 }) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: "Last 14 days")
                    DailyBars(days: summary.daily)
                }
            }

            models(summary)

            if summary.bySource.count > 1 {
                sources(summary)
            }

            conversations(snap)

            footer(snap)
        }
        .padding(18)
    }

    // MARK: - Sections

    private func header(_ snap: UsageSnapshot) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Palette.accent, Palette.cache],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 25, height: 25)

            VStack(alignment: .leading, spacing: 1) {
                Text("Antigravity")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 5) {
                    if let current = snap.currentModel {
                        Circle()
                            .fill(Palette.model(current))
                            .frame(width: 6, height: 6)
                    }
                    Text(snap.currentModel ?? (model.hasLoaded ? "No model selected" : "Loading…"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                iconButton("arrow.clockwise", help: "Refresh telemetry", action: actions.refresh)
                iconButton("chevron.up", help: "Collapse") {
                    withAnimation(.snappy(duration: 0.2)) { model.expanded = false }
                }
                iconButton("xmark", help: "Hide widget", action: actions.hide)
            }
        }
    }

    private var rangeSelector: some View {
        HStack(spacing: 3) {
            ForEach(UsageRange.allCases) { range in
                let isSelected = model.range == range
                Button {
                    model.range = range
                } label: {
                    Text(range.label)
                        .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                        .padding(.vertical, 4.5)
                        .frame(maxWidth: .infinity)
                        .background(
                            isSelected ? Color.white.opacity(0.18) : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func approvals(_ pending: [PendingApproval]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PulsingDot(color: Palette.warning)
                Text(pending.count == 1 ? "Waiting for your approval" : "\(pending.count) approvals waiting")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.warning)
            }
            ForEach(pending) { approval in
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
                    Text(approval.tool)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                    Text(model.conversationTitle(approval.conversationID) ?? "step \(approval.step)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeTime.short(approval.surfacedAt, now: model.snapshot.generatedAt))
                        .font(.system(size: 9.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(9)
        .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func totals(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormat.tokens(summary.totals.total))
                    .font(.system(size: 27, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("tokens")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(summary.totals.requests) requests")
                    Text("\(summary.conversationCount) conversations")
                }
                .font(.system(size: 10, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
            TokenSplitBar(totals: summary.totals)
            HStack(spacing: 6) {
                StatBlock(label: "Input", value: UsageFormat.tokens(summary.totals.input), color: Palette.input)
                StatBlock(label: "Cached", value: UsageFormat.tokens(summary.totals.cacheRead), color: Palette.cache)
                StatBlock(label: "Output", value: UsageFormat.tokens(summary.totals.output), color: Palette.output)
                StatBlock(label: "Cache hit", value: UsageFormat.percent(summary.totals.cacheHitRate), color: .white.opacity(0.7))
            }
        }
        .padding(13)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func quotaSection(_ snap: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Quota Remaining")
            VStack(spacing: 5) {
                ForEach(snap.quota.groups) { group in
                    HStack(spacing: 7) {
                        Text(group.name)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                        Spacer()
                        if let f = group.fiveHourBucket {
                            QuotaBadge(label: "5H", percent: f.remainingPercent, reset: f.resetTime)
                        } else if group.name.contains("Argon"), let gemini5h = snap.quota.geminiGroup?.fiveHourBucket {
                            QuotaBadge(label: "5H", percent: gemini5h.remainingPercent, reset: gemini5h.resetTime)
                        }
                        if let w = group.weeklyBucket {
                            QuotaBadge(label: "Wk", percent: w.remainingPercent, reset: w.resetTime)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func models(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Models", trailing: summary.byModel.isEmpty ? nil : "\(summary.byModel.count)")
            if summary.byModel.isEmpty {
                Text("No model calls in this period")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            let maxTokens = max(summary.byModel.map(\.totals.total).max() ?? 0, 1)
            let maxRequests = max(summary.byModel.map(\.totals.requests).max() ?? 0, 1)
            ForEach(summary.byModel.prefix(6)) { usage in
                let useTokens = usage.totals.total > 0
                ProportionRow(
                    color: Palette.model(usage.model),
                    title: usage.model,
                    value: useTokens ? UsageFormat.tokens(usage.totals.total) : "—",
                    detail: "\(usage.totals.requests) req",
                    fraction: useTokens ? Double(usage.totals.total) / Double(maxTokens)
                        : Double(usage.totals.requests) / Double(maxRequests)
                )
                .help("\(usage.model)\nInput \(UsageFormat.tokens(usage.totals.input)) · Cached \(UsageFormat.tokens(usage.totals.cacheRead)) · Output \(UsageFormat.tokens(usage.totals.output))\nLast used \(RelativeTime.short(usage.lastUsed))")
            }
        }
    }

    private func sources(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Sources")
            HStack(spacing: 6) {
                ForEach(summary.bySource) { s in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Palette.source(s.source))
                            .frame(width: 5, height: 5)
                        Text(s.source.displayName)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(s.totals.total > 0 ? UsageFormat.tokens(s.totals.total) : "\(s.totals.requests) req")
                            .font(.system(size: 9.5, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.white.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    private func conversations(_ snap: UsageSnapshot) -> some View {
        let running = snap.running
        let list = running.isEmpty ? Array(snap.conversations.prefix(3)) : Array(running.prefix(5))
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: running.isEmpty ? "Recent conversations" : "Running now",
                          trailing: running.isEmpty ? nil : "\(running.count)")
            if list.isEmpty {
                Text("No conversations found")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            ForEach(list) { c in
                Button { actions.openTranscript(c) } label: {
                    HStack(spacing: 7) {
                        if c.isRunning {
                            PulsingDot(color: snap.pendingApprovals.contains { $0.conversationID == c.id } ? Palette.warning : Palette.running)
                        } else {
                            Circle().fill(Color.white.opacity(0.3)).frame(width: 5, height: 5).frame(width: 14)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.95))
                                .lineLimit(1)
                            Text([c.source.displayName, c.workspaceName, "\(c.stepCount) steps", RelativeTime.short(c.lastModified, now: snap.generatedAt)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 8.5, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(5.5)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reveal transcript in Finder")
            }
        }
    }

    private func footer(_ snap: UsageSnapshot) -> some View {
        HStack(spacing: 4) {
            if let latest = snap.latestEvent, latest.hasTokens {
                Image(systemName: "text.alignleft").font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.5))
                Text("Last context \(UsageFormat.tokens(latest.contextTokens))")
                    .help("Prompt size of the most recent model call\n\(latest.model)\n\(snap.latestConversationTitle ?? latest.conversationID)")
            }
            Spacer()
            if snap.approvalsToday > 0 {
                Text("\(snap.approvalsToday) approvals today")
                Text("·")
            }
            Text(model.hasLoaded ? "Updated \(RelativeTime.short(snap.generatedAt))" : "Loading…")
        }
        .font(.system(size: 8.5, design: .rounded).monospacedDigit())
        .foregroundStyle(.white.opacity(0.45))
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Context Menu

struct WidgetMenuItems: View {
    @ObservedObject var model: WidgetModel
    var actions: WidgetActions

    var body: some View {
        Picker("Range", selection: $model.range) {
            ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Compact View", isOn: Binding(get: { !model.expanded }, set: { model.expanded = !$0 }))
        Menu("Compact View Model") {
            Button("Auto-follow Active (\(model.snapshot.currentModel ?? "None"))") {
                model.selectedCompactModel = nil
            }
            Divider()
            ForEach(model.availableModelOptions) { opt in
                Button {
                    model.selectedCompactModel = opt.name
                } label: {
                    let prefix = opt.isSelected && model.selectedCompactModel != nil ? "✓ " : "   "
                    let usageInfo = opt.tokens > 0 ? " (\(UsageFormat.tokens(opt.tokens)))" : ""
                    Text("\(prefix)\(opt.name) — \(opt.limitsDescription)\(usageInfo)")
                }
            }
        }
        Picker("Opacity", selection: $model.opacity) {
            Text("100%").tag(1.0)
            Text("85%").tag(0.85)
            Text("70%").tag(0.7)
            Text("50%").tag(0.5)
        }
        Picker("Refresh Interval", selection: $model.refreshInterval) {
            Text("2s").tag(2.0)
            Text("3s").tag(3.0)
            Text("5s").tag(5.0)
            Text("15s").tag(15.0)
            Text("1m").tag(60.0)
        }
        Toggle("Notify on Approvals", isOn: $model.notifyOnApprovals)
        Divider()
        Button("Refresh Now", action: actions.refresh)
        Button("Reset Widget Position", action: actions.resetPosition)
        Button("Open Data Folder", action: actions.openDataFolder)
        Divider()
        Button("Hide Widget", action: actions.hide)
        Button("Quit Antigravity Widget", action: actions.quit)
    }
}
