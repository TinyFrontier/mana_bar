import Foundation

struct CursorRefreshedToken: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
}

/// HTTP for Cursor's dashboard endpoints. Nothing here logs a token, a header
/// set, or a response body.
///
/// The usage call is a Connect-RPC POST with an empty body — the shape Cursor's
/// own dashboard uses — rather than a REST GET, because that is the endpoint
/// that answers for a plain Bearer token.
struct CursorUsageClient: Sendable {
    static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    /// Cursor's public OAuth client id, as used by the app itself.
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    var http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "POST",
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ],
            body: Data("{}".utf8),
            timeout: ProviderTimeouts.usageRequest
        ))
    }

    /// JSON-encoded refresh. As on the Codex side, a 400/401 is a dead session
    /// while anything else is far more often a proxy or WAF page than an
    /// expired token, so it surfaces as `.requestFailed`.
    func refresh(refreshToken: String) async throws -> CursorRefreshedToken {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken,
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)

        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: encoded,
            timeout: ProviderTimeouts.tokenRefresh
        ))

        if response.statusCode == 400 || response.statusCode == 401 {
            throw UsageError.sessionExpired
        }
        guard response.isSuccess else {
            throw UsageError.requestFailed(statusCode: response.statusCode)
        }
        guard let json = ProviderParse.jsonObject(response.body),
              let accessToken = (json["access_token"] as? String)?.nilIfBlank
        else {
            throw UsageError.sessionExpired
        }
        return CursorRefreshedToken(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String)?.nilIfBlank
        )
    }
}
