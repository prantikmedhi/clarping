import Foundation
import Security

enum Shell {
    struct Result {
        let status: Int32
        let out: Data
        let err: String
    }

    /// Runs a tool. Callers must never put secret material in `args`.
    @discardableResult
    static func run(_ path: String, _ args: [String]) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: out, err: String(decoding: err, as: UTF8.self))
    }
}

struct KeychainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Generic-password access. Secrets only ever move through Security.framework
/// calls in-process or over a pipe from `security find-generic-password -w`;
/// never on argv or in the environment.
///
/// Why two read paths: items created by the `security` tool (which is what
/// Claude Code uses) are readable by that tool without a prompt, while items
/// created by Clarping through SecItemAdd are readable by Clarping without a
/// prompt. Each side reads the items it can read silently.
enum Keychain {
    private static let securityTool = "/usr/bin/security"

    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// `viaTool`: read with `security find-generic-password -w` (for the Claude
    /// Code item). Otherwise SecItemCopyMatching (Clarping's own items).
    static func read(service: String, account: String, viaTool: Bool = false) throws -> Data? {
        if viaTool {
            let r = try Shell.run(securityTool, ["find-generic-password", "-a", account, "-s", service, "-w"])
            if r.status == 44 { return nil }
            guard r.status == 0 else { throw KeychainError(message: "keychain read failed (\(r.status))") }
            var out = r.out
            if out.last == 0x0A { out.removeLast() }
            // `-w` prints non-printable payloads as hex; undo that when it happens.
            if let s = String(data: out, encoding: .utf8), !s.hasPrefix("{"), let hex = Data(hexString: s) { return hex }
            return out
        }
        var q = query(service, account)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(message: describe(status, "read")) }
        return result as? Data
    }

    /// Updates the existing item's data in place (keeping its ACL and partition
    /// list, so the `security` tool and Claude Code keep silent access), or
    /// creates it when absent with the default ACL (Clarping only). The Claude
    /// Code item is never created here: an item Clarping creates would prompt
    /// when the `security` tool reads it (verified on macOS 27), so the
    /// switcher refuses when that item is missing and asks for `claude /login`.
    static func write(service: String, account: String, data: Data) throws {
        let q = query(service, account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(message: describe(status, "write")) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = service
        let a = SecItemAdd(add as CFDictionary, nil)
        guard a == errSecSuccess else { throw KeychainError(message: describe(a, "create")) }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service, account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        // Items created by another build of Clarping refuse SecItemDelete (-25244);
        // the security tool can still delete them, and nothing secret goes on argv.
        let r = try Shell.run(securityTool, ["delete-generic-password", "-a", account, "-s", service])
        guard r.status == 0 || r.status == 44 else { throw KeychainError(message: "keychain delete failed (\(r.status))") }
    }

    private static func describe(_ status: OSStatus, _ op: String) -> String {
        if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed {
            return "keychain \(op) was not allowed; choose Always Allow when macOS asks about Clarping"
        }
        let s = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return "keychain \(op) failed (\(status)) \(s)"
    }
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }

    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = Data.nibble(chars[i]), let lo = Data.nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo); i += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}
