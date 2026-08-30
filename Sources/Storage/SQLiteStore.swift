import Foundation

/// Read-only access to a SQLite key/value table.
///
/// Cursor keeps its login in `state.vscdb` — the same `ItemTable` VS Code uses
/// for global storage — so reading it is the only way to reuse that login
/// (ТЗ §4.1 applied to Cursor). Mana never writes to it.
protocol SQLiteReading: Sendable {
    /// Value for `key` in a `key`/`value` table, or `nil` when the row, the
    /// table or the file itself is missing (all three mean "no credentials
    /// here", never an error worth surfacing).
    func value(inDatabase path: String, table: String, key: String) -> String?
}

/// `SQLiteReading` via the `sqlite3` binary that ships with macOS.
///
/// Shelling out rather than linking SQLite is deliberate: Mana needs four
/// string reads out of a database another app owns and writes to constantly.
/// The URI opens the file **read-only** (`mode=ro`) so a running Cursor can
/// never see a writer, and the query runs with a short `busy_timeout` instead
/// of blocking a poll behind Cursor's own transaction.
struct SQLiteCLIStore: SQLiteReading {
    /// Read budget for one query. A poll must not stall behind a busy
    /// database; a miss simply reads as "no credentials this time".
    static let timeout: TimeInterval = 3

    private let executable: String

    init(executable: String = "/usr/bin/sqlite3") {
        self.executable = executable
    }

    func value(inDatabase path: String, table: String, key: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }

        // `sqlite3` treats extra arguments as further statements rather than
        // as bound parameters, so the key goes in as an escaped literal. Both
        // the table and the key are Mana's own constants; the escaping is
        // belt-and-braces in case that ever stops being true.
        let sql = "SELECT value FROM \(Self.quotedIdentifier(table)) "
            + "WHERE key = \(Self.quotedLiteral(key)) LIMIT 1;"

        guard let output = run(arguments: [
            "-readonly",
            "-noheader",
            // Wait briefly rather than failing the moment Cursor holds a lock.
            "-cmd", ".timeout 1000",
            "file:\(expanded)?mode=ro",
            sql,
        ]) else {
            return nil
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func run(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a full pipe buffer would deadlock `waitUntilExit`.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(Self.timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        return String(data: data, encoding: .utf8)
    }

    /// Table names come from Mana's own source, never from user input — quoted
    /// anyway so this stays safe if that ever changes.
    private static func quotedIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func quotedLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
