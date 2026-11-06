import Foundation

/// Serial off-main executor for everything that can block: process spawns
/// (`security`, `pgrep`, `osascript`), Keychain calls (which may wait on an
/// authorization prompt), JSON file reads and writes (fsync), log ingest.
///
/// The main actor only ever `await`s these; it never runs them inline. Being
/// an actor, calls are serialized, so two writes of the same vault file can
/// never land out of order.
actor IOWorker {
    func run<T>(_ body: () throws -> T) rethrows -> T { try body() }
}
