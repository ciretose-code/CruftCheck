import Foundation

/// One "kind" of Library directory, used purely for labelling rows in the UI.
enum LibraryDomain: String, Sendable, CaseIterable {
    case applicationSupport = "Application Support"
    case caches             = "Caches"
    case preferences        = "Preferences"
    case containers         = "Containers"
    case logs               = "Logs"

    var symbol: String {
        switch self {
        case .applicationSupport: "shippingbox"
        case .caches:             "arrow.triangle.2.circlepath"
        case .preferences:        "slider.horizontal.3"
        case .containers:         "cube.box"
        case .logs:               "doc.text"
        }
    }
}

/// Why an identifier was judged to belong to software that is no longer installed.
///
/// `AppPresence` runs a fixed sequence of "spare it" checks and an identifier is only an
/// orphan when every one of them declines to claim it. Recording *which* checks ran turns
/// the rule's answer from a bare `false` into something the UI can show: the app's caution
/// is its most defensible property, and until now none of it was visible on screen.
struct OrphanEvidence: Hashable, Sendable {

    /// One check that ran and found nothing.
    ///
    /// Only checks that were *meaningful* for the identifier appear. A three-component
    /// identifier has no ancestors to test, and a single-component name has no vendor
    /// prefix, so neither produces a finding rather than producing a vacuous one.
    enum Check: Hashable, Sendable {
        /// Neither LaunchServices nor the running-application list knows this identifier.
        case noLaunchServicesMatch
        /// The shorter parent identifiers don't resolve either — it isn't a helper.
        case noInstalledAncestor(checked: [String])
        /// No `.app` bundle on disk ships under this vendor prefix — it isn't an XPC service.
        case noInstalledVendor(prefix: String)

        var label: String {
            switch self {
            case .noLaunchServicesMatch:
                "No Launch Services match"
            case .noInstalledAncestor(let checked):
                checked.count == 1
                    ? "Parent \(checked[0]) not installed"
                    : "No installed parent identifier"
            case .noInstalledVendor(let prefix):
                "No installed \(prefix) bundle"
            }
        }
    }

    var checks: [Check] = []
}

/// A single on-disk item that belongs to an orphaned bundle identifier.
struct OrphanPath: Identifiable, Hashable, Sendable {
    let url: URL
    let domain: LibraryDomain
    var bytes: UInt64
    /// Newest modification anywhere under this path. Defaulted so callers that don't
    /// measure recency — tests, previews — need not invent one.
    var lastModified: Date?

    var id: URL { url }
}

/// All the leftovers for one bundle identifier, grouped so the UI shows
/// "com.acme.widget — 3 items, 412 MB" instead of three unrelated rows.
struct OrphanGroup: Identifiable, Hashable, Sendable {
    let bundleID: String
    var paths: [OrphanPath]
    /// The checks that failed to claim this identifier. Defaulted so previews and tests can
    /// build a group without restating the rule's output.
    var evidence: OrphanEvidence = OrphanEvidence()

    var id: String { bundleID }
    var bytes: UInt64 { paths.reduce(0) { $0 + $1.bytes } }
    var urls: [URL] { paths.map(\.url) }

    /// Best-effort human name: the last component of the reverse-DNS identifier,
    /// which is nearly always the product name ("com.acme.WidgetPro" -> "WidgetPro").
    var displayName: String { bundleID.components(separatedBy: ".").last ?? bundleID }

    /// The domain holding most of this group's bytes. Sections the list by where the space
    /// actually is, rather than by whichever domain happened to be enumerated first.
    var primaryDomain: LibraryDomain {
        paths.max { $0.bytes < $1.bytes }?.domain ?? .applicationSupport
    }

    /// Every leftover is a preference file — kilobytes, not gigabytes. Worth separating so a
    /// 700 KB plist never sits in the same visual rank as a 2.7 GB support folder.
    var isPreferencesOnly: Bool {
        !paths.isEmpty && paths.allSatisfy { $0.domain == .preferences }
    }

    /// The most recent change across every leftover this identifier owns.
    var lastModified: Date? {
        paths.compactMap(\.lastModified).max()
    }

    /// How long since anything here changed, phrased for a chip — or `nil` when the age
    /// isn't worth showing.
    ///
    /// Two ways to get `nil`, and conflating them would be a lie. Nothing was readable, so
    /// there is no age; or the age is short, in which case it is not evidence of anything —
    /// an app uninstalled last week leaves recent files behind, and a chip reading
    /// "Untouched 6 days" invites the user to weigh a number that means nothing.
    var stalenessLabel: String? {
        guard let lastModified else { return nil }

        let calendar = Calendar.current
        let months = calendar.dateComponents([.month], from: lastModified, to: .now).month ?? 0
        guard months >= 3 else { return nil }

        if months >= 24 { return "Untouched \(months / 12) years" }
        if months >= 12 { return "Untouched over a year" }
        return "Untouched \(months) months"
    }
}

/// One top-level directory inside ~/Library/Caches or ~/Library/Logs.
struct CacheEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let domain: LibraryDomain
    var bytes: UInt64

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Result of a Cache Diet scan.
struct CacheScan: Sendable {
    var entries: [CacheEntry] = []
    /// Entries that measured zero bytes, kept out of the main list.
    ///
    /// A row that can free nothing can't help you choose, and it costs the same space on
    /// screen as one that can. They're kept rather than discarded so the count stays
    /// honest and the tidy action has something to act on.
    ///
    /// "Zero bytes" means no regular file data — `DirectorySizer` counts only regular
    /// files, so one of these may still contain empty subdirectories.
    var emptyEntries: [CacheEntry] = []
    /// System caches deliberately not measured. Surfaced as a count so the user knows the
    /// list is filtered rather than wondering why ~/Library/Caches looks bigger in Finder.
    var skippedSystemItems: Int = 0
}

/// Progress ticks pushed up from the background enumeration.
struct ScanProgress: Sendable {
    var completed: Int
    var total: Int
    var label: String

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}
