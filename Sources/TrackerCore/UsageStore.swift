import Foundation

/// Scans `~/.claude/projects/**/*.jsonl`, owns incremental state and dedupe.
///
/// Dedupe: events keyed by message id — a later record for the same id REPLACES
/// the earlier one (Claude Code writes streaming placeholder entries that a
/// final record supersedes).
///
/// Incremental: per-file (size, mtime, offset). Unchanged file → skip; grown
/// file → parse appended complete lines only; shrunk/rewritten file → re-parse.
/// State is in-memory only: cold launch re-scans (seconds), the refresh loop
/// is what needs to be cheap.
public final class UsageStore {
    public struct FileState {
        var size: UInt64
        var mtime: Date
        var offset: UInt64   // bytes parsed so far (always ends on a line boundary)
    }

    public struct ScanStats {
        public var filesSeen = 0
        public var filesParsed = 0
        public var bytesParsed: UInt64 = 0
        public var skippedLines = 0
        public var elapsed: TimeInterval = 0
    }

    private var fileStates: [String: FileState] = [:]
    private var eventsByKey: [String: UsageEvent] = [:]
    private let parser = JSONLParser()
    public private(set) var totalSkippedLines = 0

    public let projectsDir: URL

    public init(projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")) {
        self.projectsDir = projectsDir
    }

    public var events: [UsageEvent] { Array(eventsByKey.values) }

    @discardableResult
    public func scan() -> ScanStats {
        var stats = ScanStats()
        let started = Date()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: projectsDir,
                                             includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return stats
        }
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            stats.filesSeen += 1
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize.map(UInt64.init),
                  let mtime = values.contentModificationDate else { continue }
            let path = url.path
            let cached = fileStates[path]

            let parseFrom: UInt64
            if let cached, cached.size == size, cached.mtime == mtime {
                continue                                   // unchanged
            } else if let cached, size > cached.size {
                parseFrom = cached.offset                  // appended → parse the tail
            } else {
                parseFrom = 0                              // new or rewritten → full parse
                if cached != nil { removeEvents(fromSession: path) }
            }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: parseFrom)) != nil,
                  let data = try? handle.readToEnd(), !data.isEmpty else {
                fileStates[path] = FileState(size: size, mtime: mtime, offset: parseFrom)
                continue
            }

            // Parse complete lines only; a partially-written trailing line waits
            // for the next scan.
            let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
            let completeEnd = lastNewline.map { data.index(after: $0) } ?? data.startIndex
            let complete = data[data.startIndex..<completeEnd]

            let result = parser.parse(data: Data(complete), sessionPath: path)
            for event in result.events {
                eventsByKey[event.dedupeKey] = event       // last-written record wins
            }
            stats.filesParsed += 1
            stats.bytesParsed += UInt64(complete.count)
            stats.skippedLines += result.skippedLines
            totalSkippedLines += result.skippedLines
            fileStates[path] = FileState(size: size, mtime: mtime,
                                         offset: parseFrom + UInt64(complete.count))
        }
        stats.elapsed = Date().timeIntervalSince(started)
        return stats
    }

    private func removeEvents(fromSession path: String) {
        for (key, event) in eventsByKey where event.sessionPath == path {
            eventsByKey.removeValue(forKey: key)
        }
    }
}
