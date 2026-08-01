import Foundation

/// The single choke point where Cruft/Check leaves the main actor.
///
/// Every deep enumeration, `stat(2)` storm and trash operation goes through here, so
/// there is exactly one place to audit if the UI ever hitches.
enum Background {
    /// Runs `work` on the global user-initiated queue and resumes the caller with the result.
    ///
    /// The caller stays `async`, so a `@MainActor` view model can `await` this and land
    /// back on the main actor automatically — no `DispatchQueue.main.async` dance, and no
    /// chance of accidentally mutating `@Observable` state off the main thread.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
