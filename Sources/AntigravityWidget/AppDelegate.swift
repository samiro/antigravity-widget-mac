import AGUsageCore
import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = WidgetModel()
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private let sizeRelay = SizeRelay()

    private static let visibleKey = "widget.visible"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = WidgetActions(
            hide: { [weak self] in self?.setPanelVisible(false) },
            quit: { NSApp.terminate(nil) },
            refresh: { [weak self] in Task { await self?.model.refresh() } },
            openDataFolder: { [weak self] in self?.openDataFolder() },
            resetPosition: { [weak self] in self?.panel.resetPosition() },
            openTranscript: { [weak self] in self?.reveal($0) }
        )

        sizeRelay.onChange = { [weak self] size in self?.panel?.fit(to: size) }
        panel = FloatingPanel { [model, sizeRelay] in
            WidgetRootView(model: model, sizeRelay: sizeRelay, actions: actions)
        }
        if let fit = panel.contentView?.fittingSize, fit.width > 10, fit.height > 10 {
            panel.fit(to: fit)
        }

        setUpStatusItem()
        setUpNotifications()

        model.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.$range
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &cancellables)
        model.$selectedCompactModel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
        model.$newApprovals
            .receive(on: RunLoop.main)
            .sink { [weak self] approvals in self?.notify(approvals) }
            .store(in: &cancellables)
        model.$notifyOnApprovals
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setUpNotifications() }
            .store(in: &cancellables)

        model.start()
        setPanelVisible(UserDefaults.standard.object(forKey: Self.visibleKey) as? Bool ?? true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        setPanelVisible(true)
        return true
    }

    // MARK: - Panel

    private func setPanelVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        UserDefaults.standard.set(visible, forKey: Self.visibleKey)
        updateStatusItem()
    }

    @objc private func togglePanel() {
        setPanelVisible(!panel.isVisible)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let snap = model.snapshot
        let pending = snap.pendingApprovals.count
        let symbol = pending > 0 ? "hand.raised.fill" : (snap.running.isEmpty ? "sparkles" : "bolt.fill")
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Antigravity usage")
        image?.isTemplate = pending == 0
        button.image = pending > 0 ? image?.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) : image

        let limits = model.activeModelQuota
        var title = ""
        if let fiveH = limits.fiveHourPercent, let weekly = limits.weeklyPercent {
            title = " 5H: \(fiveH)% · Wk: \(weekly)%"
        } else if let fiveH = limits.fiveHourPercent {
            title = " 5H: \(fiveH)%"
        } else if let weekly = limits.weeklyPercent {
            title = " Wk: \(weekly)%"
        } else {
            title = " " + String(format: "%.0f%%", model.activeModelPercentRest)
        }

        if pending > 0 { title += " · \(pending)" }
        button.title = model.hasLoaded ? title : ""
        button.toolTip = [
            "Antigravity Quota & Usage — \(model.range.label)",
            "Active Model: \(model.activeCompactModelName) (\(limits.groupName))",
            limits.fiveHourPercent.map { "5-Hour Limit Remaining: \($0)%\(limits.fiveHourReset.map { " (resets in \(ModelQuotaLimits.formatCountdown($0)))" } ?? "")" },
            limits.weeklyPercent.map { "Weekly Limit Remaining: \($0)%\(limits.weeklyReset.map { " (resets in \(ModelQuotaLimits.formatCountdown($0)))" } ?? "")" },
            "Tokens (\(model.range.label)): \(UsageFormat.tokens(model.activeCompactModelUsage.total)) · \(model.activeCompactModelUsage.requests) requests",
            "Total all models: \(UsageFormat.tokens(model.summary.totals.total))",
            snap.running.isEmpty ? nil : "\(snap.running.count) running",
            pending > 0 ? "\(pending) waiting for approval" : nil,
        ].compactMap { $0 }.joined(separator: "\n")
    }

    /// Rebuilt every time it opens so it always reflects fresh numbers.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snap = model.snapshot
        let summary = model.summary

        func info(_ text: String) {
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        info("Model: \(model.activeCompactModelName)")
        let limits = model.activeModelQuota
        if let fiveH = limits.fiveHourPercent {
            info("5-Hour Limit Remaining: \(fiveH)%\(limits.fiveHourReset.map { " (resets in \(ModelQuotaLimits.formatCountdown($0)))" } ?? "")")
        }
        if let weekly = limits.weeklyPercent {
            info("Weekly Limit Remaining: \(weekly)%\(limits.weeklyReset.map { " (resets in \(ModelQuotaLimits.formatCountdown($0)))" } ?? "")")
        }
        info("\(model.range.label): \(UsageFormat.tokens(model.activeCompactModelUsage.total)) tokens · \(model.activeCompactModelUsage.requests) requests")
        info("Total all models: \(UsageFormat.tokens(summary.totals.total)) tokens · \(summary.totals.requests) requests")
        menu.addItem(.separator())

        info("Quota Pools Remaining:")
        for group in snap.quota.groups {
            var parts: [String] = []
            if let f = group.fiveHourBucket?.remainingPercent {
                parts.append("5H: \(f)%")
            } else if group.name.contains("Argon"), let gf = snap.quota.geminiGroup?.fiveHourBucket?.remainingPercent {
                parts.append("5H: \(gf)% (shared)")
            }
            if let w = group.weeklyBucket?.remainingPercent {
                parts.append("Weekly: \(w)%")
            }
            info("   \(group.name) — \(parts.joined(separator: " · "))")
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: panel.isVisible ? "Hide Widget" : "Show Widget",
                                action: #selector(togglePanel), keyEquivalent: "w")
        toggle.target = self
        menu.addItem(toggle)

        let rangeItem = NSMenuItem(title: "Range", action: nil, keyEquivalent: "")
        let rangeMenu = NSMenu()
        for range in UsageRange.allCases {
            let item = NSMenuItem(title: range.label, action: #selector(selectRange(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = range.rawValue
            item.state = range == model.range ? .on : .off
            rangeMenu.addItem(item)
        }
        rangeItem.submenu = rangeMenu
        menu.addItem(rangeItem)

        let modelsItem = NSMenuItem(title: "Compact View Model", action: nil, keyEquivalent: "")
        let modelsMenu = NSMenu()
        let autoItem = NSMenuItem(title: "Auto-follow Active (\(snap.currentModel ?? "None"))",
                                  action: #selector(selectCompactModelAction(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = ""
        autoItem.state = model.selectedCompactModel == nil ? .on : .off
        modelsMenu.addItem(autoItem)
        modelsMenu.addItem(.separator())

        for opt in model.availableModelOptions {
            let usageInfo = opt.tokens > 0 ? " (\(UsageFormat.tokens(opt.tokens)))" : ""
            let item = NSMenuItem(title: "\(opt.name) — \(opt.limitsDescription)\(usageInfo)",
                                  action: #selector(selectCompactModelAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = opt.name
            item.state = opt.isSelected && model.selectedCompactModel != nil ? .on : .off
            modelsMenu.addItem(item)
        }
        modelsItem.submenu = modelsMenu
        menu.addItem(modelsItem)

        let compact = NSMenuItem(title: "Compact Widget", action: #selector(toggleCompact), keyEquivalent: "")
        compact.target = self
        compact.state = model.expanded ? .off : .on
        menu.addItem(compact)

        let notify = NSMenuItem(title: "Notify on Approval Requests", action: #selector(toggleNotify), keyEquivalent: "")
        notify.target = self
        notify.state = model.notifyOnApprovals ? .on : .off
        menu.addItem(notify)

        if Bundle.main.bundleIdentifier != nil {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let reset = NSMenuItem(title: "Reset Widget Position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        let folder = NSMenuItem(title: "Open Antigravity Data Folder", action: #selector(openDataFolderAction), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Antigravity Widget", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectRange(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let range = UsageRange(rawValue: raw) {
            model.range = range
        }
    }

    @objc private func selectCompactModelAction(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, !raw.isEmpty {
            model.selectedCompactModel = raw
        } else {
            model.selectedCompactModel = nil
        }
    }

    @objc private func toggleCompact() { model.expanded.toggle() }
    @objc private func toggleNotify() { model.notifyOnApprovals.toggle() }
    @objc private func refreshNow() { Task { await model.refresh(forceQuota: true) } }
    @objc private func resetPosition() { panel.resetPosition(); setPanelVisible(true) }
    @objc private func openDataFolderAction() { openDataFolder() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Launch at Login"
            alert.runModal()
        }
    }

    private func openDataFolder() {
        Task {
            let url = await model.monitor.dataPath
            NSWorkspace.shared.open(url)
        }
    }

    private func reveal(_ conversation: ConversationInfo) {
        Task {
            let paths = AgyPaths(base: await model.monitor.dataPath)
            let transcript = paths.transcript(conversation.source, conversationID: conversation.id)
            if FileManager.default.fileExists(atPath: transcript.path) {
                NSWorkspace.shared.activateFileViewerSelecting([transcript])
            } else {
                NSWorkspace.shared.open(paths.brain(conversation.source))
            }
        }
    }

    // MARK: - Notifications

    private var notificationsAvailable: Bool {
        // UNUserNotificationCenter crashes when the binary isn't inside an .app bundle.
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private func setUpNotifications() {
        guard notificationsAvailable, model.notifyOnApprovals else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ approvals: [PendingApproval]) {
        guard !approvals.isEmpty, model.notifyOnApprovals else { return }
        if notificationsAvailable {
            for approval in approvals {
                let content = UNMutableNotificationContent()
                content.title = "Antigravity needs your approval"
                let conversation = model.conversationTitle(approval.conversationID)
                content.body = [approval.tool, conversation].compactMap { $0 }.joined(separator: " — ")
                content.sound = .default
                let request = UNNotificationRequest(identifier: approval.id, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
            }
        } else {
            NSSound.beep()
        }
    }
}
