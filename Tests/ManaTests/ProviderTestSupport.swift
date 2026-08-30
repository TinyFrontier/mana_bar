import Foundation
import XCTest
@testable import Mana

// MARK: - HTTP

/// Scripted `HTTPClient`: hands back queued responses in order and records the
/// requests it was given, so a whole fetch → 401 → refresh → retry sequence can
/// be asserted without a network.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<HTTPResponse, Error>]
    private(set) var requests: [HTTPRequest] = []
    /// Runs after each request is recorded, with its 0-based index — the seam
    /// for simulating something changing on disk mid-fetch (e.g. the CLI
    /// rotating its token between our attempt and our retry).
    var afterRequest: ((Int) -> Void)?

    init(_ responses: [Result<HTTPResponse, Error>]) {
        queued = responses
    }

    convenience init(_ responses: HTTPResponse...) {
        self.init(responses.map { .success($0) })
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let next = record(request) else {
            XCTFail("StubHTTPClient ran out of scripted responses for \(request.url)")
            throw UsageError.connectionFailed
        }
        return try next.get()
    }

    /// Kept synchronous so the lock is never taken from an async context.
    private func record(_ request: HTTPRequest) -> Result<HTTPResponse, Error>? {
        lock.lock()
        requests.append(request)
        let index = requests.count - 1
        let next = queued.isEmpty ? nil : queued.removeFirst()
        let hook = afterRequest
        lock.unlock()

        hook?(index)
        return next
    }

    var sentRequests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

extension HTTPResponse {
    static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data(text.utf8))
    }

    static func status(_ status: Int, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data())
    }
}

// MARK: - Keychain

/// In-memory `KeychainReading`. Every provider test injects one so the suite can
/// never read or write the developer's real Keychain.
final class StubKeychain: KeychainReading, @unchecked Sendable {
    /// One data read this stub was asked to serve.
    struct DataRead: Equatable {
        var service: String
        var account: String?
        var allowInteraction: Bool
    }

    private let lock = NSLock()
    private var items: [String: String]
    private var reads: [DataRead] = []
    /// When set, reads throw it instead of returning a value.
    var readError: KeychainError?
    /// When set, only reads that **forbid** interaction throw it — the shape of
    /// a Keychain item that exists but whose ACL this app has not been granted:
    /// the existence probe still answers, an interactive read still works, and
    /// the silent read fails fast.
    var silentReadError: KeychainError?
    /// When true, writes throw `.accessDenied`.
    var refusesWrites = false
    /// When true, the attributes-only probe answers `nil` — "could not tell",
    /// the shape it takes when the silent gate is held by an open interactive
    /// dialog or `securityd` refuses the attributes query outright.
    var existenceProbeIsInconclusive = false

    init(items: [String: String] = [:]) {
        self.items = items
    }

    private static func key(_ service: String, _ account: String?) -> String {
        "\(service)\u{1}\(account ?? "")"
    }

    func readGenericPassword(
        service: String,
        account: String?,
        allowInteraction: Bool
    ) throws -> String? {
        lock.lock()
        reads.append(DataRead(service: service, account: account, allowInteraction: allowInteraction))
        lock.unlock()

        if let readError { throw readError }
        if !allowInteraction, let silentReadError { throw silentReadError }
        lock.lock()
        defer { lock.unlock() }
        return items[Self.key(service, account)] ?? items[Self.key(service, nil)]
    }

    func genericPasswordExists(service: String, account: String?) -> Bool? {
        if existenceProbeIsInconclusive { return nil }
        lock.lock()
        defer { lock.unlock() }
        return items[Self.key(service, account)] != nil || items[Self.key(service, nil)] != nil
    }

    /// Every data read served so far, in order. Lets a test assert that the
    /// launch-path existence probe never asked for the secret.
    var dataReads: [DataRead] {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func writeGenericPassword(service: String, account: String?, value: String) throws {
        if refusesWrites { throw KeychainError.accessDenied }
        lock.lock()
        items[Self.key(service, account)] = value
        lock.unlock()
    }

    func value(service: String, account: String? = nil) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[Self.key(service, account)] ?? items[Self.key(service, nil)]
    }
}

// MARK: - SQLite

/// In-memory `SQLiteReading`, so no test ever reads the developer's real
/// Cursor state database.
final class StubSQLite: SQLiteReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    /// When true, every read answers `nil` — a locked or missing database.
    var isUnavailable = false

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func value(inDatabase path: String, table: String, key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return isUnavailable ? nil : values[key]
    }
}

// MARK: - Files

/// Per-test temporary directory. Auth-file decoding is exercised against real
/// files here — never against the developer's `~/.claude` or `~/.codex`.
struct TemporaryDirectory {
    let url: URL

    init(_ testCase: XCTestCase) {
        let name = "mana-tests-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        url = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    var path: String { url.path }

    @discardableResult
    func write(_ contents: String, to name: String) -> String {
        let destination = url.appendingPathComponent(name)
        try? contents.write(to: destination, atomically: true, encoding: .utf8)
        return destination.path
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
    }
}

// MARK: - Assertions

func XCTAssertUsageError(
    _ expression: @autoclosure () throws -> Any,
    _ expected: UsageError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
        XCTFail("expected \(expected) but no error was thrown", file: file, line: line)
    } catch let error as UsageError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected) but got \(error)", file: file, line: line)
    }
}

func XCTAssertUsageErrorAsync(
    _ expression: @autoclosure () async throws -> Any,
    _ expected: UsageError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected) but no error was thrown", file: file, line: line)
    } catch let error as UsageError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected) but got \(error)", file: file, line: line)
    }
}

extension ServiceUsage {
    func window(_ kind: UsageWindow.Kind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }
}
