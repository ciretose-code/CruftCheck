import Foundation
import Testing
@testable import CruftCheck

@Suite("Cache Diet")
struct CacheDietTests {

    @Test("Caches and Logs are both scanned, largest first")
    func sortsDescendingAcrossDomains() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.caches, "Small", bytes: 1_024)
            try fixture.makeBundleDirectory(.caches, "Huge", bytes: 400_000)
            try fixture.makeBundleDirectory(.logs, "Medium", bytes: 60_000)

            let scan = LibraryScanner.scanCaches(in: fixture.library)

            #expect(scan.entries.map(\.name) == ["Huge", "Medium", "Small"])
            #expect(scan.entries.map(\.domain) == [.caches, .logs, .caches])
        }
    }

    // MARK: - Splitting the tail off the list

    private func entries(_ sizes: [UInt64]) -> [CacheEntry] {
        sizes.enumerated().map { index, bytes in
            CacheEntry(
                url: URL(fileURLWithPath: "/tmp/cache-\(index)"),
                domain: .caches,
                bytes: bytes
            )
        }
    }

    /// The shape that motivated the split: two rows holding 94% of the total, and a tail
    /// whose bars would every one of them draw at the minimum width.
    @Test("A heavy tail is grouped away from the rows that hold the space")
    func groupsHeavyTail() {
        let split = TailSplit(entries([
            1_060_000_000, 1_060_000_000, 127_300_000,
            4_800_000, 4_800_000, 520_000, 438_000, 385_000, 283_000
        ]), bytes: \.bytes)

        #expect(split.major.map(\.bytes) == [1_060_000_000, 1_060_000_000, 127_300_000])
        #expect(split.tail.count == 6)
        #expect(split.tailBytes == 11_226_000)
    }

    @Test("A tail too small to be worth a disclosure is left in place")
    func doesNotGroupATinyTail() {
        // Only the last row falls under 1%, and hiding one row behind a click saves nothing.
        let split = TailSplit(entries([500_000_000, 400_000_000, 100_000_000, 1_000]), bytes: \.bytes)

        #expect(split.tail.isEmpty)
        #expect(split.major.count == 4)
    }

    /// A flat distribution puts every row under the threshold — a hundred equal items are
    /// 1% each — which must not collapse the entire list behind one disclosure.
    @Test("A flat distribution still shows rows")
    func keepsMinimumVisibleRows() {
        let split = TailSplit(entries(Array(repeating: 1_000, count: 200)), bytes: \.bytes)

        #expect(split.major.count == TailSplitRule.minimumMajorRows)
        #expect(split.tail.count == 200 - TailSplitRule.minimumMajorRows)
    }

    @Test("An empty list splits into nothing rather than trapping")
    func handlesEmptyList() {
        let split = TailSplit([CacheEntry](), bytes: \.bytes)

        #expect(split.major.isEmpty)
        #expect(split.tail.isEmpty)
        #expect(split.tailBytes == 0)
    }

    /// Everything measuring zero gives no total to take a share of. Show them rather than
    /// divide by it.
    @Test("A list totalling zero is left whole")
    func handlesZeroTotal() {
        let split = TailSplit(entries([0, 0, 0, 0, 0]), bytes: \.bytes)

        #expect(split.major.count == 5)
        #expect(split.tail.isEmpty)
    }

    @Test("Splitting never loses or duplicates an entry")
    func splitIsAPartition() {
        let sizes: [UInt64] = [900_000_000, 90_000_000, 9_000_000, 900_000, 90_000, 9_000, 900]
        let split = TailSplit(entries(sizes), bytes: \.bytes)

        #expect(split.major.count + split.tail.count == sizes.count)
        #expect((split.major + split.tail).map(\.bytes) == sizes)
    }

    // MARK: - Empty entries
    //
    // A row that can free nothing can't help the user choose, so it's kept out of the main
    // list — but it is kept, because the count has to stay honest and the tidy action needs
    // something to act on.

    @Test("Zero-byte entries are partitioned out of the main list")
    func partitionsEmptyEntries() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.caches, "HasData", bytes: 4_096)
            try fixture.makeBundleDirectory(.caches, "Hollow", bytes: 0)
            try fixture.makeBundleDirectory(.logs, "AlsoHollow", bytes: 0)

            let scan = LibraryScanner.scanCaches(in: fixture.library)

            #expect(scan.entries.map(\.name) == ["HasData"])
            #expect(scan.emptyEntries.map(\.name) == ["AlsoHollow", "Hollow"])
        }
    }

    @Test("An empty entry is never counted as a skipped system item")
    func emptyIsNotSkipped() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.caches, "Hollow", bytes: 0)

            let scan = LibraryScanner.scanCaches(in: fixture.library)

            #expect(scan.emptyEntries.count == 1)
            #expect(scan.skippedSystemItems == 0)
        }
    }

    /// A directory holding only empty subdirectories measures zero — `DirectorySizer`
    /// counts regular files only — so it belongs with the empties, not the main list.
    @Test("A directory of empty subdirectories counts as empty")
    func nestedEmptyDirectoriesAreEmpty() throws {
        try withLibraryFixture { fixture in
            let root = fixture.library.directory(for: .caches).appending(path: "Shell", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: root.appending(path: "a/b", directoryHint: .isDirectory))

            let scan = LibraryScanner.scanCaches(in: fixture.library)

            #expect(scan.entries.isEmpty)
            #expect(scan.emptyEntries.map(\.name) == ["Shell"])
        }
    }

    @Test("System caches are never offered for tidying either")
    func emptySystemCachesStayHidden() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.caches, "GameKit", bytes: 0)

            let scan = LibraryScanner.scanCaches(in: fixture.library)

            #expect(scan.entries.isEmpty)
            #expect(scan.emptyEntries.isEmpty, "a protected name must not reach the tidy list")
            #expect(scan.skippedSystemItems == 1)
        }
    }

    /// Regression: measuring Apple's caches raises a TCC prompt ("would like to access
    /// Apple Music…") for directories the app would never offer to delete. They must be
    /// filtered out before sizing, not merely disabled in the UI.
    @Test("System caches are skipped before they are ever opened", arguments: [
        "com.apple.Music", "AMSDataMigratorTool", "PassKit", "GameKit", "GeoServices", "Animoji"
    ])
    func skipsSystemCaches(name: String) throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.caches, name, bytes: 100_000)
            try fixture.makeBundleDirectory(.caches, "com.acme.Widget", bytes: 2_048)

            let scan = LibraryScanner.scanCaches(in: fixture.library)

            #expect(scan.entries.map(\.name) == ["com.acme.Widget"])
            #expect(scan.skippedSystemItems == 1)
        }
    }

    @Test("Skipped items are counted, not silently dropped")
    func reportsSkippedCount() throws {
        try withLibraryFixture { fixture in
            for name in ["com.apple.Music", "com.apple.helpd", "PassKit"] {
                try fixture.makeBundleDirectory(.caches, name)
            }
            try fixture.makeBundleDirectory(.caches, "Homebrew")

            let scan = LibraryScanner.scanCaches(in: fixture.library)

            #expect(scan.skippedSystemItems == 3)
            #expect(scan.entries.count == 1)
        }
    }

    @Test("Progress is reported once per measured item")
    func reportsProgress() throws {
        try withLibraryFixture { fixture in
            for index in 0..<5 {
                try fixture.makeBundleDirectory(.caches, "app\(index)")
            }

            var ticks: [ScanProgress] = []
            _ = LibraryScanner.scanCaches(in: fixture.library, onProgress: { ticks.append($0) })

            #expect(ticks.count == 5)
            #expect(ticks.map(\.completed) == [1, 2, 3, 4, 5])
            #expect(ticks.allSatisfy { $0.total == 5 })
            #expect(ticks.last?.fraction == 1.0)
        }
    }

    @Test("A cancelled scan returns without measuring")
    func honoursCancellation() throws {
        try withLibraryFixture { fixture in
            for index in 0..<20 {
                try fixture.makeBundleDirectory(.caches, "app\(index)", bytes: 50_000)
            }

            let scan = LibraryScanner.scanCaches(in: fixture.library, isCancelled: { true })

            #expect(scan.entries.isEmpty)
        }
    }

    /// The flag has to be readable from a plain dispatch queue, where `Task.isCancelled`
    /// is always false — the bug this type exists to prevent.
    @Test("CancellationFlag is visible across threads")
    func cancellationFlagCrossesThreads() async {
        let flag = CancellationFlag()
        #expect(!flag.isCancelled)

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                flag.cancel()
                continuation.resume()
            }
        }

        #expect(flag.isCancelled)
    }
}
