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
                    .frame(width: 330)
            } else {
                CompactView(model: model)
            }
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(borderColor, lineWidth: model.snapshot.pendingApprovals.isEmpty ? 0.5 : 1.2)
        )
        .opacity(model.opacity)
        .fixedSize()
        .background(GeometryReader { Color.clear.preference(key: SizeKey.self, value: $0.size) })
        .onPreferenceChange(SizeKey.self) { size in
            MainActor.assumeIsolated { sizeRelay.onChange?(size) }
        }
        .contextMenu { WidgetMenuItems(model: model, actions: actions) }
        .environment(\.colorScheme, .dark)
    }

    private var borderColor: Color {
        model.snapshot.pendingApprovals.isEmpty ? Color.white.opacity(0.14) : Palette.warning.opacity(0.85)
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

// MARK: - Compact

struct CompactView: View {
    @ObservedObject var model: WidgetModel

    var body: some View {
        let snap = model.snapshot
        let summary = model.summary
        HStack(spacing: 8) {
            PulsingDot(color: statusColor, active: !snap.running.isEmpty || !snap.pendingApprovals.isEmpty)
            VStack(alignment: .leading, spacing: 0) {
                Text(snap.currentModel.map(UsageFormat.shortModel) ?? "Antigravity")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(UsageFormat.tokens(summary.totals.total)) · \(summary.totals.requests) req · \(model.range.label.lowercased())")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
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
            Button {
                withAnimation(.snappy(duration: 0.2)) { model.expanded = true }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Expand")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { withAnimation(.snappy(duration: 0.2)) { model.expanded = true } }
    }

    private var statusColor: Color {
        if !model.snapshot.pendingApprovals.isEmpty { return Palette.warning }
        if !model.snapshot.running.isEmpty { return Palette.running }
        return .gray
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: WidgetModel
    var actions: WidgetActions

    var body: some View {
        let snap = model.snapshot
        let summary = model.summary

        VStack(alignment: .leading, spacing: 12) {
            header(snap)

            Picker("", selection: $model.range) {
                Text("Today").tag(UsageRange.today)
                Text("7d").tag(UsageRange.week)
                Text("30d").tag(UsageRange.month)
                Text("All").tag(UsageRange.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if !snap.pendingApprovals.isEmpty {
                approvals(snap.pendingApprovals)
            }

            totals(summary)

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
        .padding(12)
    }

    // MARK: Sections

    private func header(_ snap: UsageSnapshot) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.accent, Palette.cache], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text("Antigravity")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if let current = snap.currentModel {
                        Circle().fill(Palette.model(current)).frame(width: 7, height: 7)
                    }
                    Text(snap.currentModel ?? (model.hasLoaded ? "No model selected" : "Loading…"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
                .help("Currently selected model")
            }
            Spacer()
            HStack(spacing: 2) {
                iconButton("arrow.clockwise", help: "Refresh now", action: actions.refresh)
                iconButton("chevron.up", help: "Collapse") {
                    withAnimation(.snappy(duration: 0.2)) { model.expanded = false }
                }
                iconButton("xmark", help: "Hide widget (reopen from the menu bar)", action: actions.hide)
            }
        }
    }

    private func approvals(_ pending: [PendingApproval]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PulsingDot(color: Palette.warning)
                Text(pending.count == 1 ? "Waiting for your approval" : "\(pending.count) approvals waiting")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.warning)
            }
            ForEach(pending) { approval in
                HStack(spacing: 6) {
                    Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(approval.tool).font(.system(size: 11, weight: .medium))
                    Text(model.conversationTitle(approval.conversationID) ?? "step \(approval.step)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(RelativeTime.short(approval.surfacedAt, now: model.snapshot.generatedAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(9)
        .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func totals(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormat.tokens(summary.totals.total))
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("tokens")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(summary.totals.requests) requests")
                    Text("\(summary.conversationCount) conversations")
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            TokenSplitBar(totals: summary.totals)
            HStack(spacing: 6) {
                StatBlock(label: "Input", value: UsageFormat.tokens(summary.totals.input), color: Palette.input)
                StatBlock(label: "Cached", value: UsageFormat.tokens(summary.totals.cacheRead), color: Palette.cache)
                StatBlock(label: "Output", value: UsageFormat.tokens(summary.totals.output), color: Palette.output)
                StatBlock(label: "Cache hit", value: UsageFormat.percent(summary.totals.cacheHitRate), color: .gray)
            }
        }
    }

    private func models(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: "Models", trailing: summary.byModel.isEmpty ? nil : "\(summary.byModel.count)")
            if summary.byModel.isEmpty {
                Text("No model calls in this period")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
                        Circle().fill(Palette.source(s.source)).frame(width: 6, height: 6)
                        Text(s.source.displayName).font(.system(size: 10.5, weight: .medium))
                        Text(s.totals.total > 0 ? UsageFormat.tokens(s.totals.total) : "\(s.totals.requests) req")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
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
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(list) { c in
                Button { actions.openTranscript(c) } label: {
                    HStack(spacing: 7) {
                        if c.isRunning {
                            PulsingDot(color: snap.pendingApprovals.contains { $0.conversationID == c.id } ? Palette.warning : Palette.running)
                        } else {
                            Circle().fill(Color.gray.opacity(0.6)).frame(width: 6, height: 6).frame(width: 12)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(c.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Text([c.source.displayName, c.workspaceName, "\(c.stepCount) steps", RelativeTime.short(c.lastModified, now: snap.generatedAt)]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
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
                Image(systemName: "text.alignleft").font(.system(size: 9))
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
        .font(.system(size: 9.5).monospacedDigit())
        .foregroundStyle(.tertiary)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Shared menu

struct WidgetMenuItems: View {
    @ObservedObject var model: WidgetModel
    var actions: WidgetActions

    var body: some View {
        Picker("Range", selection: $model.range) {
            ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
        }
        Toggle("Compact", isOn: Binding(get: { !model.expanded }, set: { model.expanded = !$0 }))
        Picker("Opacity", selection: $model.opacity) {
            Text("100%").tag(1.0)
            Text("85%").tag(0.85)
            Text("70%").tag(0.7)
            Text("50%").tag(0.5)
        }
        Picker("Refresh every", selection: $model.refreshInterval) {
            Text("2 seconds").tag(2.0)
            Text("3 seconds").tag(3.0)
            Text("5 seconds").tag(5.0)
            Text("15 seconds").tag(15.0)
            Text("1 minute").tag(60.0)
        }
        Toggle("Notify on approval requests", isOn: $model.notifyOnApprovals)
        Divider()
        Button("Refresh Now", action: actions.refresh)
        Button("Reset Position", action: actions.resetPosition)
        Button("Open Antigravity Data Folder", action: actions.openDataFolder)
        Divider()
        Button("Hide Widget", action: actions.hide)
        Button("Quit Antigravity Widget", action: actions.quit)
    }
}
