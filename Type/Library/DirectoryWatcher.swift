import Foundation
import CoreServices

/// Watches a folder tree with FSEvents and calls `onChange` (debounced, on main)
/// with the paths that changed since the last call.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void
    private var pending: DispatchWorkItem?
    private var changedPaths: Set<String> = []

    init(url: URL, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().fire(list.prefix(count).map { $0 })
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func fire(_ paths: [String]) {
        changedPaths.formUnion(paths)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.changedPaths)
            self.changedPaths = []
            self.onChange(paths)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
