import Foundation

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
