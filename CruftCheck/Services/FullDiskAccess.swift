import Foundation

/// Answers "can this app actually read all of `~/Library`?" before the user makes a plan
/// that depends on it.
///
/// Without the grant the app degrades quietly rather than loudly: it still enumerates and
/// sizes plenty, so a scan looks like it worked, and the refusal only surfaces at the moment
/// something is moved to the Trash — after the user has chosen items and confirmed a
/// destructive action. Asking up front turns that into a statement the app can make before
/// any of that effort is spent.
///
/// There is no API to query TCC. The only way to know is to attempt a read and see.
enum FullDiskAccess {

    /// A directory readable only with Full Disk Access, present on every Mac.
    ///
    /// Chosen because it fails *silently*. The purpose-limited directories — Music, Photos,
    /// Calendars — would also prove the point, but asking raises a consent dialog, which is
    /// the exact prompt `LibraryPaths` exists to keep the app from triggering.
    private static var probe: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.TCC", directoryHint: .isDirectory)
    }

    enum Status: Equatable, Sendable {
        case granted
        case denied
        /// The probe wasn't where it was expected. Says nothing either way, and must not be
        /// reported as a denial — warning about a missing grant that is present would train
        /// the user to ignore the warning.
        case unknown
    }

    /// Synchronous and cheap: one directory listing. Safe for `Background.run`.
    static func status() -> Status {
        let path = probe.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil ? .granted : .denied
    }

    /// Opens the Full Disk Access list directly, rather than dropping the user at the top of
    /// System Settings to find it.
    static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    }
}
