import Foundation

/// One of the Antigravity products that writes local data under `~/.gemini`.
public enum AgySource: String, CaseIterable, Sendable, Codable, Hashable {
    /// The `agy` terminal CLI (`~/.gemini/antigravity-cli`).
    case cli = "antigravity-cli"
    /// The Antigravity desktop app / agent manager (`~/.gemini/antigravity`).
    case app = "antigravity"
    /// The Antigravity IDE (`~/.gemini/antigravity-ide`).
    case ide = "antigravity-ide"

    public var displayName: String {
        switch self {
        case .cli: return "CLI"
        case .app: return "App"
        case .ide: return "IDE"
        }
    }
}

/// Resolves the on-disk locations the widget reads from.
///
/// All access is read-only. The base directory defaults to `~/.gemini` and can be
/// overridden with the `AGY_WIDGET_HOME` environment variable (useful for tests
/// and for pointing the widget at a copied data snapshot).
public struct AgyPaths: Sendable {
    public let base: URL

    public init(base: URL? = nil) {
        if let base {
            self.base = base
        } else if let env = ProcessInfo.processInfo.environment["AGY_WIDGET_HOME"], !env.isEmpty {
            self.base = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".gemini", isDirectory: true)
        }
    }

    public func root(_ source: AgySource) -> URL {
        base.appendingPathComponent(source.rawValue, isDirectory: true)
    }

    public func brain(_ source: AgySource) -> URL {
        root(source).appendingPathComponent("brain", isDirectory: true)
    }

    public func summariesDB(_ source: AgySource) -> URL {
        root(source).appendingPathComponent("conversation_summaries.db")
    }

    /// CLI settings JSON (contains the currently selected model).
    public var cliSettings: URL {
        root(.cli).appendingPathComponent("settings.json")
    }

    /// Directory with one log file per CLI process.
    public var cliLogDir: URL {
        root(.cli).appendingPathComponent("log", isDirectory: true)
    }

    /// Most recent CLI log (mirrors the active process).
    public var cliLog: URL {
        root(.cli).appendingPathComponent("cli.log")
    }

    /// Path of the compact transcript for a conversation.
    public func transcript(_ source: AgySource, conversationID: String) -> URL {
        brain(source)
            .appendingPathComponent(conversationID, isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript.jsonl")
    }

    /// Lists all transcript files for a source as `(conversationID, url)` pairs.
    public func transcripts(_ source: AgySource) -> [(String, URL)] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: brain(source).path) else { return [] }
        return ids.compactMap { id in
            guard !id.hasPrefix(".") else { return nil }
            let url = transcript(source, conversationID: id)
            return fm.fileExists(atPath: url.path) ? (id, url) : nil
        }
    }
}
