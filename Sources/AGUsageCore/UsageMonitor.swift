import Foundation

/// Everything the widget displays, captured at one point in time.
public struct UsageSnapshot: Sendable {
    public var generatedAt: Date
    /// Model currently selected in Antigravity (best effort).
    public var currentModel: String?
    public var summaries: [UsageRange: UsageSummary]
    public var conversations: [ConversationInfo]
    public var pendingApprovals: [PendingApproval]
    public var approvalsToday: Int
    /// Most recent model call across all sources.
    public var latestEvent: UsageEvent?
    /// Title of the conversation the latest event belongs to.
    public var latestConversationTitle: String?
    public var totalEvents: Int
    /// Active quota limits from Antigravity (5-hour and weekly limits).
    public var quota: QuotaSnapshot

    public var running: [ConversationInfo] { conversations.filter(\.isRunning) }

    public func summary(_ range: UsageRange) -> UsageSummary {
        summaries[range] ?? UsageSummary.make(events: [], range: range)
    }

    public static let empty = UsageSnapshot(
        generatedAt: .distantPast, currentModel: nil, summaries: [:], conversations: [],
        pendingApprovals: [], approvalsToday: 0, latestEvent: nil, latestConversationTitle: nil,
        totalEvents: 0, quota: .fallback)
}

/// Owns the incremental readers and produces snapshots. Call `snapshot()` from a
/// single serial context (the widget uses a dedicated actor).
public final class UsageMonitor {
    public let paths: AgyPaths
    public let quotaMonitor: QuotaMonitor
    private var cachedQuota: QuotaSnapshot
    private let index: UsageIndex
    private let logs: CLILogMonitor

    public init(paths: AgyPaths = AgyPaths()) {
        self.paths = paths
        self.quotaMonitor = QuotaMonitor(paths: paths)
        self.cachedQuota = .fallback
        self.index = UsageIndex(paths: paths)
        self.logs = CLILogMonitor(paths: paths)
    }

    public func refreshQuota(force: Bool = false) async -> QuotaSnapshot {
        let fresh = await quotaMonitor.refresh(force: force)
        cachedQuota = fresh
        return fresh
    }

    public func snapshot(now: Date = Date()) -> UsageSnapshot {
        let events = index.refresh()
        let logState = logs.refresh(now: now)
        let conversations = ConversationStore.recent(paths: paths, limit: 40)

        var summaries: [UsageRange: UsageSummary] = [:]
        for range in UsageRange.allCases {
            summaries[range] = UsageSummary.make(events: events, range: range, now: now)
        }

        let latest = events.max { $0.date < $1.date }
        let latestTitle = latest.flatMap { e in conversations.first { $0.id == e.conversationID }?.title }

        // An approval whose conversation has since gone idle was abandoned (e.g. the
        // CLI was closed while the prompt was showing).
        let pending = logState.pending.filter { approval in
            guard let id = approval.conversationID,
                  let conversation = conversations.first(where: { $0.id == id }) else { return true }
            return conversation.isRunning || conversation.lastModified <= approval.surfacedAt
        }

        // Prefer the CLI's persisted selection; fall back to the latest log/transcript signal.
        let current = CLISettings.selectedModel(paths: paths)
            ?? logState.lastModelLabel
            ?? latest.map(\.model).flatMap { $0 == unknownModel ? nil : $0 }

        return UsageSnapshot(
            generatedAt: now,
            currentModel: current,
            summaries: summaries,
            conversations: conversations,
            pendingApprovals: pending,
            approvalsToday: logState.approvalsToday,
            latestEvent: latest,
            latestConversationTitle: latestTitle,
            totalEvents: events.count,
            quota: cachedQuota
        )
    }
}

// MARK: - Formatting

public enum UsageFormat {
    /// 950 → "950", 12_300 → "12.3K", 4_560_000 → "4.56M".
    public static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch abs(v) {
        case 1_000_000_000...: return trim(v / 1_000_000_000) + "B"
        case 1_000_000...: return trim(v / 1_000_000) + "M"
        case 1_000...: return trim(v / 1_000) + "K"
        default: return "\(n)"
        }
    }

    private static func trim(_ v: Double) -> String {
        let s: String
        if v >= 100 { s = String(format: "%.0f", v) }
        else if v >= 10 { s = String(format: "%.1f", v) }
        else { s = String(format: "%.2f", v) }
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    public static func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }

    /// Short model label: "Claude Opus 5.5 (Medium)" → "Opus 5.5 · Med".
    public static func shortModel(_ model: String) -> String {
        var name = model
        var effort: String?
        if let open = name.lastIndex(of: "("), name.hasSuffix(")") {
            effort = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        // "Claude" is implied by Opus/Sonnet/Haiku; keep "Gemini" since its tiers are generic words.
        if name.hasPrefix("Claude ") { name.removeFirst("Claude ".count) }
        guard let effort else { return name }
        let short: String
        switch effort.lowercased() {
        case "medium": short = "Med"
        case "high": short = "High"
        case "low": short = "Low"
        default: short = effort
        }
        return "\(name) · \(short)"
    }
}
