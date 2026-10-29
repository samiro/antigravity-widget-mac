import Foundation
import SQLite3

/// A conversation as listed in Antigravity's `conversation_summaries.db`.
public struct ConversationInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var source: AgySource
    public var title: String
    public var status: String
    public var stepCount: Int
    public var lastModified: Date
    public var isBusy: Bool
    public var workspace: String?

    public init(id: String, source: AgySource, title: String, status: String, stepCount: Int, lastModified: Date, isBusy: Bool, workspace: String? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.status = status
        self.stepCount = stepCount
        self.lastModified = lastModified
        self.isBusy = isBusy
        self.workspace = workspace
    }

    /// True while the agent is generating or executing.
    public var isRunning: Bool {
        isBusy || status.hasSuffix("RUNNING")
    }

    /// Human-friendly status, e.g. "Running", "Idle".
    public var statusLabel: String {
        let raw = status.replacingOccurrences(of: "CASCADE_RUN_STATUS_", with: "")
        guard !raw.isEmpty else { return isBusy ? "Running" : "Unknown" }
        return raw.prefix(1).uppercased() + raw.dropFirst().lowercased().replacingOccurrences(of: "_", with: " ")
    }

    /// Last path component of the first workspace, if any.
    public var workspaceName: String? {
        guard let workspace, !workspace.isEmpty else { return nil }
        return URL(string: workspace)?.lastPathComponent ?? (workspace as NSString).lastPathComponent
    }
}

/// Read-only access to the conversation summary databases.
public enum ConversationStore {
    /// Returns the most recent conversations across sources, newest first.
    public static func recent(paths: AgyPaths, sources: [AgySource] = AgySource.allCases,
                              limit: Int = 50) -> [ConversationInfo] {
        var all: [ConversationInfo] = []
        for source in sources {
            all.append(contentsOf: load(db: paths.summariesDB(source), source: source, limit: limit))
        }
        return Array(all.sorted { $0.lastModified > $1.lastModified }.prefix(limit))
    }

    static func load(db url: URL, source: AgySource, limit: Int) -> [ConversationInfo] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var handle: OpaquePointer?
        // Read-only; never creates or mutates Antigravity's database.
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
        SELECT conversation_id, title, preview, status, step_count, last_modified_time,
               not_fully_idle, workspace_uris
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var rows: [ConversationInfo] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0)
            guard !id.isEmpty else { continue }
            let title = text(stmt, 1)
            let preview = text(stmt, 2)
            rows.append(ConversationInfo(
                id: id,
                source: source,
                title: title.isEmpty ? (preview.isEmpty ? "Untitled conversation" : preview) : title,
                status: text(stmt, 3),
                stepCount: Int(sqlite3_column_int64(stmt, 4)),
                lastModified: parseSQLiteDate(text(stmt, 5)) ?? .distantPast,
                isBusy: sqlite3_column_int(stmt, 6) != 0 || text(stmt, 6) == "true",
                workspace: firstWorkspace(text(stmt, 7))
            ))
        }
        return rows
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    /// `workspace_uris` may be a JSON array, a comma list or a single URI.
    static func firstWorkspace(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return array.first
        }
        return trimmed.split(separator: ",").first.map(String.init)
    }

    /// Parses timestamps such as `2026-10-27 20:58:27.440214+00:00`.
    public static func parseSQLiteDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        var s = raw.replacingOccurrences(of: " ", with: "T")
        // Trim sub-second precision to milliseconds so ISO8601DateFormatter accepts it.
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s[s.index(after: dot)...]
            let digits = afterDot.prefix { $0.isNumber }
            let rest = afterDot.dropFirst(digits.count)
            s = String(s[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
        }
        if !(s.hasSuffix("Z") || s.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil) {
            s += "Z"
        }
        return TranscriptParser.parseDate(s)
    }
}
