import Foundation

enum Shell {
    struct Result {
        let status: Int32
        let out: Data
        let err: String
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], stdin: Data? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        var inPipe: Pipe?
        if stdin != nil { inPipe = Pipe(); p.standardInput = inPipe }
        try p.run()
        if let stdin, let inPipe {
            inPipe.fileHandleForWriting.write(stdin)
            inPipe.fileHandleForWriting.closeFile()
        }
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

/// Generic-password access through /usr/bin/security. Claude Code creates its
/// item with the same tool, so reads and updates never trigger ACL prompts
/// (Security.framework calls from an ad-hoc signed binary would). The payload
/// is passed hex-encoded via `-X`; `security -i` caps a line at about 4 KB,
/// which the real item exceeds.
enum Keychain {
    private static let security = "/usr/bin/security"

    static func read(service: String, account: String) throws -> Data? {
        let r = try Shell.run(security, ["find-generic-password", "-a", account, "-s", service, "-w"])
        if r.status == 44 { return nil }
        guard r.status == 0 else { throw KeychainError(message: "keychain read failed (\(r.status))") }
        var out = r.out
        if out.last == 0x0A { out.removeLast() }
        // `-w` prints non-printable payloads as hex; undo that when it happens.
        if let s = String(data: out, encoding: .utf8), !s.hasPrefix("{"), let hex = Data(hexString: s) { return hex }
        return out
    }

    static func write(service: String, account: String, data: Data) throws {
        let r = try Shell.run(security, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", data.hexString])
        guard r.status == 0 else { throw KeychainError(message: "keychain write failed (\(r.status))") }
    }

    static func delete(service: String, account: String) throws {
        let r = try Shell.run(security, ["delete-generic-password", "-a", account, "-s", service])
        guard r.status == 0 || r.status == 44 else { throw KeychainError(message: "keychain delete failed (\(r.status))") }
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
