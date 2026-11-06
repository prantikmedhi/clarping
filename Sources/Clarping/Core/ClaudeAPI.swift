import Foundation

enum APIError: LocalizedError {
    case reloginNeeded
    /// The stored refresh token was rejected: it was rotated or revoked elsewhere
    /// (typically a `claude` session of that account refreshed it). The account
    /// must be made active with `claude /login` and re-captured.
    case recaptureNeeded
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .reloginNeeded: return "Re-login needed"
        case .recaptureNeeded: return "Stored login was rotated elsewhere; re-capture it"
        case .http(let c): return "HTTP \(c)"
        case .malformed: return "Unexpected response"
        }
    }
}

struct Profile {
    var accountId: String
    var email: String
    var displayName: String
    var orgName: String
}

enum ClaudeAPI {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    private static func request(_ url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("claude-cli/2.1.316 (external, cli)", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 20
        return r
    }

    private static func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.reloginNeeded }
        guard (200..<300).contains(code) else { throw APIError.http(code) }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.malformed }
        return o
    }

    /// Rotates the refresh token; the caller must persist the returned creds.
    static func refresh(_ creds: CLICreds) async throws -> CLICreds {
        guard let rt = creds.refreshToken else { throw APIError.reloginNeeded }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID, "scope": creds.scopes.joined(separator: " ")]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 400 || code == 401 { throw APIError.recaptureNeeded }
        guard (200..<300).contains(code) else { throw APIError.http(code) }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let at = o["access_token"] as? String else { throw APIError.malformed }
        var raw = creds.raw
        let now = Date().timeIntervalSince1970 * 1000
        raw["accessToken"] = at
        if let nrt = o["refresh_token"] as? String { raw["refreshToken"] = nrt }
        if let e = o["expires_in"] as? Double { raw["expiresAt"] = (now + e * 1000).rounded() }
        if let re = o["refresh_token_expires_in"] as? Double { raw["refreshTokenExpiresAt"] = (now + re * 1000).rounded() }
        if let s = o["scope"] as? String, !s.isEmpty { raw["scopes"] = s.split(separator: " ").map(String.init) }
        return CLICreds(raw: raw)
    }

    static func usage(token: String, accountId: String) async throws -> UsageSnapshot {
        let o = try await json(request(usageURL, token: token))
        func window(_ key: String) -> (Double?, Date?) {
            guard let w = o[key] as? [String: Any] else { return (nil, nil) }
            let u = (w["utilization"] as? Double)
            let r = (w["resets_at"] as? String).flatMap(Format.parseISO)
            return (u, r)
        }
        let five = window("five_hour"), seven = window("seven_day")
        var models: [ModelLimit] = []
        for l in o["limits"] as? [[String: Any]] ?? [] {
            guard l["kind"] as? String == "weekly_scoped",
                  let scope = l["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = (model["display_name"] as? String) ?? (model["id"] as? String) else { continue }
            let pct = (l["percent"] as? Double) ?? (l["utilization"] as? Double) ?? 0
            models.append(ModelLimit(name: name, percent: pct, resetsAt: (l["resets_at"] as? String).flatMap(Format.parseISO)))
        }
        return UsageSnapshot(accountId: accountId, at: Date(), fiveHour: five.0, fiveHourResetsAt: five.1,
                             sevenDay: seven.0, sevenDayResetsAt: seven.1, models: models)
    }

    static func profile(token: String) async throws -> Profile {
        let o = try await json(request(profileURL, token: token))
        let a = o["account"] as? [String: Any] ?? [:]
        let org = o["organization"] as? [String: Any] ?? [:]
        return Profile(accountId: a["uuid"] as? String ?? "", email: a["email"] as? String ?? "", displayName: a["display_name"] as? String ?? a["full_name"] as? String ?? "", orgName: org["name"] as? String ?? "")
    }
}
