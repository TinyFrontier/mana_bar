import Foundation

/// The two HTTP calls the Claude provider makes (ТЗ §4.1, research doc §4.2).
/// Nothing here logs a token, a header set, or a response body.
struct ClaudeUsageClient: Sendable {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let refreshScopes =
        "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    var http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
            ],
            timeout: 10
        ))
    }

    /// Exchanges a refresh token for a fresh access token.
    ///
    /// A 400/401 carrying `invalid_grant` means the login is dead
    /// (`.sessionExpired`); a 400/401 without a recognized OAuth error code is
    /// far more often a proxy/WAF page than an expired token, so it surfaces as
    /// `.requestFailed` instead of telling the user to re-login.
    func refresh(refreshToken: String) async throws -> ClaudeRefreshedToken {
        let payload: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.refreshScopes,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: body,
            timeout: 15
        ))

        if response.statusCode == 400 || response.statusCode == 401 {
            throw Self.refreshFailure(response)
        }
        guard response.isSuccess else {
            throw UsageError.requestFailed(statusCode: response.statusCode)
        }
        guard let json = ProviderParse.jsonObject(response.body),
              let accessToken = (json["access_token"] as? String)?.nilIfBlank
        else {
            // A 2xx with no usable token is a dead session in practice.
            throw UsageError.sessionExpired
        }
        return ClaudeRefreshedToken(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String)?.nilIfBlank,
            expiresIn: ProviderParse.number(json["expires_in"])
        )
    }

    static func refreshFailure(_ response: HTTPResponse) -> UsageError {
        let json = ProviderParse.jsonObject(response.body)
        let code = (json?["error"] as? String) ?? (json?["error_description"] as? String)
        if code == "invalid_grant" { return .sessionExpired }
        return .requestFailed(statusCode: response.statusCode)
    }
}

struct ClaudeRefreshedToken: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    /// Lifetime in seconds, as returned by the token endpoint.
    var expiresIn: Double?
}
