import Foundation

/// HTTP for the ChatGPT/Codex usage endpoint (ТЗ §4.1, research doc §5.2).
/// Nothing here logs a token, a header set, or a response body.
struct CodexUsageClient: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    /// The Codex CLI's public OAuth client id.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    var http: HTTPClient

    init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsage(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Accept": "application/json",
        ]
        if let accountID = accountID?.nilIfBlank {
            headers["ChatGPT-Account-Id"] = accountID
        }
        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: headers,
            timeout: 10
        ))
    }

    /// Form-encoded refresh. A 400/401 carrying a recognized OAuth error code
    /// is a dead session; an unrecognized one is far more often a proxy/WAF page
    /// than an expired token, so it surfaces as `.requestFailed` rather than
    /// telling the user to re-login (research doc §5.4).
    func refresh(refreshToken: String) async throws -> CodexRefreshedToken {
        let body = "grant_type=refresh_token"
            + "&client_id=\(Self.clientID.urlFormEncoded)"
            + "&refresh_token=\(refreshToken.urlFormEncoded)"

        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
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
            throw UsageError.sessionExpired
        }
        return CodexRefreshedToken(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String)?.nilIfBlank,
            idToken: (json["id_token"] as? String)?.nilIfBlank
        )
    }

    static func refreshFailure(_ response: HTTPResponse) -> UsageError {
        let json = ProviderParse.jsonObject(response.body)
        let code: String? = {
            if let error = json?["error"] as? [String: Any] {
                return error["code"] as? String ?? error["error"] as? String
            }
            return json?["error"] as? String ?? json?["code"] as? String
        }()

        switch code {
        // All three mean the same thing for Mana: re-login in the CLI.
        case "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated":
            return .sessionExpired
        default:
            return .requestFailed(statusCode: response.statusCode)
        }
    }
}

struct CodexRefreshedToken: Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}
