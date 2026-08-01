import Foundation

/// Where we look, what we refuse to touch, and how a folder name becomes a bundle identifier.
///
/// This is the safety-critical file. Every guard that stops Cruft/Check from proposing
/// something catastrophic lives here rather than being scattered through the scanner.
/// The Library being scanned.
///
/// A parameter rather than a hardcoded path so tests can point the scanners at a synthetic
/// fixture. Without this the only way to exercise the Orphan Hunt is to wait for real cruft
/// to accumulate on a real machine — which is exactly the code path where a false positive
/// costs the user working software.
struct LibraryRoot: Sendable {
    let url: URL

    static var userLibrary: LibraryRoot {
        LibraryRoot(
            url: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library", directoryHint: .isDirectory)
        )
    }

    func directory(for domain: LibraryDomain) -> URL {
        url.appending(path: domain.rawValue, directoryHint: .isDirectory)
    }
}

enum LibraryPaths {

    /// Scanned by The Orphan Hunt.
    static let orphanDomains: [LibraryDomain] = [.applicationSupport, .caches, .preferences, .containers]

    /// Scanned by The Cache Diet.
    static let cacheDomains: [LibraryDomain] = [.caches, .logs]

    // MARK: - Safety

    /// Identifier prefixes that are never eligible for the Orphan Hunt.
    ///
    /// `com.apple.*` is the big one: LaunchServices has no app bundle for most Apple
    /// daemons, frameworks and system services, so they'd *all* look orphaned. Trashing
    /// them ranges from annoying (re-login) to destructive (losing Messages history).
    private static let protectedIdentifierPrefixes: [String] = [
        "com.apple.",
        "group.com.apple.",
        "systemgroup.",               // systemgroup.com.apple.* — Apple system state
        "org.cups.",                  // printer configuration; no app bundle will ever exist
        "com.microsoft.autoupdate",   // patches other installed apps
        "org.swift.",
        "com.docker.docker"           // VM disk images live here; nuking them loses volumes
    ]

    /// Exact directory names that are never eligible, in either mode.
    ///
    /// These hold user data or state that isn't reproducible, even though they sit in
    /// directories we otherwise treat as disposable.
    /// Matched case-insensitively; see `isProtected(name:)`.
    ///
    /// The second half of this list is the interesting part. Apple's own caches and logs do
    /// *not* all use a `com.apple.` prefix — `AMSDataMigratorTool` (Apple Media Services),
    /// `PassKit`, `GameKit` and friends are bare names. Several are guarded by TCC, so merely
    /// *measuring* them makes macOS raise a privacy prompt ("would like to access Apple
    /// Music, your music and video activity, and your media library") for directories the app
    /// would never offer to delete. Naming them here keeps the scan silent.
    private static let protectedNames: Set<String> = [
        // User data that is not regenerable.
        "MobileSync",                 // iOS device backups
        "CloudDocs",
        "CloudStorage",
        "com.apple.sharedfilelist",
        "Mobile Documents",
        "Application Scripts",
        "Keychains",
        "Safari",

        // Apple-owned caches and logs without a com.apple. prefix.
        "AMSDataMigratorTool",        // Apple Media Services — trips the media-library prompt
        "Animoji",
        "AppAnalytics",
        "askpermissiond",
        "Assistant",
        "AudioUnitCache",
        "Baseband",
        "CloudKit",
        "CrashReporter",
        "DiagnosticReports",
        "FamilyCircle",
        "familycircled",
        "GameKit",
        "GameStoreKit",
        "GeoServices",
        "MiniLauncher",
        "PassKit",
        "PhotosSearch.aapbz",
        "PhotosUpgrade.aapbz",
        "PrivacyPreservingMeasurement",
        "SiriTTSService",
        "snapshot",
        "Sync"
    ]

    private static let protectedNamesLowercased: Set<String> = Set(protectedNames.map { $0.lowercased() })

    static func isProtected(name: String) -> Bool {
        let lowered = name.lowercased()
        if protectedNamesLowercased.contains(lowered) { return true }
        return protectedIdentifierPrefixes.contains { lowered.hasPrefix($0.lowercased()) }
    }

    // MARK: - Identifier extraction

    /// Reverse-DNS shape: three or more dot-separated components of `[A-Za-z0-9_-]`.
    ///
    /// Three rather than two is deliberate. Two-component names produce false positives on
    /// ordinary folders ("Adobe.Setup"), and essentially every real bundle identifier in
    /// ~/Library has at least three parts. Folders with human names ("Google", "Sublime
    /// Text 4") fail this test and are simply never considered — the Orphan Hunt stays
    /// silent about them rather than guessing.
    ///
    /// Hand-rolled rather than a regex literal so it doesn't depend on the bare-slash
    /// regex build setting, and so it stays allocation-free in a hot loop.
    private static func looksLikeReverseDNS(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        }
    }

    /// Extracts a bundle identifier from a Library entry, or nil if the name isn't one.
    ///
    /// Handles the three shapes that actually occur:
    ///   - `Containers/com.acme.Widget`                     -> `com.acme.Widget`
    ///   - `Preferences/com.acme.Widget.plist`              -> `com.acme.Widget`
    ///   - `Preferences/ByHost/com.acme.Widget.<UUID>.plist` -> `com.acme.Widget`
    static func bundleIdentifier(from url: URL) -> String? {
        var name = url.lastPathComponent

        // Preferences entries are files: com.acme.Widget.plist, plus lock/backup siblings.
        for suffix in [".plist.lockfile", ".plist.bak", ".plist"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }

        // ByHost preferences append the hardware UUID: com.acme.Widget.0000-0000-....
        if url.deletingLastPathComponent().lastPathComponent == "ByHost" {
            name = strippingHostUUID(from: name)
        }

        // Group containers are namespaced by the owning app: group.com.acme.Widget.
        if name.hasPrefix("group.") {
            name = String(name.dropFirst("group.".count))
        }

        guard !isProtected(name: name) else { return nil }
        guard looksLikeReverseDNS(name) else { return nil }
        return name
    }

    /// Drops a trailing hardware-UUID component, which is hex-and-dashes and long.
    private static func strippingHostUUID(from name: String) -> String {
        var parts = name.components(separatedBy: ".")
        guard let last = parts.last, last.count >= 12 else { return name }
        let isUUIDish = last.allSatisfy { $0.isHexDigit || $0 == "-" }
        if isUUIDish { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    /// Candidate parent identifiers to test before declaring `bundleID` an orphan.
    ///
    /// Helpers and XPC services get their own identifiers ("com.acme.Widget.Helper") but
    /// have no app bundle of their own, so LaunchServices returns nil for them even while
    /// the parent app is installed. Testing successively shorter prefixes down to three
    /// components catches that whole class of false positive.
    static func ancestorIdentifiers(of bundleID: String) -> [String] {
        var parts = bundleID.components(separatedBy: ".")
        var result: [String] = []
        while parts.count > 3 {
            parts.removeLast()
            result.append(parts.joined(separator: "."))
        }
        return result
    }
}
