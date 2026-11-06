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

    var emailDomain: String { email.split(separator: "@").last.map(String.init) ?? "" }
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

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pollMinutes = try c.decodeIfPresent(Int.self, forKey: .pollMinutes) ?? 3
        menuBarText = try c.decodeIfPresent(Bool.self, forKey: .menuBarText) ?? true
        notifyThresholds = try c.decodeIfPresent(Bool.self, forKey: .notifyThresholds) ?? true
        suggestNext = try c.decodeIfPresent(Bool.self, forKey: .suggestNext) ?? true
        switchDesktop = try c.decodeIfPresent(Bool.self, forKey: .switchDesktop) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
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
    static func money(_ v: Double) -> String { v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let isoPlain = ISO8601DateFormatter()
    static func parseISO(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }
}
