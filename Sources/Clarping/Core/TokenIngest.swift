import Foundation

struct TokenBucket: Codable, Equatable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0

    static func + (a: TokenBucket, b: TokenBucket) -> TokenBucket {
        TokenBucket(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }
    var total: Int { input + output + cacheRead + cacheWrite }
}

struct FileCursor: Codable, Equatable {
    var offset: Int
    var size: Int
}

/// Daily buckets keyed "yyyy-MM-dd|accountId|family". Unattributed tokens use
/// accountId "unattributed".
struct TokenStats: Codable, Equatable {
    var cursors: [String: FileCursor] = [:]
    var buckets: [String: TokenBucket] = [:]
    var seen: [String] = []
    var lastIngest: Date?

    static let unattributed = "unattributed"

    static func key(day: String, account: String, family: String) -> String { "\(day)|\(account)|\(family)" }
    static func split(_ key: String) -> (day: String, account: String, family: String) {
        let p = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        return (p[0], p.count > 1 ? p[1] : "", p.count > 2 ? p[2] : "")
    }

    func sum(days: Set<String>, account: String? = nil) -> [String: TokenBucket] {
        var byFamily: [String: TokenBucket] = [:]
        for (k, b) in buckets {
            let s = TokenStats.split(k)
            guard days.contains(s.day), account == nil || s.account == account else { continue }
            byFamily[s.family, default: TokenBucket()] = byFamily[s.family, default: TokenBucket()] + b
        }
        return byFamily
    }

    func sumByAccount(days: Set<String>) -> [String: TokenBucket] {
        var out: [String: TokenBucket] = [:]
        for (k, b) in buckets {
            let s = TokenStats.split(k)
            guard days.contains(s.day) else { continue }
            out[s.account, default: TokenBucket()] = out[s.account, default: TokenBucket()] + b
        }
        return out
    }

    func perDay(days: [String]) -> [(day: String, family: String, bucket: TokenBucket)] {
        var out: [String: TokenBucket] = [:]
        let set = Set(days)
        for (k, b) in buckets {
            let s = TokenStats.split(k)
            guard set.contains(s.day) else { continue }
            out["\(s.day)|\(s.family)", default: TokenBucket()] = out["\(s.day)|\(s.family)", default: TokenBucket()] + b
        }
        return out.map { k, b in
            let p = k.split(separator: "|").map(String.init)
            return (p[0], p[1], b)
        }.sorted { $0.day < $1.day }
    }
}

/// Approximate API-equivalent pricing in USD per million tokens. These are the
/// public list prices for the 4.x generation; Fable uses the Opus figures as a
/// placeholder. Cache read is billed at 10% of input, cache write at 125%.
enum Pricing {
    static let perMTok: [String: (input: Double, output: Double)] = [
        "Opus": (15, 75), "Sonnet": (3, 15), "Haiku": (1, 5), "Fable": (15, 75), "Other": (3, 15),
    ]
    static func cost(family: String, _ b: TokenBucket) -> Double {
        let p = perMTok[family] ?? perMTok["Other"]!
        return (Double(b.input) * p.input + Double(b.output) * p.output
                + Double(b.cacheRead) * p.input * 0.10 + Double(b.cacheWrite) * p.input * 1.25) / 1_000_000
    }
    static func family(of model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus") { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        if m.contains("fable") { return "Fable" }
        return "Other"
    }
    static let families = ["Opus", "Sonnet", "Fable", "Haiku", "Other"]
}

enum DayKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func of(_ d: Date) -> String { formatter.string(from: d) }
    static func days(from: Date, to: Date) -> [String] {
        var out: [String] = []
        var d = Calendar.current.startOfDay(for: from)
        let end = Calendar.current.startOfDay(for: to)
        while d <= end {
            out.append(of(d))
            d = Calendar.current.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }
}

/// Incrementally reads Claude Code session logs (~/.claude/projects/**/*.jsonl)
/// and folds assistant usage into daily buckets. Only files modified inside the
/// reporting window are considered; byte cursors make re-runs cheap.
enum TokenIngest {
    static let windowDays = 62
    private static let usageMarker = Data("\"usage\"".utf8)

    static func ingest(stats: inout TokenStats, projects: URL, attribute: (Date) -> String) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: projects, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86400)
        var seen = Set(stats.seen)
        var touched = false
        while let url = e.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  rv.isRegularFile == true, let size = rv.fileSize, let mod = rv.contentModificationDate, mod >= cutoff else { continue }
            let key = url.path
            var cursor = stats.cursors[key] ?? FileCursor(offset: 0, size: 0)
            if size < cursor.offset { cursor = FileCursor(offset: 0, size: 0) }
            guard size > cursor.offset, let fh = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: UInt64(cursor.offset))
            guard let data = try? fh.readToEnd() else { continue }
            var consumed = 0
            var start = data.startIndex
            while let nl = data[start...].firstIndex(of: 0x0A) {
                let line = data[start..<nl]
                consumed = nl - data.startIndex + 1
                start = nl + 1
                if line.range(of: usageMarker) != nil { fold(line: line, into: &stats, seen: &seen, attribute: attribute) }
            }
            stats.cursors[key] = FileCursor(offset: cursor.offset + consumed, size: size)
            touched = true
        }
        if touched {
            if seen.count > 400_000 { seen.removeAll() }
            stats.seen = Array(seen)
            stats.lastIngest = Date()
        }
    }

    private static func fold(line: Data, into stats: inout TokenStats, seen: inout Set<String>, attribute: (Date) -> String) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              o["type"] as? String == "assistant",
              let msg = o["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return }
        let id = (msg["id"] as? String ?? "") + ":" + (o["requestId"] as? String ?? "")
        if id != ":" {
            if seen.contains(id) { return }
            seen.insert(id)
        }
        guard let ts = (o["timestamp"] as? String).flatMap(Format.parseISO) else { return }
        let b = TokenBucket(input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0)
        guard b.total > 0 else { return }
        let key = TokenStats.key(day: DayKey.of(ts), account: attribute(ts), family: Pricing.family(of: msg["model"] as? String ?? ""))
        stats.buckets[key, default: TokenBucket()] = stats.buckets[key, default: TokenBucket()] + b
    }

    /// Account active at `date` according to the switch log. With no switches at
    /// all, everything belongs to the single current account (if any).
    static func attributor(log: [SwitchLogEntry], activeId: String?) -> (Date) -> String {
        let entries = log.filter(\.ok).sorted { $0.at < $1.at }
        if entries.isEmpty { return { _ in activeId ?? TokenStats.unattributed } }
        return { date in
            var current: String? = nil
            for e in entries {
                if e.at <= date { current = e.toId } else { break }
            }
            return current ?? TokenStats.unattributed
        }
    }
}
