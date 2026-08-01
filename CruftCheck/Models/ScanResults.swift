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

/// A single on-disk item that belongs to an orphaned bundle identifier.
struct OrphanPath: Identifiable, Hashable, Sendable {
    let url: URL
    let domain: LibraryDomain
    var bytes: UInt64

    var id: URL { url }
}

/// All the leftovers for one bundle identifier, grouped so the UI shows
/// "com.acme.widget — 3 items, 412 MB" instead of three unrelated rows.
struct OrphanGroup: Identifiable, Hashable, Sendable {
    let bundleID: String
    var paths: [OrphanPath]

    var id: String { bundleID }
    var bytes: UInt64 { paths.reduce(0) { $0 + $1.bytes } }
    var urls: [URL] { paths.map(\.url) }

    /// Best-effort human name: the last component of the reverse-DNS identifier,
    /// which is nearly always the product name ("com.acme.WidgetPro" -> "WidgetPro").
    var displayName: String { bundleID.components(separatedBy: ".").last ?? bundleID }
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
