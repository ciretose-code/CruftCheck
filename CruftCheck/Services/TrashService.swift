import Foundation

/// The only code in Cruft/Check permitted to remove anything.
///
/// `FileManager.removeItem(at:)` is deliberately absent from this file and from the whole
/// project. Every removal goes to the macOS Trash via `trashItem(at:resultingItemURL:)`,
/// so a bad call is one Cmd-Z-equivalent away from being undone by the user. If you are
/// reviewing a change that adds `removeItem`, `unlink`, or a shell-out to `rm`, reject it.
enum TrashService {

    struct Outcome: Sendable {
        var trashed: [URL] = []
        var failures: [(url: URL, message: String)] = []
        var reclaimedBytes: UInt64 = 0

        var didFullySucceed: Bool { failures.isEmpty }
    }

    /// Moves each URL to the Trash. Synchronous — call it through `Background.run`, since
    /// trashing a large tree copies metadata and can block for seconds.
    ///
    /// - Parameter expectedBytes: Per-URL sizes measured during the scan, used to report
    ///   how much was reclaimed without re-walking trees that no longer exist.
    static func trash(_ urls: [URL], expectedBytes: [URL: UInt64] = [:]) -> Outcome {
        let fileManager = FileManager.default
        var outcome = Outcome()

        for url in urls {
            // Belt and braces: the safety list is enforced at scan time, but this is the
            // last gate before destruction, so it is re-checked here too.
            guard !LibraryPaths.isProtected(name: url.lastPathComponent) else {
                outcome.failures.append((url, "Protected system item — skipped."))
                continue
            }

            // Already gone (the app cleaned up after itself, or a previous run got it).
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
                outcome.trashed.append(url)
                continue
            }

            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                outcome.trashed.append(url)
                outcome.reclaimedBytes &+= expectedBytes[url] ?? 0
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }

        return outcome
    }
}
