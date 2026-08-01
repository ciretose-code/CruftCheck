import Foundation

/// A thread-safe cancellation signal readable from a plain dispatch queue.
///
/// `Task.isCancelled` is useless inside `Background.run`: the closure runs on a GCD queue
/// with no enclosing task, so the property reads `false` forever and a long enumeration
/// would run to completion after the user cancelled. This flag is set on the main actor
/// and polled from the background walk instead.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
