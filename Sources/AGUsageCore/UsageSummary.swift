import Foundation

/// Time window used to aggregate usage.
public enum UsageRange: String, CaseIterable, Sendable, Identifiable {
    case today, week, month, all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        case .month: return "30 days"
        case .all: return "All time"
        }
    }

    /// Start of the window relative to `now` (nil = unbounded).
    public func start(now: Date, calendar: Calendar = .current) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .today: return startOfToday
        case .week: return calendar.date(byAdding: .day, value: -6, to: startOfToday)
        case .month: return calendar.date(byAdding: .day, value: -29, to: startOfToday)
        case .all: return nil
        }
    }
}

/// Token counters for a group of usage events.
public struct TokenTotals: Sendable, Hashable {
    public var requests = 0
    public var input = 0
    public var cacheRead = 0
    public var output = 0

    public init(requests: Int = 0, input: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.requests = requests
        self.input = input
        self.cacheRead = cacheRead
        self.output = output
    }

    public var total: Int { input + cacheRead + output }

    /// Fraction of prompt tokens that were served from cache.
    public var cacheHitRate: Double {
        let prompt = input + cacheRead
        return prompt == 0 ? 0 : Double(cacheRead) / Double(prompt)
    }

    public mutating func add(_ e: UsageEvent) {
        requests += 1
        input += e.input
        cacheRead += e.cacheRead
        output += e.output
    }
}

public struct ModelUsage: Sendable, Hashable, Identifiable {
    public var model: String
    public var totals: TokenTotals
    public var lastUsed: Date
    public var id: String { model }
}

public struct SourceUsage: Sendable, Hashable, Identifiable {
    public var source: AgySource
    public var totals: TokenTotals
    public var id: String { source.rawValue }
}

public struct DailyUsage: Sendable, Hashable, Identifiable {
    public var day: Date
    public var totals: TokenTotals
    public var id: Date { day }
}

/// Aggregated view over a set of events for one range.
public struct UsageSummary: Sendable {
    public var range: UsageRange
    public var totals: TokenTotals
    public var byModel: [ModelUsage]
    public var bySource: [SourceUsage]
    /// One bucket per calendar day for the last `dailyDays` days (oldest first).
    public var daily: [DailyUsage]
    public var conversationCount: Int

    public static func make(events: [UsageEvent], range: UsageRange, now: Date = Date(),
                            dailyDays: Int = 14, calendar: Calendar = .current) -> UsageSummary {
        let start = range.start(now: now, calendar: calendar)
        let inRange = start.map { s in events.filter { $0.date >= s } } ?? events

        var totals = TokenTotals()
        var models: [String: ModelUsage] = [:]
        var sources: [AgySource: TokenTotals] = [:]
        var conversations = Set<String>()

        for e in inRange {
            totals.add(e)
            var m = models[e.model] ?? ModelUsage(model: e.model, totals: TokenTotals(), lastUsed: e.date)
            m.totals.add(e)
            m.lastUsed = max(m.lastUsed, e.date)
            models[e.model] = m
            sources[e.source, default: TokenTotals()].add(e)
            conversations.insert(e.conversationID)
        }

        // Daily buckets are independent of the selected range so the sparkline is stable.
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: TokenTotals] = [:]
        let firstDay = calendar.date(byAdding: .day, value: -(dailyDays - 1), to: today) ?? today
        for e in events where e.date >= firstDay {
            buckets[calendar.startOfDay(for: e.date), default: TokenTotals()].add(e)
        }
        let daily: [DailyUsage] = (0..<dailyDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyUsage(day: day, totals: buckets[day] ?? TokenTotals())
        }

        return UsageSummary(
            range: range,
            totals: totals,
            byModel: models.values.sorted {
                $0.totals.total != $1.totals.total ? $0.totals.total > $1.totals.total
                    : $0.totals.requests > $1.totals.requests
            },
            bySource: sources.map { SourceUsage(source: $0.key, totals: $0.value) }
                .sorted { $0.totals.total > $1.totals.total },
            daily: daily,
            conversationCount: conversations.count
        )
    }
}
