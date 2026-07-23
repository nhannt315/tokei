import Foundation
import Security

/// Reads the Claude Code OAuth access token from the macOS Keychain.
/// Read-only; the token is never logged or written anywhere.
///
/// Reads via the `/usr/bin/security` CLI rather than `SecItemCopyMatching`.
/// The Keychain "Always Allow" grant binds to the *process* that asked. Claude
/// Code rewrites the "Claude Code-credentials" item whenever it refreshes its
/// token, which can reset the item's ACL; a grant bound to Tokei's own (and
/// occasionally changing) signature then breaks and re-prompts. Binding the
/// grant to the stable, Apple-signed `security` binary survives those rewrites
/// far better. It does not eliminate prompts — the item is owned by another
/// app — so a hung prompt is bounded by a hard timeout and treated as denied.
public struct KeychainCredentialReader {
    public enum ReadResult {
        case token(String)
        case notFound          // no Keychain entry → not signed in
        case denied            // user denied the prompt, or it timed out
        case failure(OSStatus)
    }

    public let service: String

    /// How long to wait on `security` before assuming a stuck prompt. A read
    /// runs on the UsageEngine actor, so an unbounded wait would wedge polling.
    private let timeout: TimeInterval

    public init(service: String = "Claude Code-credentials", timeout: TimeInterval = 10) {
        self.service = service
        self.timeout = timeout
    }

    public func readAccessToken() -> ReadResult {
        switch runSecurityTool() {
        case .output(let data):
            // Item exists; the stored blob is JSON. A malformed/unexpected
            // shape is treated as "not signed in", matching prior behavior.
            return Self.parseToken(from: data).map(ReadResult.token) ?? .notFound
        case .exit(let status):
            return Self.classify(exitCode: status)
        case .timedOut:
            return .denied
        }
    }

    private enum ToolOutcome {
        case output(Data)      // exit 0, stdout captured
        case exit(Int32)       // non-zero exit code
        case timedOut          // killed after `timeout`
    }

    /// Mutable reference so the stdout-drain closure writes without capturing a
    /// `var` (Swift 6 concurrency); the `readDone` semaphore orders the read.
    private final class DataBox: @unchecked Sendable { var data = Data() }

    /// Runs `security find-generic-password -s <service> -w` with a hard
    /// timeout, killing the process if a Keychain prompt keeps it blocked.
    /// stdout is drained on a separate queue so a full pipe cannot deadlock
    /// the child. Mirrors the subprocess shape of `UpdateInstaller.run`, with
    /// the timeout that helper lacks.
    private func runSecurityTool() -> ToolOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Reference box so the drain closure has no captured-var mutation
        // (Swift 6 Sendable); the semaphore establishes the happens-before.
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = stdout.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        do {
            try process.run()
        } catch {
            return .exit(OSStatus(errSecIO))   // could not launch → generic I/O failure
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return .timedOut
        }
        // Child has exited, so EOF is imminent; bound the wait anyway.
        _ = readDone.wait(timeout: .now() + 2)
        return process.terminationStatus == 0 ? .output(box.data) : .exit(process.terminationStatus)
    }

    /// Maps a non-zero `security` exit code to a result. `security` exits with
    /// the low byte of the underlying `OSStatus` (e.g. errSecItemNotFound
    /// -25300 & 0xFF = 44 — verified against the live tool), so we match on
    /// those bytes and reconstruct the OSStatus for the failure case.
    public static func classify(exitCode: Int32) -> ReadResult {
        switch exitCode {
        case errSecItemNotFound & 0xFF:                                  // 44
            return .notFound
        case errSecAuthFailed & 0xFF, errSecUserCanceled & 0xFF:         // 51, 128
            return .denied
        default:
            return .failure(OSStatus(exitCode))
        }
    }

    /// Extracts `claudeAiOauth.accessToken` from the stored JSON blob.
    public static func parseToken(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }
}
