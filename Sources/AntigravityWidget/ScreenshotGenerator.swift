import AGUsageCore
import AppKit
import SwiftUI

@MainActor
enum ScreenshotGenerator {
    static func generate(to directory: URL) {
        print("[ScreenshotGenerator] Output directory: \(directory.path)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = WidgetModel()
        model.widgetSize = .normal

        let snapshot = makeSnapshot()
        model.applySnapshotForScreenshot(snapshot)

        // 1. Render Compact View (Normal Size)
        print("[ScreenshotGenerator] Rendering compact view...")
        let compactView = CompactView(model: model)
            .background(.regularMaterial, in: Capsule())
            .clipShape(Capsule())
            .padding(10)
            .environment(\.colorScheme, .dark)

        if let compactData = render(compactView) {
            let compactURL = directory.appendingPathComponent("compact-view.png")
            try? compactData.write(to: compactURL)
            print("[ScreenshotGenerator] Successfully wrote \(compactURL.path) (\(compactData.count) bytes)")
        } else {
            print("[ScreenshotGenerator] Failed to render compact view")
        }

        // 2. Render Expanded View (Normal Size)
        print("[ScreenshotGenerator] Rendering expanded view...")
        let expandedView = ExpandedView(model: model, actions: WidgetActions())
            .frame(width: model.widgetSize.expandedWidth)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(10)
            .environment(\.colorScheme, .dark)

        if let expandedData = render(expandedView) {
            let expandedURL = directory.appendingPathComponent("expanded-view.png")
            try? expandedData.write(to: expandedURL)
            print("[ScreenshotGenerator] Successfully wrote \(expandedURL.path) (\(expandedData.count) bytes)")
        } else {
            print("[ScreenshotGenerator] Failed to render expanded view")
        }
    }

    private static func render<V: View>(_ view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0 // Retina 2x
        guard let nsImage = renderer.nsImage else { return nil }
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    private static func makeSnapshot() -> UsageSnapshot {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(4 * 3600 + 53 * 60) // 4h 53m
        let weeklyReset = now.addingTimeInterval(4 * 86400 + 9 * 3600)  // 4d 9h

        let geminiGroup = QuotaGroup(
            name: "Gemini Models",
            description: "Gemini 3.8 Flash, Gemini Pro",
            buckets: [
                QuotaBucket(
                    id: "gemini-5h",
                    name: "Five Hour Limit Remaining",
                    window: "5h",
                    remainingFraction: 0.98,
                    resetTime: fiveHourReset
                ),
                QuotaBucket(
                    id: "gemini-weekly",
                    name: "Weekly Limit Remaining",
                    window: "weekly",
                    remainingFraction: 0.69,
                    resetTime: weeklyReset
                )
            ]
        )

        let claudeGroup = QuotaGroup(
            name: "Claude and GPT models",
            description: "Claude 3.7 Sonnet, GPT-4o",
            buckets: [
                QuotaBucket(
                    id: "claude-5h",
                    name: "Five Hour Limit Remaining",
                    window: "5h",
                    remainingFraction: 0.45,
                    resetTime: now.addingTimeInterval(2 * 3600 + 15 * 60)
                ),
                QuotaBucket(
                    id: "claude-weekly",
                    name: "Weekly Limit Remaining",
                    window: "weekly",
                    remainingFraction: 0.82,
                    resetTime: now.addingTimeInterval(5 * 86400)
                )
            ]
        )

        let quota = QuotaSnapshot(
            description: "Active Quotas",
            groups: [geminiGroup, claudeGroup],
            fetchedAt: now
        )

        // Generate realistic events matching 38.3M tokens and 260 req
        var events: [UsageEvent] = []
        let cal = Calendar.current
        for dayOffset in 0..<14 {
            let dayDate = cal.date(byAdding: .day, value: -dayOffset, to: now) ?? now
            let count = dayOffset == 0 ? 35 : (dayOffset < 7 ? 20 : 15)
            for i in 0..<count {
                let eDate = dayDate.addingTimeInterval(Double(-i * 120))
                events.append(UsageEvent(
                    date: eDate,
                    model: "gemini-3.8-flash",
                    source: .cli,
                    conversationID: "conv-\(dayOffset)",
                    input: 135_000,
                    cacheRead: 10_000,
                    output: 2_500,
                    hasTokens: true
                ))
            }
        }

        var summaries: [UsageRange: UsageSummary] = [:]
        for range in UsageRange.allCases {
            summaries[range] = UsageSummary.make(events: events, range: range, now: now)
        }

        let convs = [
            ConversationInfo(
                id: "c-active",
                source: .cli,
                title: "Antigravity Widget Enhancement",
                status: "RUNNING",
                stepCount: 42,
                lastModified: now,
                isBusy: true,
                workspace: "antigravity-widget-mac"
            ),
            ConversationInfo(
                id: "c-prev",
                source: .cli,
                title: "Quota telemetry integration",
                status: "COMPLETED",
                stepCount: 18,
                lastModified: now.addingTimeInterval(-3600),
                isBusy: false,
                workspace: "antigravity-widget-mac"
            )
        ]

        return UsageSnapshot(
            generatedAt: now,
            currentModel: "gemini-3.8-flash",
            summaries: summaries,
            conversations: convs,
            pendingApprovals: [],
            approvalsToday: 12,
            latestEvent: events.first,
            latestConversationTitle: "Antigravity Widget Enhancement",
            totalEvents: events.count,
            quota: quota
        )
    }
}
