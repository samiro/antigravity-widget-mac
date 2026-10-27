import AGUsageCore
import Foundation

// Prints the same statistics the widget shows. Usage:
//   agy-usage [today|week|month|all] [--json]

let args = CommandLine.arguments.dropFirst()
let range = args.compactMap { UsageRange(rawValue: $0) }.first ?? .today
let asJSON = args.contains("--json")

let monitor = UsageMonitor()
let snap = monitor.snapshot()
let summary = snap.summary(range)

if asJSON {
    func totals(_ t: TokenTotals) -> [String: Any] {
        ["requests": t.requests, "input": t.input, "cacheRead": t.cacheRead, "output": t.output, "total": t.total]
    }
    let payload: [String: Any] = [
        "range": range.rawValue,
        "currentModel": (snap.currentModel as Any?) ?? NSNull(),
        "totals": totals(summary.totals),
        "conversations": summary.conversationCount,
        "byModel": summary.byModel.map { ["model": $0.model, "totals": totals($0.totals)] },
        "bySource": summary.bySource.map { ["source": $0.source.rawValue, "totals": totals($0.totals)] },
        "daily": summary.daily.map { ["day": ISO8601DateFormatter().string(from: $0.day), "total": $0.totals.total] },
        "running": snap.running.map { ["id": $0.id, "title": $0.title, "source": $0.source.rawValue] },
        "pendingApprovals": snap.pendingApprovals.map { ["tool": $0.tool, "step": $0.step, "conversation": ($0.conversationID as Any?) ?? NSNull()] as [String: Any] },
        "approvalsToday": snap.approvalsToday,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}

print("Antigravity usage — \(range.label)  (data: \(monitor.paths.base.path))")
print("Current model : \(snap.currentModel ?? "unknown")")
let t = summary.totals
print("Requests      : \(t.requests) across \(summary.conversationCount) conversations")
print("Tokens        : \(UsageFormat.tokens(t.total)) total  (in \(UsageFormat.tokens(t.input)), cached \(UsageFormat.tokens(t.cacheRead)), out \(UsageFormat.tokens(t.output)); cache hit \(UsageFormat.percent(t.cacheHitRate)))")
if let latest = snap.latestEvent {
    print("Last context  : \(UsageFormat.tokens(latest.contextTokens)) tokens · \(latest.model) · \(snap.latestConversationTitle ?? latest.conversationID)")
}
print("\nBy model:")
for m in summary.byModel {
    print("  \(pad(m.model, 32)) \(pad(UsageFormat.tokens(m.totals.total), 8)) \(m.totals.requests) req")
}
print("\nBy source:")
for s in summary.bySource {
    print("  \(pad(s.source.displayName, 32)) \(pad(UsageFormat.tokens(s.totals.total), 8)) \(s.totals.requests) req")
}
print("\nLast 14 days:")
let df = DateFormatter()
df.dateFormat = "EEE MMM d"
let maxDay = max(summary.daily.map(\.totals.total).max() ?? 1, 1)
for d in summary.daily {
    let bar = String(repeating: "█", count: Int((Double(d.totals.total) / Double(maxDay)) * 30))
    print("  \(pad(df.string(from: d.day), 11)) \(pad(UsageFormat.tokens(d.totals.total), 8)) \(bar)")
}
print("\nRunning conversations: \(snap.running.count)")
for c in snap.running {
    print("  [\(c.source.displayName)] \(c.title)")
}
print("Pending approvals: \(snap.pendingApprovals.count)  (surfaced today: \(snap.approvalsToday))")
for p in snap.pendingApprovals {
    print("  \(p.tool) at step \(p.step) — \(p.conversationID ?? "unknown conversation")")
}
