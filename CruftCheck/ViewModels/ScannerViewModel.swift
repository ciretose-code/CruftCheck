import Foundation
import Observation

/// Owns all scan state and is the app's only bridge between the background queue and SwiftUI.
///
/// `@MainActor` on the whole type is the enforcement mechanism for the threading rule: every
/// stored property here can only be mutated on the main actor, so publishing a result off the
/// main thread is a compile error rather than a runtime glitch. The expensive work escapes
/// via `await Background.run { ... }`, which returns the caller to the main actor on its own.
@MainActor
@Observable
final class ScannerViewModel {

    enum Phase: Equatable {
        case idle
        case scanning
        case done
        case cancelled
    }

    // MARK: - Observable state

    var mode: ScanMode = .orphanHunt {
        didSet { if oldValue != mode { scan() } }
    }

    private(set) var orphans: [OrphanGroup] = []
    private(set) var caches: [CacheEntry] = []
    /// Caches that measured zero bytes. Kept out of `caches` so they don't take list space
    /// they can't earn, but retained so `tidyEmptyCaches` has something to act on.
    private(set) var emptyCaches: [CacheEntry] = []
    /// System caches the scanner refused to measure — see `LibraryScanner.scanCaches`.
    private(set) var skippedSystemItems = 0
    private(set) var phase: Phase = .idle
    private(set) var progress: ScanProgress?
    private(set) var failure: TrashFailure?
    private(set) var reclaimedBytes: UInt64 = 0
    /// Checked at the start of every scan. `.denied` means results are incomplete and
    /// nothing can be trashed, which the user needs to know before choosing anything.
    private(set) var diskAccess: FullDiskAccess.Status = .unknown
    /// The volume's own numbers, so the reclaimable total has something to be a fraction of.
    private(set) var capacity: VolumeCapacity?

    /// What to tell the user when items couldn't be moved, and what to offer them about it.
    struct TrashFailure {
        var message: String
        /// Drives the offer of System Settings, and of Finder as the way through meanwhile.
        var needsFullDiskAccess: Bool
        /// The items macOS refused, for revealing in Finder.
        var blockedURLs: [URL] = []

        var title: String {
            needsFullDiskAccess
                ? "Cruft/Check needs Full Disk Access"
                : "Some items couldn't be moved to the Trash"
        }
    }

    /// Bundle identifiers the user has ticked in the Orphan Hunt.
    var selection: Set<OrphanGroup.ID> = []

    // MARK: - Derived

    var isScanning: Bool { phase == .scanning }

    var selectedGroups: [OrphanGroup] {
        orphans.filter { selection.contains($0.id) }
    }

    var selectedBytes: UInt64 {
        selectedGroups.reduce(0) { $0 + $1.bytes }
    }

    /// Total recoverable bytes surfaced by the current mode.
    var totalBytes: UInt64 {
        switch mode {
        case .orphanHunt: orphans.reduce(0) { $0 + $1.bytes }
        case .cacheDiet:  caches.reduce(0) { $0 + $1.bytes }
        }
    }

    var hasResults: Bool {
        switch mode {
        case .orphanHunt: !orphans.isEmpty
        case .cacheDiet:  !caches.isEmpty
        }
    }

    // MARK: - Private

    private let appIndex = InstalledAppIndex()
    private var scanTask: Task<Void, Never>?
    /// Polled by the background walk; `Task.isCancelled` can't be (see CancellationFlag).
    private var scanFlag = CancellationFlag()

    // MARK: - Scanning

    func scan() {
        scanFlag.cancel()          // stop any walk still running from the previous scan
        scanTask?.cancel()
        scanFlag = CancellationFlag()

        phase = .scanning
        progress = nil
        failure = nil
        selection.removeAll()

        let mode = mode
        scanTask = Task { [weak self] in
            // Before the walk, not after it fails: one directory listing, and it decides
            // whether anything the scan finds can actually be acted on.
            self?.diskAccess = await Background.run { FullDiskAccess.status() }
            self?.capacity = await Background.run { VolumeCapacity.current() }

            switch mode {
            case .orphanHunt: await self?.runOrphanHunt()
            case .cacheDiet:  await self?.runCacheDiet()
            }
        }
    }

    func cancelScan() {
        scanFlag.cancel()
        scanTask?.cancel()
        scanTask = nil
        phase = .cancelled
        progress = nil
    }

    private func runOrphanHunt() async {
        let flag = scanFlag

        // Phase 1 — background: shallow listing, identifier extraction, and the app-bundle
        // sweep that tells us which vendors are still installed.
        let candidates = await Background.run { LibraryScanner.collectOrphanCandidates() }
        let vendors = await Background.run { AppBundleIndex.vendorPrefixes(of: AppBundleIndex.installedIdentifiers()) }
        guard !flag.isCancelled else { return finishCancelled(flag) }

        // Phase 2 — main actor: LaunchServices lookups. Cheap and AppKit-bound.
        appIndex.load(vendorPrefixes: vendors)
        let unresolved = LibraryScanner.orphans(among: candidates, presence: appIndex.presence)
        guard !flag.isCancelled else { return finishCancelled(flag) }

        // Phase 3 — background: deep sizing of the survivors only.
        let report = progressReporter(flag)
        let groups = await Background.run {
            LibraryScanner.group(unresolved, isCancelled: { flag.isCancelled }, onProgress: report)
        }
        guard !flag.isCancelled else { return finishCancelled(flag) }

        orphans = groups
        progress = nil
        phase = .done
    }

    private func runCacheDiet() async {
        let flag = scanFlag
        let report = progressReporter(flag)

        let result = await Background.run {
            LibraryScanner.scanCaches(isCancelled: { flag.isCancelled }, onProgress: report)
        }
        guard !flag.isCancelled else { return finishCancelled(flag) }

        caches = result.entries
        emptyCaches = result.emptyEntries
        skippedSystemItems = result.skippedSystemItems
        progress = nil
        phase = .done
    }

    /// Only the *current* scan may write terminal state. A superseded walk that finally
    /// notices its flag must not stomp on the scan that replaced it.
    private func finishCancelled(_ flag: CancellationFlag) {
        guard flag === scanFlag else { return }
        progress = nil
        phase = .cancelled
    }

    /// Bridges background progress ticks back onto the main actor.
    ///
    /// Ticks from a superseded scan are dropped, so a slow dying walk can't rewind the
    /// progress bar of the scan that replaced it.
    private func progressReporter(_ flag: CancellationFlag) -> @Sendable (ScanProgress) -> Void {
        { [weak self] tick in
            Task { @MainActor in
                guard let self, flag === self.scanFlag else { return }
                self.progress = tick
            }
        }
    }

    // MARK: - Deletion (Trash only — see TrashService)

    func trashSelectedOrphans() async {
        let groups = selectedGroups
        guard !groups.isEmpty else { return }

        let urls = groups.flatMap(\.urls)
        let sizes = Dictionary(
            groups.flatMap(\.paths).map { ($0.url, $0.bytes) },
            uniquingKeysWith: { first, _ in first }
        )

        let outcome = await Background.run { TrashService.trash(urls, expectedBytes: sizes) }

        let trashed = Set(outcome.trashed)
        orphans.removeAll { group in group.urls.allSatisfy(trashed.contains) }
        selection.removeAll()
        reclaimedBytes &+= outcome.reclaimedBytes
        report(outcome)
    }

    func clearCache(_ entry: CacheEntry) async {
        let outcome = await Background.run {
            TrashService.trash([entry.url], expectedBytes: [entry.url: entry.bytes])
        }

        if outcome.trashed.contains(entry.url) {
            caches.removeAll { $0.id == entry.id }
            emptyCaches.removeAll { $0.id == entry.id }
            reclaimedBytes &+= outcome.reclaimedBytes
        }
        report(outcome)
    }

    /// Moves the zero-byte cache folders to the Trash.
    ///
    /// This reclaims nothing and is not pretending to. It exists because those folders are
    /// clutter, and the honest framing is tidying rather than freeing space — `reclaimedBytes`
    /// is driven by `expectedBytes`, which is zero for every one of these, so the figure the
    /// footer reports cannot be inflated by running it.
    ///
    /// An app you still use is free to recreate its cache folder on next launch. That's the
    /// expected outcome, not a failure.
    func tidyEmptyCaches() async {
        let entries = emptyCaches
        guard !entries.isEmpty else { return }

        let urls = entries.map(\.url)
        let outcome = await Background.run { TrashService.trash(urls) }

        let trashed = Set(outcome.trashed)
        emptyCaches.removeAll { trashed.contains($0.url) }
        report(outcome)
    }

    func clearError() { failure = nil }

    private func report(_ outcome: TrashService.Outcome) {
        guard !outcome.didFullySucceed else {
            failure = nil
            return
        }

        // A refused write is a fact about this Mac's settings, not about the items, so it
        // gets its own explanation and its own way out rather than a list of file names
        // each repeating the same underlying cause.
        if outcome.needsFullDiskAccess {
            diskAccess = .denied
            let count = outcome.blockedURLs.count
            failure = TrashFailure(
                message: """
                    macOS blocked \(count) item\(count == 1 ? "" : "s"). Cruft/Check can find \
                    these but can't remove them without Full Disk Access.

                    Grant it in System Settings and run the scan again — or reveal them in \
                    Finder and move them to the Trash yourself, which works right now.
                    """,
                needsFullDiskAccess: true,
                blockedURLs: outcome.blockedURLs
            )
            return
        }

        failure = TrashFailure(
            message: outcome.failures
                .map { "\($0.url.lastPathComponent): \($0.message)" }
                .joined(separator: "\n"),
            needsFullDiskAccess: false
        )
    }
}
