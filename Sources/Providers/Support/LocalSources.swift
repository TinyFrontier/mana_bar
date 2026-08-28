import Foundation

/// Process-environment access behind a seam, so auth-store tests can point a
/// store at a temporary directory (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) without
/// mutating the real process environment or touching the user's `~/.claude`.
protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    func value(for name: String) -> String? {
        ProcessInfo.processInfo.environment[name]?.nilIfBlank
    }
}

/// Fixed environment, for tests and for pinning a store to a directory.
struct StaticEnvironment: EnvironmentReading {
    var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func value(for name: String) -> String? {
        values[name]?.nilIfBlank
    }
}

/// Text-file access behind a seam for the same reason. Paths may be `~`-based;
/// implementations expand them.
protocol TextFileAccessing: Sendable {
    func exists(_ path: String) -> Bool
    func readText(_ path: String) throws -> String
    func writeText(_ path: String, _ text: String) throws
}

extension TextFileAccessing {
    /// Contents when present and readable, `nil` otherwise — the shape most
    /// credential probes want.
    func readTextIfPresent(_ path: String) -> String? {
        guard exists(path) else { return nil }
        return try? readText(path)
    }
}

struct LocalTextFileAccessor: TextFileAccessing {
    init() {}

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.expand(path))
    }

    func readText(_ path: String) throws -> String {
        try String(contentsOfFile: Self.expand(path), encoding: .utf8)
    }

    func writeText(_ path: String, _ text: String) throws {
        let expanded = Self.expand(path)
        try text.write(toFile: expanded, atomically: true, encoding: .utf8)
        // Credential files stay owner-only, matching what the CLI tools write.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: expanded
        )
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
