import AGUsageCore
import Combine
import Foundation
import SwiftUI

/// Serializes all disk access off the main thread.
actor MonitorActor {
    private let monitor = UsageMonitor()

    func snapshot() -> UsageSnapshot {
        monitor.snapshot()
    }

    var dataPath: URL { monitor.paths.base }
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

    let monitor = MonitorActor()
    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    private var knownApprovalIDs = Set<String>()

    private enum Keys {
        static let range = "widget.range"
        static let expanded = "widget.expanded"
        static let opacity = "widget.opacity"
        static let interval = "widget.refreshInterval"
        static let notify = "widget.notifyOnApprovals"
    }

    init() {
        range = UsageRange(rawValue: defaults.string(forKey: Keys.range) ?? "") ?? .today
        expanded = defaults.object(forKey: Keys.expanded) as? Bool ?? true
        opacity = defaults.object(forKey: Keys.opacity) as? Double ?? 1.0
        refreshInterval = defaults.object(forKey: Keys.interval) as? Double ?? 3
        notifyOnApprovals = defaults.object(forKey: Keys.notify) as? Bool ?? true
    }

    var summary: UsageSummary { snapshot.summary(range) }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.refreshInterval ?? 3
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 1) * 1_000_000_000))
            }
        }
    }

    func restart() {
        loop?.cancel()
        loop = nil
        start()
    }

    func refresh() async {
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
}
