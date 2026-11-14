import CoreServices
import Foundation

/// Calls `changed` when anything in a folder (or the folders inside it) changes on disk, using
/// macOS's file system events. Calls come on the main thread, a moment after the changes, with
/// bursts (a camera writing many files) gathered into one.
@MainActor
final class FolderWatcher {
    let url: URL
    private var stream: FSEventStreamRef?
    private let changed: @MainActor () -> Void

    /// `latency` is how long to gather changes before calling, in seconds.
    init?(url: URL, latency: TimeInterval = 0.5, changed: @escaping @MainActor () -> Void) {
        self.url = url
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [url.path(percentEncoded: false)] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit {
        stop()
    }
}
