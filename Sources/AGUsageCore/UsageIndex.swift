import Foundation

/// Keeps an incrementally-updated index of usage events across every
/// Antigravity transcript on disk. Only new bytes are parsed on each refresh.
///
/// Not thread-safe: own it from a single actor/queue.
public final class UsageIndex {
    private struct Entry {
        var parser: TranscriptParser
        var events: [UsageEvent]
        var modified: Date?
    }

    public let paths: AgyPaths
    public let sources: [AgySource]
    private var entries: [String: Entry] = [:] // keyed by file path

    public init(paths: AgyPaths = AgyPaths(), sources: [AgySource] = AgySource.allCases) {
        self.paths = paths
        self.sources = sources
    }

    /// Re-scans transcript directories and returns all known events.
    @discardableResult
    public func refresh() -> [UsageEvent] {
        var seen = Set<String>()
        let fm = FileManager.default

        for source in sources {
            for (conversationID, url) in paths.transcripts(source) {
                let key = url.path
                seen.insert(key)
                let modified = (try? fm.attributesOfItem(atPath: key))?[.modificationDate] as? Date

                var entry = entries[key] ?? Entry(
                    parser: TranscriptParser(source: source, conversationID: conversationID),
                    events: [],
                    modified: nil
                )
                if entry.modified != nil, entry.modified == modified {
                    continue // unchanged since last scan
                }
                let previousOffset = entry.parser.offset
                do {
                    let newEvents = try entry.parser.consumeNewData(at: url)
                    if entry.parser.offset < previousOffset || (previousOffset > 0 && entry.parser.offset == 0) {
                        entry.events = newEvents // file was rewritten
                    } else {
                        entry.events.append(contentsOf: newEvents)
                    }
                    entry.modified = modified
                } catch {
                    // Unreadable right now (e.g. mid-write); try again next refresh.
                }
                entries[key] = entry
            }
        }

        // Drop transcripts that disappeared.
        for key in entries.keys where !seen.contains(key) {
            entries.removeValue(forKey: key)
        }
        return allEvents
    }

    public var allEvents: [UsageEvent] {
        entries.values.flatMap(\.events)
    }

    /// Latest model seen for a conversation (from its transcript), if any.
    public func lastModel(conversationID: String) -> String? {
        entries.values.first { $0.parser.conversationID == conversationID }?.parser.currentModel
    }
}
