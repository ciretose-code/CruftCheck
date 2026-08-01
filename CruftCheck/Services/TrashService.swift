import Foundation

/// The only code in Cruft/Check permitted to remove anything.
///
/// `FileManager.removeItem(at:)` is deliberately absent from this file and from the whole
/// project. Every removal goes to the macOS Trash via `trashItem(at:resultingItemURL:)`,
/// so a bad call is one Cmd-Z-equivalent away from being undone by the user. If you are
/// reviewing a change that adds `removeItem`, `unlink`, or a shell-out to `rm`, reject it.
enum TrashService {

    /// One item that could not be moved, and why.
    ///
    /// The reason is classified rather than left as a string because the categories need
    /// different things from the user. "macOS refused the write" is fixable in System
    /// Settings; the safety list refusing an item is not fixable and shouldn't look like it
    /// is. Passing `localizedDescription` straight through stated a fact and offered no
    /// route out of it.
    struct Failure: Sendable {
        enum Reason: Equatable, Sendable {
            /// macOS refused. On this app's paths that means Full Disk Access, essentially
            /// always — `~/Library/Containers` is unwritable without it.
            case permissionDenied
            /// Refused by `LibraryPaths` before macOS was ever asked.
            case protectedItem
            case other(String)
        }

        let url: URL
        let reason: Reason

        var message: String {
            switch reason {
            case .permissionDenied: "Needs Full Disk Access."
            case .protectedItem:    "Protected system item — skipped."
            case .other(let text):  text
            }
        }
    }

    struct Outcome: Sendable {
        var trashed: [URL] = []
        var failures: [Failure] = []
        var reclaimedBytes: UInt64 = 0

        var didFullySucceed: Bool { failures.isEmpty }

        /// Whether the run was blocked by the grant rather than by anything about the items.
        var needsFullDiskAccess: Bool {
            failures.contains { $0.reason == .permissionDenied }
        }

        /// The items macOS refused — offered to Finder, which has privileges this app
        /// doesn't, so the user has a way through that doesn't depend on the grant.
        var blockedURLs: [URL] {
            failures.filter { $0.reason == .permissionDenied }.map(\.url)
        }
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
                outcome.failures.append(Failure(url: url, reason: .protectedItem))
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
                outcome.failures.append(Failure(url: url, reason: reason(for: error)))
            }
        }

        return outcome
    }

    /// Classifies a `trashItem` error.
    ///
    /// Checks the Cocoa code and the underlying POSIX errno, because the same denial
    /// surfaces either way depending on where in the stack it was refused.
    private static func reason(for error: Error) -> Failure.Reason {
        let nsError = error as NSError

        let cocoaPermissionCodes = [
            NSFileWriteNoPermissionError,
            NSFileReadNoPermissionError,
            NSFileWriteVolumeReadOnlyError
        ]
        if nsError.domain == NSCocoaErrorDomain, cocoaPermissionCodes.contains(nsError.code) {
            return .permissionDenied
        }

        if let posix = posixCode(in: nsError), posix == EPERM || posix == EACCES {
            return .permissionDenied
        }

        return .other(error.localizedDescription)
    }

    private static func posixCode(in error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return nil }
        return posixCode(in: underlying)
    }
}
