import AGUsageCore
import Combine
import Foundation
import SwiftUI

/// Serializes all disk and process access off the main thread.
actor MonitorActor {
    private let monitor = UsageMonitor()

    func snapshot() -> UsageSnapshot {
        monitor.snapshot()
    }

    func refreshQuota(force: Bool = false) async -> QuotaSnapshot {
        await monitor.refreshQuota(force: force)
    }

    var dataPath: URL { monitor.paths.base }
}

/// An available model option with usage and quota limit remaining stats.
public struct CompactModelOption: Identifiable, Hashable {
    public let name: String
    public let groupName: String
    public let tokens: Int
    public let requests: Int
    public let fiveHourPercent: Int?
    public let weeklyPercent: Int?
    public let isSelected: Bool

    public var id: String { name }

    public var limitsDescription: String {
        var parts: [String] = []
        if let f = fiveHourPercent { parts.append("5H: \(f)%") }
        if let w = weeklyPercent { parts.append("Wk: \(w)%") }
        return parts.joined(separator: " · ")
    }
}

/// Observable state shared by the floating widget and the menu bar item.
@MainActor
final class WidgetModel: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var hasLoaded = false
    /// Approvals that appeared since the previous refresh (used to flash / notify).
    @Published private(set) var newApprovals: [PendingApproval] = []

    @Published var range: UsageRange {
        didSet { defaults.set(range.rawValue, forKey: Keys.range) }
    }
    @Published var expanded: Bool {
        didSet { defaults.set(expanded, forKey: Keys.expanded) }
    }
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: Keys.opacity) }
    }
    @Published var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.interval); restart() }
    }
    @Published var notifyOnApprovals: Bool {
        didSet { defaults.set(notifyOnApprovals, forKey: Keys.notify) }
    }
    @Published var selectedCompactModel: String? {
        didSet {
            if let selectedCompactModel {
                defaults.set(selectedCompactModel, forKey: Keys.compactModel)
            } else {
                defaults.removeObject(forKey: Keys.compactModel)
            }
        }
    }

    let monitor = MonitorActor()
    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    private var quotaLoop: Task<Void, Never>?
    private var knownApprovalIDs = Set<String>()

    private enum Keys {
        static let range = "widget.range"
        static let expanded = "widget.expanded"
        static let opacity = "widget.opacity"
        static let interval = "widget.refreshInterval"
        static let notify = "widget.notifyOnApprovals"
        static let compactModel = "widget.compactModel"
    }

    init() {
        range = UsageRange(rawValue: defaults.string(forKey: Keys.range) ?? "") ?? .today
        expanded = defaults.object(forKey: Keys.expanded) as? Bool ?? false
        opacity = defaults.object(forKey: Keys.opacity) as? Double ?? 1.0
        refreshInterval = defaults.object(forKey: Keys.interval) as? Double ?? 3
        notifyOnApprovals = defaults.object(forKey: Keys.notify) as? Bool ?? true
        selectedCompactModel = defaults.string(forKey: Keys.compactModel)
    }

    var summary: UsageSummary { snapshot.summary(range) }

    func start() {
        guard loop == nil else { return }
        // Run initial refresh with quota
        Task { [weak self] in
            await self?.refresh(forceQuota: true)
        }

        // Local transcript and log monitoring loop (fast)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(forceQuota: false)
                let seconds = self?.refreshInterval ?? 3
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 1) * 1_000_000_000))
            }
        }

        // Background quota refresh loop (every 30 seconds)
        quotaLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                _ = await self?.monitor.refreshQuota(force: false)
            }
        }
    }

    func restart() {
        loop?.cancel()
        loop = nil
        quotaLoop?.cancel()
        quotaLoop = nil
        start()
    }

    func refresh(forceQuota: Bool = false) async {
        if forceQuota {
            _ = await monitor.refreshQuota(force: true)
        }
        let snap = await monitor.snapshot()
        let ids = Set(snap.pendingApprovals.map(\.id))
        // Don't notify about approvals that were already pending at launch.
        newApprovals = hasLoaded ? snap.pendingApprovals.filter { !knownApprovalIDs.contains($0.id) } : []
        knownApprovalIDs = ids
        snapshot = snap
        hasLoaded = true
    }

    func conversationTitle(_ id: String?) -> String? {
        guard let id else { return nil }
        return snapshot.conversations.first { $0.id == id }?.title
    }

    public static let knownModels: [String] = [
        "Gemini 4 Argon (Medium)",
        "Gemini 4 Argon (High)",
        "Gemini 4 Argon (Low)",
        "Gemini 3.8 Flash (High)",
        "Gemini 3.8 Flash (Medium)",
        "Gemini 3.8 Flash (Low)",
        "Gemini 3.8 Pro (High)",
        "Gemini 3.8 Pro (Medium)",
        "Claude Opus 5.5 (Medium)",
        "Claude Opus 5.5 (High)",
        "Claude Sonnet 5.5 (Medium)",
        "Claude Sonnet 5.5 (High)",
        "GPT-OSS 120B (Medium)",
    ]

    /// The model to display in the compact view: an explicitly chosen model,
    /// or the currently active model from CLI / logs, or the highest-usage model.
    var activeCompactModelName: String {
        if let explicit = selectedCompactModel, !explicit.isEmpty {
            return explicit
        }
        if let current = snapshot.currentModel, !current.isEmpty {
            return current
        }
        if let first = summary.byModel.first?.model {
            return first
        }
        return "Gemini 4 Argon (Medium)"
    }

    /// Usage totals for the active compact model in the current range.
    var activeCompactModelUsage: TokenTotals {
        let name = activeCompactModelName
        if let match = summary.byModel.first(where: { $0.model == name }) {
            return match.totals
        }
        return TokenTotals()
    }

    /// Quota limits for active compact model (5H and Weekly remaining limits).
    var activeModelQuota: ModelQuotaLimits {
        snapshot.quota.limits(for: activeCompactModelName)
    }

    var activeModelFiveHourPercent: Int? {
        activeModelQuota.fiveHourPercent
    }

    var activeModelWeeklyPercent: Int? {
        activeModelQuota.weeklyPercent
    }

    var activeModelResetCountdown: String? {
        activeModelQuota.resetCountdownString
    }

    /// Percentage of total tokens consumed by the active compact model (0.0 ... 100.0).
    var activeModelPercentUsed: Double {
        let total = summary.totals.total
        guard total > 0 else { return 0 }
        let modelTotal = activeCompactModelUsage.total
        return min(max((Double(modelTotal) / Double(total)) * 100.0, 0), 100)
    }

    /// Remaining percentage of usage available (100% - used%).
    var activeModelPercentRest: Double {
        max(0, 100.0 - activeModelPercentUsed)
    }

    /// Available model options with usage and quota remaining percentages.
    var availableModelOptions: [CompactModelOption] {
        let active = activeCompactModelName
        var result: [CompactModelOption] = []
        var seen = Set<String>()

        // 1. Models that have usage in the current range (sorted by token volume)
        for m in summary.byModel {
            seen.insert(m.model)
            let limits = snapshot.quota.limits(for: m.model)
            result.append(CompactModelOption(
                name: m.model,
                groupName: limits.groupName,
                tokens: m.totals.total,
                requests: m.totals.requests,
                fiveHourPercent: limits.fiveHourPercent,
                weeklyPercent: limits.weeklyPercent,
                isSelected: m.model == active
            ))
        }

        // 2. Currently selected CLI model if not seen yet
        if let current = snapshot.currentModel, !seen.contains(current) {
            seen.insert(current)
            let limits = snapshot.quota.limits(for: current)
            result.append(CompactModelOption(
                name: current,
                groupName: limits.groupName,
                tokens: 0,
                requests: 0,
                fiveHourPercent: limits.fiveHourPercent,
                weeklyPercent: limits.weeklyPercent,
                isSelected: current == active
            ))
        }

        // 3. Other known models from Antigravity
        for known in Self.knownModels where !seen.contains(known) {
            seen.insert(known)
            let limits = snapshot.quota.limits(for: known)
            result.append(CompactModelOption(
                name: known,
                groupName: limits.groupName,
                tokens: 0,
                requests: 0,
                fiveHourPercent: limits.fiveHourPercent,
                weeklyPercent: limits.weeklyPercent,
                isSelected: known == active
            ))
        }

        return result
    }
}
