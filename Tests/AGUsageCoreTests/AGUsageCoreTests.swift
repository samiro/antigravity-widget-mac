import Foundation
import Testing
@testable import AGUsageCore

// MARK: - Fixtures

/// Builds a temporary `~/.gemini`-like tree for tests.
struct Fixture {
    let base: URL
    var paths: AgyPaths { AgyPaths(base: base) }

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-widget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func writeTranscript(_ source: AgySource, _ id: String, _ lines: [String]) throws -> URL {
        let url = paths.transcript(source, conversationID: id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func append(_ url: URL, _ text: String) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

func userInput(_ text: String, at date: String = "2026-10-27T20:52:39Z") -> String {
    let obj: [String: Any] = ["step_index": 0, "source": "USER_EXPLICIT", "type": "USER_INPUT",
                              "status": "DONE", "created_at": date, "content": text]
    return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
}

func modelChange(from: String, to: String) -> String {
    userInput("<USER_REQUEST>\nhi\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from \(from) to \(to). No need to comment on this change if the user doesn't ask about it.\n</USER_SETTINGS_CHANGE>")
}

func planner(_ input: Int?, _ cache: Int?, _ output: Int?, at date: String = "2026-10-27T20:53:00Z") -> String {
    var obj: [String: Any] = ["step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE",
                              "status": "DONE", "created_at": date]
    if let input { obj["input_tokens"] = input }
    if let cache { obj["cache_read_tokens"] = cache }
    if let output { obj["output_tokens"] = output }
    return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
}

// MARK: - Model change parsing

@Suite struct ModelChangeTests {
    @Test func parsesSimpleChange() {
        let text = "The user changed setting `Model Selection` from None to Gemini 3.8 Flash (Medium). No need to comment."
        #expect(TranscriptParser.modelChange(in: text) == "Gemini 3.8 Flash (Medium)")
    }

    @Test func handlesDotsInsideVersionNumbers() {
        let text = "setting `Model Selection` from Gemini 3.8 Flash (Medium) to Claude Opus 5.5 (Medium). If reporting"
        #expect(TranscriptParser.modelChange(in: text) == "Claude Opus 5.5 (Medium)")
    }

    @Test func handlesEmptyFromAndEndOfString() {
        #expect(TranscriptParser.modelChange(in: "setting `Model Selection` from  to Gemini 3.8 Flash (High).") == "Gemini 3.8 Flash (High)")
    }

    @Test func lastChangeWins() {
        let text = "`Model Selection` from None to A 1.0. x\n`Model Selection` from A 1.0 to B 2.0 (Low). y"
        #expect(TranscriptParser.modelChange(in: text) == "B 2.0 (Low)")
    }

    @Test func ignoresUnrelatedText() {
        #expect(TranscriptParser.modelChange(in: "please change the modal selection to dark") == nil)
        #expect(TranscriptParser.modelChange(in: "`Model Selection` from X to None. ok") == nil)
    }
}

// MARK: - Transcript parsing

@Suite struct TranscriptParserTests {
    @Test func attributesTokensToActiveModel() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.writeTranscript(.cli, "conv1", [
            planner(10, 0, 1), // before any model note → unknown
            modelChange(from: "None", to: "Gemini 3.8 Flash (Medium)"),
            planner(100, 50, 5),
            planner(nil, nil, nil), // step without token info
            modelChange(from: "Gemini 3.8 Flash (Medium)", to: "Claude Opus 5.5 (High)"),
            planner(200, 300, 20),
            "not json at all",
        ])

        var parser = TranscriptParser(source: .cli, conversationID: "conv1")
        let events = try parser.consumeNewData(at: url)
        #expect(events.count == 4)
        #expect(events[0].model == unknownModel)
        #expect(events[1].model == "Gemini 3.8 Flash (Medium)")
        #expect(events[1].totalTokens == 155)
        #expect(events[1].contextTokens == 150)
        #expect(events[2].hasTokens == false)
        #expect(events[3].model == "Claude Opus 5.5 (High)")
        #expect(events[3].cacheRead == 300)
        #expect(parser.currentModel == "Claude Opus 5.5 (High)")
    }

    @Test func readsIncrementallyAndWaitsForCompleteLines() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.writeTranscript(.cli, "c", [modelChange(from: "None", to: "M1"), planner(1, 2, 3)])
        var parser = TranscriptParser(source: .cli, conversationID: "c")
        #expect(try parser.consumeNewData(at: url).count == 1)
        #expect(try parser.consumeNewData(at: url).isEmpty)

        // Half a line: not consumed yet.
        let line = planner(4, 5, 6)
        let half = line.index(line.startIndex, offsetBy: line.count / 2)
        try fx.append(url, String(line[..<half]))
        #expect(try parser.consumeNewData(at: url).isEmpty)
        try fx.append(url, String(line[half...]) + "\n")
        let more = try parser.consumeNewData(at: url)
        #expect(more.count == 1)
        #expect(more.first?.model == "M1")
        #expect(more.first?.output == 6)
    }

    @Test func resetsWhenFileShrinks() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let url = try fx.writeTranscript(.cli, "c", [planner(1, 1, 1), planner(1, 1, 1), planner(1, 1, 1)])
        var parser = TranscriptParser(source: .cli, conversationID: "c")
        #expect(try parser.consumeNewData(at: url).count == 3)
        try (planner(9, 9, 9) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let events = try parser.consumeNewData(at: url)
        #expect(events.count == 1)
        #expect(events.first?.input == 9)
    }

    @Test func parsesDates() {
        #expect(TranscriptParser.parseDate("2026-10-27T20:52:39Z") != nil)
        #expect(TranscriptParser.parseDate("2026-10-27T20:52:39.123Z") != nil)
        #expect(TranscriptParser.parseDate("garbage") == nil)
    }
}

// MARK: - Index + summary

@Suite struct UsageIndexTests {
    @Test func indexesAllSourcesAndPicksUpAppends() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let cli = try fx.writeTranscript(.cli, "a", [modelChange(from: "None", to: "M1"), planner(10, 0, 1)])
        _ = try fx.writeTranscript(.ide, "b", [modelChange(from: "None", to: "M2"), planner(nil, nil, nil)])

        let index = UsageIndex(paths: fx.paths)
        #expect(index.refresh().count == 2)

        try fx.append(cli, planner(5, 5, 5) + "\n")
        // Ensure mtime changes even on coarse-resolution filesystems.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: cli.path)
        let events = index.refresh()
        #expect(events.count == 3)
        #expect(events.filter { $0.source == .cli }.count == 2)
        #expect(index.lastModel(conversationID: "b") == "M2")
    }

    @Test func summaryGroupsByModelSourceAndDay() throws {
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let old = cal.date(byAdding: .day, value: -40, to: now)!
        let events = [
            UsageEvent(date: now, model: "A", source: .cli, conversationID: "1", input: 100, cacheRead: 100, output: 10),
            UsageEvent(date: now, model: "B", source: .ide, conversationID: "2", input: 1, cacheRead: 0, output: 1),
            UsageEvent(date: yesterday, model: "A", source: .cli, conversationID: "1", input: 50, cacheRead: 0, output: 5),
            UsageEvent(date: old, model: "C", source: .app, conversationID: "3", input: 1000, cacheRead: 0, output: 0),
        ]

        let today = UsageSummary.make(events: events, range: .today, now: now)
        #expect(today.totals.requests == 2)
        #expect(today.totals.total == 212)
        #expect(today.byModel.map(\.model) == ["A", "B"])
        #expect(today.conversationCount == 2)
        #expect(abs(today.totals.cacheHitRate - 100.0 / 201.0) < 0.0001)

        let week = UsageSummary.make(events: events, range: .week, now: now)
        #expect(week.totals.requests == 3)
        #expect(week.byModel.first?.totals.requests == 2)
        #expect(week.bySource.first?.source == .cli)

        let all = UsageSummary.make(events: events, range: .all, now: now)
        #expect(all.byModel.first?.model == "C")
        #expect(all.totals.requests == 4)

        #expect(today.daily.count == 14)
        #expect(today.daily.last?.totals.requests == 2)
        #expect(today.daily[12].totals.requests == 1)
    }
}

// MARK: - Logs

@Suite struct CLILogTests {
    static let log = """
    I1027 15:52:38.685943     254 model_config_manager.go:340] Propagating selected model override to backend: label="Gemini 3.8 Flash (Medium)"
    I1027 15:52:39.808740     527 conversation_manager.go:893] Forwarding user message to conversation c7c9c76f-02b6-474f-b631-dc42eb11890c (items=1, media=0)
    I1027 15:53:39.908992    2718 tool_confirmation_manager.go:231] Surfacing tool confirmation: "RunCommand" at step 7
    I1027 15:53:53.647781     282 input_loop.go:753] Responding to tool confirmation: convID=c7c9c76f-02b6-474f-b631-dc42eb11890c, stepIdx=7, approved=true, sandboxOverride=false, persistGrants=[]
    I1027 15:53:59.494558    2718 tool_confirmation_manager.go:231] Surfacing tool confirmation: "EditFile" at step 9
    I1027 15:54:01.000000     254 model_config_manager.go:340] Propagating selected model override to backend: label="Claude Opus 5.5 (Medium)"
    """

    @Test func findsPendingApprovalsAndModel() throws {
        let reference = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 16))!
        let state = CLILogMonitor.parse(log: Self.log, fileName: "cli-x.log", referenceDate: reference)
        #expect(state.pending.count == 1)
        let pending = try #require(state.pending[9])
        #expect(pending.tool == "EditFile")
        #expect(pending.conversationID == "c7c9c76f-02b6-474f-b631-dc42eb11890c")
        #expect(state.surfacedDates.count == 2)
        #expect(state.lastModel?.0 == "Claude Opus 5.5 (Medium)")

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: pending.surfacedAt)
        #expect(comps.year == 2026 && comps.month == 10 && comps.day == 27)
        #expect(comps.hour == 15 && comps.minute == 53 && comps.second == 59)
    }

    @Test func monitorReadsLogDirectoryAndDropsStale() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try FileManager.default.createDirectory(at: fx.paths.cliLogDir, withIntermediateDirectories: true)
        let file = fx.paths.cliLogDir.appendingPathComponent("cli-20261027_155236.log")
        try Self.log.write(to: file, atomically: true, encoding: .utf8)

        let surfaced = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 15, minute: 54))!
        try FileManager.default.setAttributes([.modificationDate: surfaced], ofItemAtPath: file.path)

        let monitor = CLILogMonitor(paths: fx.paths)
        let fresh = monitor.refresh(now: surfaced.addingTimeInterval(60))
        #expect(fresh.pending.map(\.tool) == ["EditFile"])
        #expect(fresh.lastModelLabel == "Claude Opus 5.5 (Medium)")
        #expect(fresh.approvalsToday == 2)

        let later = monitor.refresh(now: surfaced.addingTimeInterval(3 * 3600))
        #expect(later.pending.isEmpty)
    }

    @Test func glogYearRollover() {
        let jan = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 1, hour: 0, minute: 5))!
        let date = CLILogMonitor.glogDate("I1231 23:59:59.000000 1 x.go:1] hi", reference: jan)
        #expect(date.map { Calendar.current.component(.year, from: $0) } == 2026)
    }
}

// MARK: - Misc

@Suite struct MiscTests {
    @Test func tokenFormatting() {
        #expect(UsageFormat.tokens(950) == "950")
        #expect(UsageFormat.tokens(12_300) == "12.3K")
        #expect(UsageFormat.tokens(4_560_000) == "4.56M")
        #expect(UsageFormat.tokens(126_000_000) == "126M")
        #expect(UsageFormat.tokens(1_000) == "1K")
    }

    @Test func shortModelNames() {
        #expect(UsageFormat.shortModel("Claude Opus 5.5 (Medium)") == "Opus 5.5 · Med")
        #expect(UsageFormat.shortModel("Gemini 3.8 Flash (High)") == "Gemini 3.8 Flash · High")
        #expect(UsageFormat.shortModel("Custom") == "Custom")
    }

    @Test func sqliteDates() {
        let d = ConversationStore.parseSQLiteDate("2026-10-27 20:58:27.440214+00:00")
        #expect(d != nil)
        #expect(ConversationStore.parseSQLiteDate("2026-10-27 20:58:27") != nil)
        #expect(ConversationStore.parseSQLiteDate("") == nil)
    }

    @Test func workspaceParsing() {
        #expect(ConversationStore.firstWorkspace(#"["file:///Users/me/proj","file:///x"]"#) == "file:///Users/me/proj")
        #expect(ConversationStore.firstWorkspace("file:///a,file:///b") == "file:///a")
        #expect(ConversationStore.firstWorkspace("") == nil)
    }

    @Test func rangeStarts() {
        let now = Date()
        #expect(UsageRange.all.start(now: now) == nil)
        #expect(UsageRange.today.start(now: now) == Calendar.current.startOfDay(for: now))
    }

    @Test func endToEndMonitorSnapshot() throws {
        let fx = try Fixture()
        defer { fx.cleanup() }

        // Write CLI settings.json
        let cliRoot = fx.paths.root(.cli)
        try FileManager.default.createDirectory(at: cliRoot, withIntermediateDirectories: true)
        try #"{"model":"Gemini 4 Argon (Medium)"}"#.write(
            to: fx.paths.cliSettings, atomically: true, encoding: .utf8
        )

        // Write a transcript
        let isoNow = ISO8601DateFormatter().string(from: Date())
        _ = try fx.writeTranscript(.cli, "conv-1", [
            modelChange(from: "None", to: "Gemini 4 Argon (Medium)"),
            planner(1500, 8500, 400, at: isoNow),
        ])

        let monitor = UsageMonitor(paths: fx.paths)
        let snap = monitor.snapshot()
        #expect(snap.currentModel == "Gemini 4 Argon (Medium)")
        #expect(snap.totalEvents == 1)
        #expect(snap.summary(.today).totals.total == 10_400)
        #expect(snap.latestEvent?.contextTokens == 10_000)
    }
}

@Suite struct QuotaMonitorTests {
    @Test func parsesQuotaJSONAndResolvesLimits() {
        let jsonString = """
        {
          "conversation_id": "",
          "status": "SUCCESS",
          "response": "Gemini Models\\tWeekly Limit Remaining\\t75%\\n",
          "command": {
            "name": "usage",
            "data": {
              "description": "quota test",
              "groups": [
                {
                  "name": "Gemini Models",
                  "description": "Flash and Pro",
                  "buckets": [
                    {
                      "id": "gemini-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.748,
                      "reset_time": "2026-11-02T05:08:24Z"
                    },
                    {
                      "id": "gemini-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 0.828,
                      "reset_time": "2026-10-28T07:53:29Z"
                    }
                  ]
                },
                {
                  "name": "Claude and GPT models",
                  "buckets": [
                    {
                      "id": "3p-weekly",
                      "name": "Weekly Limit Remaining",
                      "window": "weekly",
                      "remaining_fraction": 0.488,
                      "reset_time": "2026-11-03T20:53:35Z"
                    },
                    {
                      "id": "3p-5h",
                      "name": "Five Hour Limit Remaining",
                      "window": "5h",
                      "remaining_fraction": 1.0,
                      "reset_time": "2026-10-28T08:40:18Z"
                    }
                  ]
                },
                {
                  "name": "Gemini 4 Argon",
                  "buckets": [
                    {
                      "id": "gemini-argon-wtu-weekly",
                      "name": "Gemini 4 Argon Weekly Limit",
                      "window": "weekly",
                      "remaining_fraction": 0.142,
                      "reset_time": "2026-11-02T05:33:42Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """

        let snapshot = QuotaMonitor.parseJSON(Data(jsonString.utf8))
        #expect(snapshot != nil)
        guard let snapshot else { return }

        // Test Gemini 4 Argon limits (Argon weekly: 14%, shares Gemini 5H: 83%)
        let argonLimits = snapshot.limits(for: "Gemini 4 Argon (Medium)")
        #expect(argonLimits.groupName == "Gemini 4 Argon")
        #expect(argonLimits.weeklyPercent == 14)
        #expect(argonLimits.fiveHourPercent == 83)

        // Test standard Gemini models (Weekly: 75%, 5H: 83%)
        let geminiLimits = snapshot.limits(for: "Gemini 3.8 Flash (High)")
        #expect(geminiLimits.groupName == "Gemini Models")
        #expect(geminiLimits.weeklyPercent == 75)
        #expect(geminiLimits.fiveHourPercent == 83)

        // Test Claude models (Weekly: 49%, 5H: 100%)
        let claudeLimits = snapshot.limits(for: "Claude Opus 5.5 (Medium)")
        #expect(claudeLimits.groupName == "Claude & GPT")
        #expect(claudeLimits.weeklyPercent == 49)
        #expect(claudeLimits.fiveHourPercent == 100)
    }
}
