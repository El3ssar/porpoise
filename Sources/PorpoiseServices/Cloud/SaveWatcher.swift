import Foundation

/// Follows editor saves, including inode replacement, and debounces a burst into one callback.
/// The callback queue may serialize uploads; events keep arriving while an upload runs.
final class SaveWatcher: @unchecked Sendable {
    private let local: URL
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private let changed: () -> Void
    private let save: () -> Void
    private let reattach: (@escaping () -> Void) -> Void
    private let events = DispatchQueue(label: "porpoise.save-watch", autoreleaseFrequency: .workItem)
    private let lock = NSRecursiveLock()
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var cancelled = false

    init(
        _ local: URL, delay: TimeInterval, queue: DispatchQueue,
        reattach: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        changed: @escaping () -> Void = {}, save: @escaping () -> Void
    ) {
        self.local = local; self.delay = delay; self.queue = queue
        self.reattach = reattach; self.changed = changed; self.save = save
        attach()
    }
    deinit { cancel() }
    func cancel() {
        lock.withLock {
            cancelled = true; pending?.cancel(); pending = nil; source?.cancel(); source = nil
        }
    }
    private func attach(uploading: ino_t? = nil) {
        lock.withLock {
            guard !cancelled else { return }
            source?.cancel(); source = nil
            let fd = Darwin.open(local.path, O_EVTONLY)
            guard fd >= 0 else { return }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: events)
            watch.setCancelHandler { close(fd) }
            watch.setEventHandler { [weak self, weak watch] in
                guard let watch else { return }
                self?.event(replaced: watch.data.contains(.rename) || watch.data.contains(.delete))
            }
            source = watch; watch.resume()
            var st = stat()
            if let uploading, fstat(fd, &st) == 0, st.st_ino != uploading {
                events.async { [weak self] in self?.event(replaced: false) }
            }
        }
    }
    private func event(replaced: Bool) {
        lock.withLock {
            guard !cancelled else { return }
            changed(); pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.lock.withLock({ self.cancelled }) else { return }
                guard FileManager.default.fileExists(atPath: self.local.path) else { self.cancel(); return }
                if replaced {
                    var st = stat()
                    let inode = stat(self.local.path, &st) == 0 ? st.st_ino : nil
                    self.reattach { [weak self] in self?.attach(uploading: inode) }
                }
                self.save()
            }
            pending = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}
