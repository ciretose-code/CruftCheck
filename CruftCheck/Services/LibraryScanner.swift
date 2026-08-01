import Foundation

/// The two scans, expressed as synchronous work suitable for `Background.run`.
///
/// The scanner never decides what is installed — that judgement needs AppKit and belongs
/// to `InstalledAppIndex` on the main actor. Instead the Orphan Hunt is split into two
/// background phases with a cheap main-actor filter between them:
///
///   1. `collectOrphanCandidates()`  — background: enumerate top level, extract identifiers
///   2. `InstalledAppIndex`          — main actor: LaunchServices lookup (fast, in-memory)
///   3. `size(candidates:)`          — background: deep enumeration of survivors only
///
/// Sizing only the survivors matters: on a typical machine it's a few dozen directories
/// instead of several hundred.
enum LibraryScanner {

    /// A directory or file that *might* belong to an uninstalled app. Not yet sized.
    struct Candidate: Sendable {
        let bundleID: String
        let url: URL
        let domain: LibraryDomain
    }

    // MARK: - Mode 1: The Orphan Hunt

    /// Phase 1. Lists the top level of each orphan domain and keeps entries whose names
    /// parse as bundle identifiers. Cheap: one shallow listing per directory, no recursion.
    static func collectOrphanCandidates(in library: LibraryRoot = .userLibrary) -> [Candidate] {
        var candidates: [Candidate] = []

        for domain in LibraryPaths.orphanDomains {
            let root = library.directory(for: domain)

            for url in shallowContents(of: root) {
                if let bundleID = LibraryPaths.bundleIdentifier(from: url) {
                    candidates.append(Candidate(bundleID: bundleID, url: url, domain: domain))
                }
            }

            // Preferences/ByHost holds a second, parallel set of plists.
            if domain == .preferences {
                let byHost = root.appending(path: "ByHost", directoryHint: .isDirectory)
                for url in shallowContents(of: byHost) {
                    if let bundleID = LibraryPaths.bundleIdentifier(from: url) {
                        candidates.append(Candidate(bundleID: bundleID, url: url, domain: domain))
                    }
                }
            }
        }

        return candidates
    }

    /// Phase 2. Keeps only the candidates that no installed software claims.
    ///
    /// Pure, so the safety rule can be tested against a synthetic Library without needing
    /// particular apps installed on the machine running the tests.
    static func orphans(among candidates: [Candidate], presence: AppPresence) -> [Candidate] {
        candidates.filter { !presence.isInstalled($0.bundleID) }
    }

    /// Phase 3. Sizes the confirmed orphans and groups them by bundle identifier, so one
    /// dead app with four leftover directories reads as a single row.
    static func group(
        _ candidates: [Candidate],
        isCancelled: () -> Bool = { false },
        onProgress: (ScanProgress) -> Void = { _ in }
    ) -> [OrphanGroup] {
        var groups: [String: [OrphanPath]] = [:]

        for (index, candidate) in candidates.enumerated() {
            if isCancelled() { break }

            let bytes = DirectorySizer.size(of: candidate.url, isCancelled: isCancelled)
            groups[candidate.bundleID, default: []].append(
                OrphanPath(url: candidate.url, domain: candidate.domain, bytes: bytes)
            )

            onProgress(ScanProgress(
                completed: index + 1,
                total: candidates.count,
                label: candidate.bundleID
            ))
        }

        return groups
            .map { OrphanGroup(bundleID: $0.key, paths: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Mode 2: The Cache Diet

    /// Sizes every top-level directory in ~/Library/Caches and ~/Library/Logs, largest first.
    ///
    /// Unlike the Orphan Hunt this makes no claim about whether an app is installed — the
    /// premise is that these belong to apps you *do* use, and the caches are regenerable.
    ///
    /// Protected (system) directories are filtered out *before* sizing, not merely disabled
    /// in the UI. Walking into `~/Library/Caches/com.apple.Music` triggers a TCC prompt
    /// asking for the user's media library — a genuinely alarming dialog to raise while
    /// merely measuring something we would never offer to delete anyway.
    static func scanCaches(
        in library: LibraryRoot = .userLibrary,
        isCancelled: () -> Bool = { false },
        onProgress: (ScanProgress) -> Void = { _ in }
    ) -> CacheScan {
        var targets: [(url: URL, domain: LibraryDomain)] = []
        var skipped = 0

        for domain in LibraryPaths.cacheDomains {
            for url in shallowContents(of: library.directory(for: domain)) {
                if LibraryPaths.isProtected(name: url.lastPathComponent) {
                    skipped += 1
                } else {
                    targets.append((url, domain))
                }
            }
        }

        var entries: [CacheEntry] = []
        entries.reserveCapacity(targets.count)

        for (index, target) in targets.enumerated() {
            if isCancelled() { break }

            let bytes = DirectorySizer.size(of: target.url, isCancelled: isCancelled)
            entries.append(CacheEntry(url: target.url, domain: target.domain, bytes: bytes))

            onProgress(ScanProgress(
                completed: index + 1,
                total: targets.count,
                label: target.url.lastPathComponent
            ))
        }

        return CacheScan(
            entries: entries.sorted { $0.bytes > $1.bytes },
            skippedSystemItems: skipped
        )
    }

    // MARK: - Shared

    /// One level of `directory`, hidden entries included (plenty of cruft is dot-prefixed).
    /// A missing or unreadable directory yields an empty list rather than an error — an
    /// absent ~/Library/Logs is normal, not exceptional.
    private static func shallowContents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
    }
}
