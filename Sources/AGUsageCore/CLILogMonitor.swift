import Foundation

/// A tool call that the agent surfaced for user approval and that hasn't been
/// answered yet (the "Allow / Deny" prompt in the CLI).
public struct PendingApproval: Sendable, Hashable, Identifiable {
    public var tool: String
    public var step: Int
    public var surfacedAt: Date
    public var conversationID: String?
    public var logFile: String
    public var id: String { "\(logFile)#\(step)" }
}

/// Information derived from the CLI process logs.
public struct CLILogState: Sendable {
    public var pending: [PendingApproval] = []
    /// Most recent model label the CLI propagated to the backend.
    public var lastModelLabel: String?
    public var lastModelDate: Date?
    /// Number of approval prompts surfaced today.
    public var approvalsToday = 0
}

/// Parses `~/.gemini/antigravity-cli/log/cli-*.log` (glog format) to find pending
/// tool confirmations and the latest selected model.
public final class CLILogMonitor {
    public let paths: AgyPaths
    /// Only log files touched within this window are considered "live".
    public var liveWindow: TimeInterval = 6 * 3600
    /// Pending approvals older than this are treated as abandoned.
    public var staleAfter: TimeInterval = 2 * 3600

    private var cache: [String: (modified: Date, state: FileState)] = [:]

    struct FileState {
        var pending: [Int: PendingApproval] = [:]
        var lastConversation: String?
        var lastModel: (String, Date)?
        var surfacedDates: [Date] = []
    }

    public init(paths: AgyPaths = AgyPaths()) {
        self.paths = paths
    }

    public func refresh(now: Date = Date()) -> CLILogState {
        let fm = FileManager.default
        let dir = paths.cliLogDir
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("cli-") && $0.hasSuffix(".log") }

        var result = CLILogState()
        let startOfToday = Calendar.current.startOfDay(for: now)
        var live = Set<String>()

        for name in files {
            let path = dir.appendingPathComponent(name).path
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) < liveWindow else { continue }
            live.insert(path)

            let state: FileState
            if let cached = cache[path], cached.modified == modified {
                state = cached.state
            } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                state = Self.parse(log: text, fileName: name, referenceDate: modified)
                cache[path] = (modified, state)
            } else {
                continue
            }

            for approval in state.pending.values where now.timeIntervalSince(approval.surfacedAt) < staleAfter {
                result.pending.append(approval)
            }
            result.approvalsToday += state.surfacedDates.filter { $0 >= startOfToday }.count
            if let (label, date) = state.lastModel, date > (result.lastModelDate ?? .distantPast) {
                result.lastModelLabel = label
                result.lastModelDate = date
            }
        }
        cache = cache.filter { live.contains($0.key) }
        result.pending.sort { $0.surfacedAt < $1.surfacedAt }
        return result
    }

    // MARK: - Parsing

    private static let surfacing = try! NSRegularExpression(
        pattern: #"Surfacing tool confirmation: "([^"]*)" at step (\d+)"#)
    private static let responding = try! NSRegularExpression(
        pattern: #"Responding to tool confirmation: convID=([0-9a-fA-F-]+), stepIdx=(\d+)"#)
    private static let forwarding = try! NSRegularExpression(
        pattern: #"(?:Forwarding|Sending) user message to conversation ([0-9a-fA-F-]+)"#)
    private static let modelLabel = try! NSRegularExpression(
        pattern: #"Propagating selected model override to backend: label="([^"]+)""#)

    static func parse(log text: String, fileName: String, referenceDate: Date) -> FileState {
        var state = FileState()
        text.enumerateLines { line, _ in
            // Cheap prefilters before running regexes.
            if line.contains("tool confirmation") {
                if let m = firstMatch(surfacing, line), let step = Int(m[1]) {
                    let date = glogDate(line, reference: referenceDate) ?? referenceDate
                    state.pending[step] = PendingApproval(
                        tool: m[0], step: step, surfacedAt: date,
                        conversationID: state.lastConversation, logFile: fileName)
                    state.surfacedDates.append(date)
                } else if let m = firstMatch(responding, line), let step = Int(m[1]) {
                    state.pending.removeValue(forKey: step)
                    state.lastConversation = m[0]
                }
            } else if line.contains("user message to conversation") {
                if let m = firstMatch(forwarding, line) { state.lastConversation = m[0] }
            } else if line.contains("Propagating selected model") {
                if let m = firstMatch(modelLabel, line) {
                    state.lastModel = (m[0], glogDate(line, reference: referenceDate) ?? referenceDate)
                }
            }
        }
        return state
    }

    private static func firstMatch(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }

    /// Parses the glog prefix `I1027 15:53:39.908992` (local time, no year).
    static func glogDate(_ line: String, reference: Date) -> Date? {
        let chars = Array(line.prefix(21))
        guard chars.count >= 21, "IWEF".contains(chars[0]) else { return nil }
        let s = String(chars)
        func num(_ from: Int, _ len: Int) -> Int? {
            let start = s.index(s.startIndex, offsetBy: from)
            return Int(s[start..<s.index(start, offsetBy: len)])
        }
        guard let month = num(1, 2), let day = num(3, 2), let hour = num(6, 2),
              let minute = num(9, 2), let second = num(12, 2) else { return nil }
        let micros = num(15, 6) ?? 0
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.year = calendar.component(.year, from: reference)
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        guard var date = calendar.date(from: comps) else { return nil }
        // Log spanning New Year: a December line in a January-modified file.
        if date > reference.addingTimeInterval(86_400) {
            date = calendar.date(byAdding: .year, value: -1, to: date) ?? date
        }
        return date.addingTimeInterval(Double(micros) / 1_000_000)
    }
}

/// Reads the CLI's `settings.json` (selected model etc.).
public enum CLISettings {
    public static func selectedModel(paths: AgyPaths) -> String? {
        guard let data = try? Data(contentsOf: paths.cliSettings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String, !model.isEmpty else { return nil }
        return model
    }
}
