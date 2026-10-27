import Foundation

/// A single model call (one `PLANNER_RESPONSE` step in a transcript).
public struct UsageEvent: Sendable, Hashable {
    public var date: Date
    public var model: String
    public var source: AgySource
    public var conversationID: String
    /// Uncached prompt tokens.
    public var input: Int
    /// Prompt tokens served from cache (reported separately from `input`).
    public var cacheRead: Int
    public var output: Int
    /// Whether the transcript reported token counts for this step at all.
    public var hasTokens: Bool

    public init(date: Date, model: String, source: AgySource, conversationID: String,
                input: Int = 0, cacheRead: Int = 0, output: Int = 0, hasTokens: Bool = true) {
        self.date = date
        self.model = model
        self.source = source
        self.conversationID = conversationID
        self.input = input
        self.cacheRead = cacheRead
        self.output = output
        self.hasTokens = hasTokens
    }

    /// Everything the model processed for this step.
    public var totalTokens: Int { input + cacheRead + output }

    /// Size of the prompt (approximate context window occupancy).
    public var contextTokens: Int { input + cacheRead }
}

/// Label used when a conversation's model can't be determined from its transcript.
public let unknownModel = "Unknown model"

/// Streaming, incremental parser for Antigravity `transcript.jsonl` files.
///
/// Model attribution works by following `<USER_SETTINGS_CHANGE>` notes that
/// Antigravity injects into user inputs whenever the selected model changes
/// (e.g. "…changed setting `Model Selection` from X to Y."). Each subsequent
/// `PLANNER_RESPONSE` is attributed to the latest model seen.
public struct TranscriptParser: Sendable {
    public let source: AgySource
    public let conversationID: String
    /// Model in effect at the current read position.
    public private(set) var currentModel: String?
    /// Byte offset just past the last fully-consumed line.
    public private(set) var offset: UInt64 = 0

    public init(source: AgySource, conversationID: String, initialModel: String? = nil) {
        self.source = source
        self.conversationID = conversationID
        self.currentModel = initialModel
    }

    /// Resets the parser so the file is re-read from the start.
    public mutating func reset() {
        offset = 0
        currentModel = nil
    }

    /// Reads any new complete lines from `url` and returns the usage events found.
    /// Partial trailing lines are left for the next call.
    public mutating func consumeNewData(at url: URL) throws -> [UsageEvent] {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if size < offset { reset() } // file was truncated / rewritten
        guard size > offset else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }

        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        return consume(lines: complete)
    }

    /// Parses a buffer of newline-separated JSON objects.
    public mutating func consume(lines buffer: Data) -> [UsageEvent] {
        var events: [UsageEvent] = []
        for line in buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let event = consume(line: Data(line)) {
                events.append(event)
            }
        }
        return events
    }

    /// Parses a single JSON line, updating model state; returns an event for model responses.
    public mutating func consume(line: Data) -> UsageEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }

        switch type {
        case "USER_INPUT":
            if let content = object["content"] as? String,
               let model = Self.modelChange(in: content) {
                currentModel = model
            }
            return nil
        case "PLANNER_RESPONSE":
            let input = Self.int(object["input_tokens"])
            let cache = Self.int(object["cache_read_tokens"])
            let output = Self.int(object["output_tokens"])
            let hasTokens = input != nil || cache != nil || output != nil
            let date = (object["created_at"] as? String).flatMap(Self.parseDate) ?? Date()
            return UsageEvent(
                date: date,
                model: currentModel ?? unknownModel,
                source: source,
                conversationID: conversationID,
                input: input ?? 0,
                cacheRead: cache ?? 0,
                output: output ?? 0,
                hasTokens: hasTokens
            )
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static let modelChangeRegex = try! NSRegularExpression(
        pattern: #"`Model Selection` from (.*?) to (.+?)\.(?:\s|$)"#,
        options: []
    )

    /// Extracts the new model name from a `<USER_SETTINGS_CHANGE>` note, if present.
    /// When several changes appear in one message, the last one wins.
    public static func modelChange(in content: String) -> String? {
        guard content.contains("Model Selection") else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = modelChangeRegex.matches(in: content, range: range).last,
              let toRange = Range(match.range(at: 2), in: content) else { return nil }
        let model = content[toRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model != "None" else { return nil }
        return model
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parseDate(_ string: String) -> Date? {
        isoPlain.date(from: string) ?? isoFractional.date(from: string)
    }
}
