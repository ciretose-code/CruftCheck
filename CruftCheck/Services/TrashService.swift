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
            /// macOS refused the write. Usually Full Disk Access — but not always, which is
            /// why this records *what happened* rather than *what to do about it*. Whether
            /// the grant is the cause depends on whether the grant is present, and only the
            /// caller knows that.
            case permissionDenied
            /// The volume itself is read-only. No permission grant changes this, and Finder
            /// can't do it either.
            case readOnlyVolume
            /// Refused by `LibraryPaths` before macOS was ever asked.
            case protectedItem
            case other(String)
        }

        let url: URL
        let reason: Reason

        var message: String {
            switch reason {
            case .permissionDenied: "macOS refused to remove this."
            case .readOnlyVolume:   "The volume is read-only."
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

        /// Items macOS refused on permission grounds. Offered to Finder, which holds
        /// privileges this app doesn't, so there's a route through that doesn't depend on
        /// any grant.
        ///
        /// Read-only volumes are excluded: Finder can't write there either, so pointing the
        /// user at it would waste their time. Protected items are excluded because the
        /// refusal is this app's own and no external tool is being suggested.
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
                outcome.failures.append(Failure(url: url, reason: classify(error)))
            }
        }

        return outcome
    }

    /// Classifies a `trashItem` error.
    ///
    /// Checks the Cocoa code and the underlying POSIX errno, because the same denial
    /// surfaces either way depending on where in the stack it was refused.
    ///
    /// Not private so the tests can drive it with constructed errors. Provoking a genuine
    /// read-only-volume failure would mean mounting one.
    static func classify(_ error: Error) -> Failure.Reason {
        let nsError = error as NSError
        let posix = posixCode(in: nsError)

        // Checked before the permission codes, not after. A read-only volume is a denial
        // too, and folding it in with the rest would have the app recommend a permission
        // grant for something no grant can fix.
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteVolumeReadOnlyError {
            return .readOnlyVolume
        }
        if posix == EROFS {
            return .readOnlyVolume
        }

        let cocoaPermissionCodes = [NSFileWriteNoPermissionError, NSFileReadNoPermissionError]
        if nsError.domain == NSCocoaErrorDomain, cocoaPermissionCodes.contains(nsError.code) {
            return .permissionDenied
        }
        if posix == EPERM || posix == EACCES {
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
