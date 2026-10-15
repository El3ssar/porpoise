import Foundation
import CoreServices

/// Owns its stream and callback context for exactly the stream lifetime.
final class IndexEvents {
    private var stream: FSEventStreamRef?
    private let callback: ([String], UInt64, Bool) -> Void
    private let queue = DispatchQueue(label: "app.porpoise.index-events", qos: .utility)
    init(roots: [String], since: UInt64, callback: @escaping ([String], UInt64, Bool) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, ids in
            guard let info else { return }
            let owner = Unmanaged<IndexEvents>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as! [String]
            var rescan = false, last: UInt64 = 0
            for i in 0..<count {
                last = max(last, ids[i])
                let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
                if flags[i] & lost != 0 { rescan = true }
            }
            owner.callback(names, last, rescan)
        }, &context, roots as CFArray, since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since, 0.1, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
