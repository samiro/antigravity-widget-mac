import Foundation

/// A single quota bucket from Antigravity (e.g. 5-hour limit or weekly limit).
public struct QuotaBucket: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let window: String // "5h", "weekly"
    public let remainingFraction: Double
    public let resetTime: Date?

    public init(id: String, name: String, description: String? = nil, window: String, remainingFraction: Double, resetTime: Date? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.window = window
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
    }

    public var remainingPercent: Int {
        Int(round(min(max(remainingFraction, 0), 1) * 100))
    }
}

/// A group of models sharing limits (e.g. "Gemini Models", "Gemini 4 Argon", "Claude and GPT models").
public struct QuotaGroup: Sendable, Hashable, Identifiable {
    public let name: String
    public let description: String?
    public let buckets: [QuotaBucket]

    public var id: String { name }

    public init(name: String, description: String? = nil, buckets: [QuotaBucket]) {
        self.name = name
        self.description = description
        self.buckets = buckets
    }

    public var fiveHourBucket: QuotaBucket? {
        buckets.first { $0.window == "5h" || $0.name.localizedCaseInsensitiveContains("Five Hour") || $0.name.localizedCaseInsensitiveContains("5H") }
    }

    public var weeklyBucket: QuotaBucket? {
        buckets.first { $0.window == "weekly" || $0.name.localizedCaseInsensitiveContains("Weekly") }
    }
}

/// Normalized limits for a specific model or model family.
public struct ModelQuotaLimits: Sendable, Hashable {
    public let modelName: String
    public let groupName: String
    public let fiveHourPercent: Int?
    public let fiveHourReset: Date?
    public let weeklyPercent: Int?
    public let weeklyReset: Date?

    public init(modelName: String, groupName: String, fiveHourPercent: Int?, fiveHourReset: Date?, weeklyPercent: Int?, weeklyReset: Date?) {
        self.modelName = modelName
        self.groupName = groupName
        self.fiveHourPercent = fiveHourPercent
        self.fiveHourReset = fiveHourReset
        self.weeklyPercent = weeklyPercent
        self.weeklyReset = weeklyReset
    }

    public var resetCountdownString: String? {
        var parts: [String] = []
        if let fReset = fiveHourReset {
            parts.append("5H: \(Self.formatCountdown(fReset))")
        }
        if let wReset = weeklyReset {
            parts.append("Wk: \(Self.formatCountdown(wReset))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func formatCountdown(_ date: Date, relativeTo now: Date = Date()) -> String {
        let diff = date.timeIntervalSince(now)
        if diff <= 0 { return "now" }
        let totalHours = Int(diff) / 3600
        let mins = (Int(diff) % 3600) / 60
        let days = totalHours / 24
        if days > 0 {
            let remHours = totalHours % 24
            return "\(days)d \(remHours)h"
        } else if totalHours > 0 {
            return "\(totalHours)h \(mins)m"
        } else {
            return "\(max(1, mins))m"
        }
    }
}

/// Snapshot of all active quotas fetched from Antigravity.
public struct QuotaSnapshot: Sendable, Hashable {
    public let description: String?
    public let groups: [QuotaGroup]
    public let fetchedAt: Date

    public init(description: String? = nil, groups: [QuotaGroup], fetchedAt: Date = Date()) {
        self.description = description
        self.groups = groups
        self.fetchedAt = fetchedAt
    }

    public static let empty = QuotaSnapshot(groups: [], fetchedAt: .distantPast)

    /// Sensible fallback snapshot when CLI is not immediately reachable.
    public static let fallback = QuotaSnapshot(
        description: "Cached Antigravity quota",
        groups: [
            QuotaGroup(name: "Gemini Models", description: "Gemini Flash, Gemini Pro", buckets: [
                QuotaBucket(id: "gemini-weekly", name: "Weekly Limit Remaining", window: "weekly", remainingFraction: 0.75),
                QuotaBucket(id: "gemini-5h", name: "Five Hour Limit Remaining", window: "5h", remainingFraction: 0.83)
            ]),
            QuotaGroup(name: "Gemini 4 Argon", description: "Gemini 4 Argon", buckets: [
                QuotaBucket(id: "argon-weekly", name: "Gemini 4 Argon Weekly Limit", window: "weekly", remainingFraction: 0.14)
            ]),
            QuotaGroup(name: "Claude and GPT models", description: "Claude & GPT", buckets: [
                QuotaBucket(id: "3p-weekly", name: "Weekly Limit Remaining", window: "weekly", remainingFraction: 0.49),
                QuotaBucket(id: "3p-5h", name: "Five Hour Limit Remaining", window: "5h", remainingFraction: 1.0)
            ])
        ],
        fetchedAt: Date()
    )

    public var geminiGroup: QuotaGroup? {
        groups.first { $0.name.localizedCaseInsensitiveContains("Gemini Models") }
    }

    public var argonGroup: QuotaGroup? {
        groups.first { $0.name.localizedCaseInsensitiveContains("Argon") }
    }

    public var claudeGroup: QuotaGroup? {
        groups.first { $0.name.localizedCaseInsensitiveContains("Claude") || $0.name.localizedCaseInsensitiveContains("3p") }
    }

    /// Resolves the 5H and Weekly remaining limits for a given model.
    public func limits(for modelName: String) -> ModelQuotaLimits {
        let lower = modelName.lowercased()

        if lower.contains("argon") {
            let argon = argonGroup
            let gemini = geminiGroup
            // Argon weekly limit comes from Argon bucket; 5H limit comes from Gemini shared pool.
            let weekly = argon?.weeklyBucket ?? gemini?.weeklyBucket
            let fiveH = argon?.fiveHourBucket ?? gemini?.fiveHourBucket
            return ModelQuotaLimits(
                modelName: modelName,
                groupName: "Gemini 4 Argon",
                fiveHourPercent: fiveH?.remainingPercent,
                fiveHourReset: fiveH?.resetTime,
                weeklyPercent: weekly?.remainingPercent,
                weeklyReset: weekly?.resetTime
            )
        } else if lower.contains("gemini") {
            let gemini = geminiGroup
            let weekly = gemini?.weeklyBucket
            let fiveH = gemini?.fiveHourBucket
            return ModelQuotaLimits(
                modelName: modelName,
                groupName: "Gemini Models",
                fiveHourPercent: fiveH?.remainingPercent,
                fiveHourReset: fiveH?.resetTime,
                weeklyPercent: weekly?.remainingPercent,
                weeklyReset: weekly?.resetTime
            )
        } else {
            let claude = claudeGroup
            let weekly = claude?.weeklyBucket
            let fiveH = claude?.fiveHourBucket
            return ModelQuotaLimits(
                modelName: modelName,
                groupName: "Claude & GPT",
                fiveHourPercent: fiveH?.remainingPercent,
                fiveHourReset: fiveH?.resetTime,
                weeklyPercent: weekly?.remainingPercent,
                weeklyReset: weekly?.resetTime
            )
        }
    }
}

/// Periodically queries `agy -p "/quota" --output-format json` to get live limit percentages.
public actor QuotaMonitor {
    private let paths: AgyPaths
    private var _cachedSnapshot: QuotaSnapshot?
    private var _lastFetch: Date = .distantPast
    private var _isFetching = false

    public init(paths: AgyPaths = AgyPaths()) {
        self.paths = paths
        let cacheFile = paths.base.appendingPathComponent("quota_cache.json")
        if let diskSnapshot = Self.loadDiskCache(from: cacheFile) {
            self._cachedSnapshot = diskSnapshot
        }
    }

    public var currentSnapshot: QuotaSnapshot {
        _cachedSnapshot ?? .fallback
    }

    /// Fetches fresh quota if stale (> 30s) or forced.
    public func refresh(force: Bool = false) async -> QuotaSnapshot {
        let shouldFetch = force || _cachedSnapshot == nil || Date().timeIntervalSince(_lastFetch) > 30
        if !shouldFetch || _isFetching {
            return _cachedSnapshot ?? .fallback
        }
        _isFetching = true
        defer { _isFetching = false }

        if let fresh = await executeAgyQuota() {
            _cachedSnapshot = fresh
            _lastFetch = Date()
            Self.saveDiskCache(fresh, to: paths.base.appendingPathComponent("quota_cache.json"))
            return fresh
        }

        return _cachedSnapshot ?? .fallback
    }

    private func executeAgyQuota() async -> QuotaSnapshot? {
        let agyURL = findAgyExecutable()
        guard let agyURL else { return nil }

        return await Task.detached(priority: .utility) { [agyURL] () -> QuotaSnapshot? in
            let process = Process()
            process.executableURL = agyURL
            process.arguments = ["-p", "/quota", "--output-format", "json"]

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0, !data.isEmpty else { return nil }
                return Self.parseJSON(data)
            } catch {
                return nil
            }
        }.value
    }

    private func findAgyExecutable() -> URL? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            paths.base.appendingPathComponent("bin/agy")
        ]
        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func saveDiskCache(_ snapshot: QuotaSnapshot, to fileURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        struct CacheFormat: Codable {
            struct GroupFormat: Codable {
                struct BucketFormat: Codable {
                    let id: String
                    let name: String
                    let description: String?
                    let window: String
                    let remainingFraction: Double
                    let resetTime: Date?
                }
                let name: String
                let description: String?
                let buckets: [BucketFormat]
            }
            let description: String?
            let groups: [GroupFormat]
            let fetchedAt: Date
        }

        let fmt = CacheFormat(
            description: snapshot.description,
            groups: snapshot.groups.map { g in
                CacheFormat.GroupFormat(
                    name: g.name,
                    description: g.description,
                    buckets: g.buckets.map { b in
                        CacheFormat.GroupFormat.BucketFormat(
                            id: b.id,
                            name: b.name,
                            description: b.description,
                            window: b.window,
                            remainingFraction: b.remainingFraction,
                            resetTime: b.resetTime
                        )
                    }
                )
            },
            fetchedAt: snapshot.fetchedAt
        )

        if let data = try? encoder.encode(fmt) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func loadDiskCache(from fileURL: URL) -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct CacheFormat: Codable {
            struct GroupFormat: Codable {
                struct BucketFormat: Codable {
                    let id: String
                    let name: String
                    let description: String?
                    let window: String
                    let remainingFraction: Double
                    let resetTime: Date?
                }
                let name: String
                let description: String?
                let buckets: [BucketFormat]
            }
            let description: String?
            let groups: [GroupFormat]
            let fetchedAt: Date
        }

        guard let fmt = try? decoder.decode(CacheFormat.self, from: data) else { return nil }
        let groups = fmt.groups.map { g in
            QuotaGroup(
                name: g.name,
                description: g.description,
                buckets: g.buckets.map { b in
                    QuotaBucket(
                        id: b.id,
                        name: b.name,
                        description: b.description,
                        window: b.window,
                        remainingFraction: b.remainingFraction,
                        resetTime: b.resetTime
                    )
                }
            )
        }
        return QuotaSnapshot(description: fmt.description, groups: groups, fetchedAt: fmt.fetchedAt)
    }

    public static func parseJSON(_ data: Data) -> QuotaSnapshot? {
        struct ResponsePayload: Decodable {
            struct Command: Decodable {
                let name: String
                let data: DataPayload
            }
            struct DataPayload: Decodable {
                let description: String?
                let groups: [RawGroup]
            }
            struct RawGroup: Decodable {
                let name: String
                let description: String?
                let buckets: [RawBucket]
            }
            struct RawBucket: Decodable {
                let id: String
                let name: String
                let description: String?
                let window: String
                let remaining_fraction: Double
                let reset_time: String?
            }
            let command: Command?
            let response: String?
        }

        guard let decoded = try? JSONDecoder().decode(ResponsePayload.self, from: data) else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFallback = ISO8601DateFormatter()

        if let cmd = decoded.command {
            let groups = cmd.data.groups.map { g in
                let buckets = g.buckets.map { b -> QuotaBucket in
                    let reset = b.reset_time.flatMap { iso.date(from: $0) ?? isoFallback.date(from: $0) }
                    return QuotaBucket(
                        id: b.id,
                        name: b.name,
                        description: b.description,
                        window: b.window,
                        remainingFraction: b.remaining_fraction,
                        resetTime: reset
                    )
                }
                return QuotaGroup(name: g.name, description: g.description, buckets: buckets)
            }
            return QuotaSnapshot(description: cmd.data.description, groups: groups, fetchedAt: Date())
        }

        // Fallback: parse TSV response string if present
        if let responseStr = decoded.response, !responseStr.isEmpty {
            return parseTSV(responseStr)
        }

        return nil
    }

    private static func parseTSV(_ text: String) -> QuotaSnapshot {
        let lines = text.split(separator: "\n").map(String.init)
        var groupsDict: [String: [QuotaBucket]] = [:]
        let iso = ISO8601DateFormatter()

        for line in lines {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 3 else { continue }
            let groupName = parts[0].trimmingCharacters(in: .whitespaces)
            let bucketName = parts[1].trimmingCharacters(in: .whitespaces)
            let pctStr = parts[2].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            let fraction = (Double(pctStr) ?? 0.0) / 100.0
            let resetTime = parts.count >= 4 ? iso.date(from: parts[3].trimmingCharacters(in: .whitespaces)) : nil
            let window = bucketName.localizedCaseInsensitiveContains("5") ? "5h" : "weekly"

            let bucket = QuotaBucket(
                id: "\(groupName)-\(window)",
                name: bucketName,
                window: window,
                remainingFraction: fraction,
                resetTime: resetTime
            )
            groupsDict[groupName, default: []].append(bucket)
        }

        let groups = groupsDict.map { QuotaGroup(name: $0.key, buckets: $0.value) }
        return QuotaSnapshot(description: "Parsed from TSV", groups: groups, fetchedAt: Date())
    }
}
