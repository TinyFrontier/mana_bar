import Foundation

/// Per-request time budgets, in one place because getting them wrong is what
/// produced the "No connection on first launch" bug.
///
/// The usage GETs used to allow 10 s. That is plenty for a *warm* process —
/// every poll after the first reuses an open connection and finishes in
/// 300–1200 ms — but the very first fetch after launch always pays for a cold
/// DNS lookup + TCP connect + TLS handshake, and on a degraded link that alone
/// can exceed 10 s. Measured on the reporter's machine (unified log, 2026-08-29
/// 17:18–17:19): both providers failed with `NSURLErrorTimedOut` at exactly
/// 10 004 / 10 007 ms having sent 0 request bytes, while the very next attempt
/// on the same launch *succeeded* in 12 950 ms — of which 8 825 ms was TCP
/// connect and 3 253 ms was the TLS handshake. A 10 s budget guillotined a
/// request that was working; 20 s covers it with margin.
///
/// A genuinely offline machine does not wait this out: `URLSession` fails such
/// a request with `.notConnectedToInternet` in milliseconds, and the config
/// deliberately leaves `waitsForConnectivity` at its `false` default.
enum ProviderTimeouts {
    /// Usage GET — the call that decides whether a ring shows a number.
    static let usageRequest: TimeInterval = 20
    /// OAuth token refresh. Kept as it was: it only ever runs after a usage
    /// call has already proved the connection is usable.
    static let tokenRefresh: TimeInterval = 15
}

/// One outgoing request. Header values may carry bearer tokens, so a
/// `HTTPRequest` must never be logged or described in full (research doc §9.2
/// п.9).
struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 15
}

/// One response. `body` of a *successful* usage call is account data and is
/// likewise never logged.
struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        // Normalize to lower-case keys so lookups are case-insensitive.
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        self.body = body
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Seam that lets the provider tests drive the whole fetch/refresh/retry flow
/// without touching the network.
protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// `URLSession`-backed client. Deliberately silent: nothing about the request,
/// its headers, or the response body is logged anywhere, in any build
/// configuration, and no telemetry of any kind is emitted (ТЗ §8).
struct URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // Credentials belong to the CLI tools; never let URLSession persist
        // cookies or credentials of its own on the user's disk.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.connectionFailed
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key] = value
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
