import Foundation

/// The `claudeAiOauth` block of the Claude Code keychain item, kept raw so
/// unknown keys round-trip. Lives only in the keychain, never in a JSON file.
struct CLICreds {
    var raw: [String: Any]

    init(raw: [String: Any]) { self.raw = raw }
    init?(data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        raw = o
    }
    var data: Data { (try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])) ?? Data() }

    var accessToken: String? { raw["accessToken"] as? String }
    var refreshToken: String? { raw["refreshToken"] as? String }
    var expiresAt: Date? { (raw["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
    var scopes: [String] { raw["scopes"] as? [String] ?? [] }
    var subscriptionType: String? { raw["subscriptionType"] as? String }
    var rateLimitTier: String? { raw["rateLimitTier"] as? String }
}

struct Account: Codable, Identifiable, Equatable {
    var id: String            // accountUuid
    var label: String
    var colorHex: String
    var email: String
    var orgName: String
    var createdAt: Date
    var lastCaptured: Date
    var oauthAccount: [String: JSONValue]
    var hasDesktopSnapshot: Bool
    var needsRelogin: Bool
    /// Plan fields copied from the CLI keychain item at capture time (no secrets).
    var subscriptionType: String? = nil
    var rateLimitTier: String? = nil

    var emailDomain: String { email.split(separator: "@").last.map(String.init) ?? "" }

    /// "Max 5x", "Pro", "Team"... derived from the rate-limit tier, the
    /// subscription type or the organization type; nil when none is known.
    var planName: String? {
        Plan.name(tier: rateLimitTier ?? oauthAccount["userRateLimitTier"]?.stringValue,
                  subscriptionType: subscriptionType,
                  orgType: oauthAccount["organizationType"]?.stringValue)
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
}

/// Maps the raw plan identifiers Claude's login carries to short, friendly
/// names. Known shapes: `default_claude_max_5x`, `default_claude_max_20x`,
/// `default_claude_pro`, subscription types `max` / `pro` / `team` /
/// `enterprise`, organization types `claude_team` / `claude_enterprise`.
/// Anything else is tidied (`default_raven` -> "Raven") rather than hidden.
enum Plan {
    static func name(tier: String?, subscriptionType: String?, orgType: String?) -> String? {
        if let t = tier?.lowercased(), !t.isEmpty {
            if t.contains("max") {
                if let r = t.range(of: #"(\d+)x"#, options: .regularExpression) { return "Max \(t[r])" }
                return "Max"
            }
            if t.contains("enterprise") { return "Enterprise" }
            if t.contains("team") { return "Team" }
            if t.contains("pro") { return "Pro" }
            if t.contains("free") { return "Free" }
        }
        if let s = subscriptionType?.lowercased(), !s.isEmpty {
            switch s {
            case "max": return "Max"
            case "pro": return "Pro"
            case "team": return "Team"
            case "enterprise": return "Enterprise"
            case "free": return "Free"
            default: return tidy(s)
            }
        }
        if let o = orgType?.lowercased(), !o.isEmpty {
            if o.contains("enterprise") { return "Enterprise" }
            if o.contains("team") { return "Team" }
            if o.contains("max") { return "Max" }
            if o.contains("pro") { return "Pro" }
        }
        if let t = tier, !t.isEmpty { return tidy(t) }
        return nil
    }

    /// `default_claude_foo_bar` -> "Foo Bar".
    static func tidy(_ raw: String) -> String {
        var parts = raw.lowercased().split(separator: "_").map(String.init)
        while let f = parts.first, f == "default" || f == "claude" { parts.removeFirst() }
        if parts.isEmpty { return raw }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct ModelLimit: Codable, Equatable {
    var name: String
    var percent: Double
    var resetsAt: Date?
}

struct UsageSnapshot: Codable, Equatable {
    var accountId: String
    var at: Date
    var fiveHour: Double?
    var fiveHourResetsAt: Date?
    var sevenDay: Double?
    var sevenDayResetsAt: Date?
    var models: [ModelLimit]
}

struct SwitchLogEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var at: Date
    var fromId: String?
    var toId: String
    var ok: Bool
    var note: String?
}

struct Settings: Codable, Equatable {
    var pollMinutes: Int = 3
    var menuBarText: Bool = true
    var notifyThresholds: Bool = true
    var suggestNext: Bool = true
    var switchDesktop: Bool = true
    var launchAtLogin: Bool = false
    /// Set once the first-run setup guide was finished or dismissed.
    var onboardingDone: Bool = false

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollMinutes = try c.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 3
        menuBarText = try c.decodeIfPresent(Bool.self, forKey: .menuBarText) ?? true
        notifyThresholds = try c.decodeIfPresent(Bool.self, forKey: .notifyThresholds) ?? true
        suggestNext = try c.decodeIfPresent(Bool.self, forKey: .suggestNext) ?? true
        switchDesktop = try c.decodeIfPresent(Bool.self, forKey: .switchDesktop) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? false
    }
}

enum AccountColors {
    static let palette: [(name: String, hex: String)] = [
        ("Clay", "D97757"), ("Sage", "6F8F7A"), ("Slate", "5C7A99"),
        ("Amber", "C99A3B"), ("Plum", "8A6A8F"), ("Ink", "4A4440"),
    ]
    static func next(after used: [String]) -> String {
        palette.first { !used.contains($0.hex) }?.hex ?? palette[used.count % palette.count].hex
    }
}

enum Format {
    static func duration(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: d)
    }
    static func dayClock(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return clock(d) }
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
        return f.string(from: d)
    }
    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.2fB", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1e3)
        default: return "\(n)"
        }
    }
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let isoPlain = ISO8601DateFormatter()
    static func parseISO(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
}
