import Foundation
import CoreServices

/// Recursive FSEvents watch on a directory. A burst of file changes collapses
/// into one debounced callback (fired on a private queue).
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "tokei.directory-watcher")
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    public init(directory: URL, debounce: TimeInterval = 2.0,
                onChange: @escaping @Sendable () -> Void) {
        self.debounce = debounce
        self.onChange = onChange

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info!).takeUnretainedValue()
            watcher.scheduleCallback()
        }
        stream = FSEventStreamCreate(
            nil, callback, &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,   // FSEvents' own coalescing latency; our debounce sits on top
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return }   // dir missing → watcher inert, poll loop still covers refreshes
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func scheduleCallback() {
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        pending?.cancel()
    }
}
