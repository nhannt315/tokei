import Foundation

/// Downloads a staged update and swaps it in over the running bundle.
///
/// The swap cannot happen in-process: the app would have to outlive its own
/// replacement. Instead a detached `/bin/sh` waits for this process to exit,
/// moves the new bundle into place, and relaunches. A running bundle *can* be
/// renamed on APFS, so the old copy is kept aside until the new one lands and
/// is restored if the move fails.
public struct UpdateInstaller: Sendable {
    public enum InstallError: Error, Equatable {
        case download(String)
        case unpack(String)
        case noBundleInArchive
        case identifierMismatch
        case notInstalled(String)
        case swapFailed(String)
    }

    /// Bundle id the unpacked app must declare before we trust it.
    public let expectedIdentifier: String

    public init(expectedIdentifier: String = "com.nhannt315.tokei") {
        self.expectedIdentifier = expectedIdentifier
    }

    /// Downloads and unpacks the update, returning the staged `.app` path.
    /// Staging is separate from installing so a failed download never touches
    /// the installed bundle.
    public func stage(_ update: AvailableUpdate) async throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokei-update-\(update.version)")
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let zipURL = workDir.appendingPathComponent("update.zip")
        do {
            let (tmp, response) = try await URLSession.shared.download(from: update.downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw InstallError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try FileManager.default.moveItem(at: tmp, to: zipURL)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.download(error.localizedDescription)
        }

        // ditto (not unzip) — it preserves the bundle's code signature and symlinks.
        let unpackDir = workDir.appendingPathComponent("unpacked")
        let result = Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpackDir.path])
        guard result.status == 0 else { throw InstallError.unpack(result.output) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: unpackDir,
                                                                     includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.noBundleInArchive
        }
        // Never swap in a bundle that is not us, whatever the release said.
        guard Self.bundleIdentifier(at: app) == expectedIdentifier else {
            throw InstallError.identifierMismatch
        }
        return app
    }

    /// Spawns the detached swap script and returns. The caller must terminate
    /// promptly afterwards — the script blocks until this PID disappears.
    ///
    /// `installedAt` is the bundle to replace (`Bundle.main.bundleURL`).
    public func installOnExit(staged: URL, installedAt: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: installedAt.path, isDirectory: &isDir), isDir.boolValue else {
            throw InstallError.notInstalled(installedAt.path)
        }
        guard FileManager.default.isWritableFile(atPath: installedAt.deletingLastPathComponent().path) else {
            throw InstallError.swapFailed("no write permission for \(installedAt.deletingLastPathComponent().path)")
        }

        let script = Self.swapScript(staged: staged, installed: installedAt, pid: ProcessInfo.processInfo.processIdentifier)
        let scriptURL = staged.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        do {
            try process.run()   // detached: we exit, it keeps going
        } catch {
            throw InstallError.swapFailed(error.localizedDescription)
        }
    }

    /// Waits for the app to exit, swaps bundles, relaunches, and rolls back if
    /// the new bundle fails to move into place.
    static func swapScript(staged: URL, installed: URL, pid: Int32) -> String {
        let new = shellQuote(staged.path)
        let target = shellQuote(installed.path)
        let backup = shellQuote(installed.path + ".old")
        return """
        #!/bin/sh
        # Wait for Tokei (pid \(pid)) to exit; bail out if it lingers.
        i=0
        while kill -0 \(pid) 2>/dev/null; do
            i=$((i + 1))
            [ "$i" -gt 300 ] && exit 1
            sleep 0.1
        done

        rm -rf \(backup)
        mv \(target) \(backup) || exit 1
        if ! mv \(new) \(target); then
            mv \(backup) \(target)   # put the old app back, update abandoned
            exit 1
        fi
        rm -rf \(backup)
        open -n \(target)
        """
    }

    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func bundleIdentifier(at app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return root["CFBundleIdentifier"] as? String
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
