import Foundation
import Testing
@testable import CruftCheck

/// The Orphan Hunt is the mode that can cost a user working software, so these tests are
/// weighted toward the ways it could wrongly flag something rather than toward coverage.
@Suite("Orphan Hunt")
struct OrphanHuntTests {

    // MARK: - Identifier extraction

    @Test("Reverse-DNS directory names are recognised")
    func recognisesBundleIdentifiers() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.applicationSupport, "com.acme.Widget")

            let candidates = LibraryScanner.collectOrphanCandidates(in: fixture.library)

            #expect(candidates.map(\.bundleID) == ["com.acme.Widget"])
        }
    }

    @Test("Preferences plists yield the identifier without the extension")
    func stripsPlistExtension() throws {
        try withLibraryFixture { fixture in
            try fixture.makeFile(.preferences, "com.acme.Widget.plist")
            try fixture.makeFile(.preferences, "com.acme.Other.plist.lockfile")

            let ids = Set(LibraryScanner.collectOrphanCandidates(in: fixture.library).map(\.bundleID))

            #expect(ids == ["com.acme.Widget", "com.acme.Other"])
        }
    }

    @Test("ByHost preferences drop the trailing hardware UUID")
    func stripsByHostUUID() throws {
        try withLibraryFixture { fixture in
            try fixture.makeByHostFile("com.acme.Widget.6F1B2C3D-4E5F-6789-ABCD-EF0123456789.plist")

            let ids = LibraryScanner.collectOrphanCandidates(in: fixture.library).map(\.bundleID)

            #expect(ids == ["com.acme.Widget"])
        }
    }

    @Test("Group containers are attributed to the owning app")
    func normalisesGroupPrefix() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.containers, "group.com.acme.Widget")

            let ids = LibraryScanner.collectOrphanCandidates(in: fixture.library).map(\.bundleID)

            #expect(ids == ["com.acme.Widget"])
        }
    }

    @Test("Human-named folders are never candidates", arguments: [
        "Google", "Sublime Text 4", "Adobe.Setup", "MobileSync", "CrashReporter", "firefox"
    ])
    func ignoresNonIdentifierNames(name: String) throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.applicationSupport, name)

            let candidates = LibraryScanner.collectOrphanCandidates(in: fixture.library)

            #expect(candidates.isEmpty, "\(name) must not be treated as a bundle identifier")
        }
    }

    // MARK: - Protected identifiers

    @Test("System identifiers are never candidates", arguments: [
        "com.apple.Music",
        "com.apple.iTunes.something",
        "group.com.apple.notes",
        "systemgroup.com.apple.icloud.searchpartyd.sharedsettings",
        "org.cups.PrintingPrefs",
        "org.swift.swiftpm"
    ])
    func neverFlagsSystemIdentifiers(name: String) throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.containers, name)

            let candidates = LibraryScanner.collectOrphanCandidates(in: fixture.library)

            #expect(candidates.isEmpty, "\(name) is system-owned and must never be offered")
        }
    }

    /// Regression: `systemgroup.com.apple.…` slipped past the `com.apple.` guard, because
    /// the guard ran against the raw name and only the `group.` prefix was stripped.
    @Test("Regression: systemgroup identifiers are protected")
    func systemGroupRegression() {
        #expect(LibraryPaths.isProtected(name: "systemgroup.com.apple.icloud.searchpartyd.sharedsettings"))
        #expect(LibraryPaths.bundleIdentifier(
            from: URL(fileURLWithPath: "/tmp/systemgroup.com.apple.icloud.searchpartyd.sharedsettings")
        ) == nil)
    }

    // MARK: - The installed-software rule

    @Test("An app that is gone is flagged")
    func flagsGenuineOrphan() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.applicationSupport, "com.dead.Ghost")

            let candidates = LibraryScanner.collectOrphanCandidates(in: fixture.library)
            let orphans = LibraryScanner.orphans(
                among: candidates,
                presence: .fake(installed: ["com.live.Other"])
            )

            #expect(orphans.map(\.bundleID) == ["com.dead.Ghost"])
        }
    }

    @Test("An installed app is not flagged")
    func skipsInstalledApp() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.applicationSupport, "com.acme.Widget")

            let orphans = LibraryScanner.orphans(
                among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                presence: .fake(installed: ["com.acme.Widget"])
            )

            #expect(orphans.isEmpty)
        }
    }

    @Test("A helper is not flagged when its parent app is installed")
    func skipsHelperOfInstalledApp() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.containers, "com.acme.Widget.Helper")

            let orphans = LibraryScanner.orphans(
                among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                presence: .fake(installed: ["com.acme.Widget"])
            )

            #expect(orphans.isEmpty, "helper identifiers must resolve through their parent")
        }
    }

    /// Regression: HandBrake ships `fr.handbrake.HandBrakeXPCService`, whose identifier is
    /// not a suffix of the app's `fr.handbrake.HandBrake`, so prefix-walking alone missed it
    /// and the XPC service's container was offered for deletion.
    @Test("Regression: XPC services sharing a vendor with an installed app are not flagged")
    func skipsXPCServiceOfInstalledVendor() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.containers, "fr.handbrake.HandBrakeXPCService")
            try fixture.makeBundleDirectory(.containers, "fr.handbrake.sparkle-project.DownloaderService")

            let orphans = LibraryScanner.orphans(
                among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                presence: .fake(installed: ["fr.handbrake.HandBrake"], vendorPrefixes: ["fr.handbrake"])
            )

            #expect(orphans.isEmpty)
        }
    }

    @Test("A vendor with nothing installed is still flagged")
    func vendorSuppressionIsNotBlanket() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.containers, "fr.handbrake.HandBrakeXPCService")

            let orphans = LibraryScanner.orphans(
                among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                presence: .fake(installed: [], vendorPrefixes: ["com.google"])
            )

            #expect(orphans.map(\.bundleID) == ["fr.handbrake.HandBrakeXPCService"])
        }
    }

    // MARK: - Evidence
    //
    // The evidence exists to be shown to the user as justification, so the thing worth
    // testing is that it never claims a check that didn't run or couldn't apply.

    @Test("A verdict of installed carries no evidence")
    func installedHasNoEvidence() {
        let presence = AppPresence.fake(installed: ["com.acme.Widget"])

        #expect(presence.verdict(for: "com.acme.Widget") == .installed)
    }

    @Test("A plain orphan records only the Launch Services and vendor checks")
    func evidenceForPlainOrphan() throws {
        let presence = AppPresence.fake(installed: [], vendorPrefixes: ["com.google"])

        guard case .orphaned(let evidence) = presence.verdict(for: "com.dead.Ghost") else {
            Issue.record("expected com.dead.Ghost to be orphaned")
            return
        }

        // Three components means no ancestors exist, so no ancestor check is claimed.
        #expect(evidence.checks == [
            .noLaunchServicesMatch,
            .noInstalledVendor(prefix: "com.dead")
        ])
    }

    @Test("A helper identifier records the ancestors that were tested")
    func evidenceNamesTestedAncestors() throws {
        let presence = AppPresence.fake(installed: [])

        guard case .orphaned(let evidence) = presence.verdict(for: "com.dead.Ghost.Helper") else {
            Issue.record("expected the helper to be orphaned")
            return
        }

        #expect(evidence.checks == [
            .noLaunchServicesMatch,
            .noInstalledAncestor(checked: ["com.dead.Ghost"]),
            .noInstalledVendor(prefix: "com.dead")
        ])
    }

    /// The evidence must not outrun the rule: once a clause spares an identifier, no later
    /// clause runs, so no later check may appear in a verdict.
    @Test("Evidence is never recorded for a check the rule short-circuited past")
    func evidenceStopsWhereTheRuleStops() {
        // Vendor is installed, so the identifier is spared before any evidence is returned.
        let spared = AppPresence.fake(installed: [], vendorPrefixes: ["fr.handbrake"])
        #expect(spared.verdict(for: "fr.handbrake.HandBrakeXPCService") == .installed)

        // Parent installed: spared at the ancestor clause, never reaching the vendor clause.
        let viaParent = AppPresence.fake(installed: ["com.acme.Widget"])
        #expect(viaParent.verdict(for: "com.acme.Widget.Helper") == .installed)
    }

    @Test("Grouping carries the evidence onto the group")
    func groupCarriesEvidence() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.applicationSupport, "com.dead.Ghost")
            try fixture.makeBundleDirectory(.caches, "com.dead.Ghost")

            let groups = LibraryScanner.group(
                LibraryScanner.orphans(
                    among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                    presence: .fake(installed: [])
                )
            )

            let group = try #require(groups.first)
            #expect(group.paths.count == 2)
            #expect(group.evidence.checks.contains(.noLaunchServicesMatch))
            #expect(group.evidence.checks.contains(.noInstalledVendor(prefix: "com.dead")))
        }
    }

    @Test("Every check produces a non-empty label")
    func checksAreLabelled() {
        let checks: [OrphanEvidence.Check] = [
            .noLaunchServicesMatch,
            .noInstalledAncestor(checked: ["com.acme.Widget"]),
            .noInstalledAncestor(checked: ["com.acme.Widget.Sub", "com.acme.Widget"]),
            .noInstalledVendor(prefix: "com.acme")
        ]

        for check in checks {
            #expect(!check.label.isEmpty)
        }
    }

    // MARK: - Staleness
    //
    // This label is shown next to the evidence chips, so a wrong or over-confident one
    // reads as justification for deleting something. The absent cases matter most.

    private func group(monthsAgo months: Int?) -> OrphanGroup {
        let date = months.map { Calendar.current.date(byAdding: .month, value: -$0, to: .now)! }
        return OrphanGroup(
            bundleID: "com.dead.Ghost",
            paths: [OrphanPath(
                url: URL(fileURLWithPath: "/tmp/ghost"),
                domain: .applicationSupport,
                bytes: 1,
                lastModified: date
            )]
        )
    }

    @Test("No readable date means no staleness claim")
    func noDateMeansNoLabel() {
        #expect(group(monthsAgo: nil).lastModified == nil)
        #expect(group(monthsAgo: nil).stalenessLabel == nil)
    }

    /// An app uninstalled last week leaves recent files behind. Reporting "Untouched 1
    /// month" there would be a number the user has to know to discount.
    @Test("A recent date is not reported as staleness", arguments: [0, 1, 2])
    func recentIsNotReported(months: Int) {
        #expect(group(monthsAgo: months).stalenessLabel == nil)
    }

    @Test("Months are reported once they're worth reporting")
    func reportsMonths() {
        #expect(group(monthsAgo: 3).stalenessLabel == "Untouched 3 months")
        #expect(group(monthsAgo: 11).stalenessLabel == "Untouched 11 months")
    }

    @Test("A year or more collapses to a coarser phrase")
    func reportsYears() {
        #expect(group(monthsAgo: 12).stalenessLabel == "Untouched over a year")
        #expect(group(monthsAgo: 23).stalenessLabel == "Untouched over a year")
        #expect(group(monthsAgo: 24).stalenessLabel == "Untouched 2 years")
        #expect(group(monthsAgo: 40).stalenessLabel == "Untouched 3 years")
    }

    @Test("A group's date is the newest across all of its leftovers")
    func groupTakesNewestDate() throws {
        let old = Date(timeIntervalSinceNow: -400 * 86_400)
        let recent = Date(timeIntervalSinceNow: -10 * 86_400)

        let group = OrphanGroup(bundleID: "com.dead.Ghost", paths: [
            OrphanPath(url: URL(fileURLWithPath: "/tmp/a"), domain: .caches, bytes: 1, lastModified: old),
            OrphanPath(url: URL(fileURLWithPath: "/tmp/b"), domain: .preferences, bytes: 1, lastModified: recent),
            OrphanPath(url: URL(fileURLWithPath: "/tmp/c"), domain: .containers, bytes: 1, lastModified: nil)
        ])

        #expect(group.lastModified == recent)
        // One still-active leftover is enough to withdraw the claim entirely.
        #expect(group.stalenessLabel == nil)
    }

    @Test("Scanning carries a date onto every orphan path")
    func scanRecordsDates() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.applicationSupport, "com.dead.Ghost")

            let groups = LibraryScanner.group(
                LibraryScanner.orphans(
                    among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                    presence: .fake(installed: [])
                )
            )

            let group = try #require(groups.first)
            #expect(group.paths.allSatisfy { $0.lastModified != nil })
        }
    }

    // MARK: - Grouping

    @Test("Leftovers across domains collapse into one group with a summed size")
    func groupsAcrossDomains() throws {
        try withLibraryFixture { fixture in
            let support = try fixture.makeBundleDirectory(.applicationSupport, "com.dead.Ghost", bytes: 4_096)
            let caches = try fixture.makeBundleDirectory(.caches, "com.dead.Ghost", bytes: 8_192)
            let prefs = try fixture.makeFile(.preferences, "com.dead.Ghost.plist", bytes: 512)

            let groups = LibraryScanner.group(
                LibraryScanner.orphans(
                    among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                    presence: .fake(installed: [])
                )
            )

            #expect(groups.count == 1)
            let group = try #require(groups.first)
            #expect(group.bundleID == "com.dead.Ghost")
            #expect(group.paths.count == 3)
            #expect(Set(group.paths.map(\.domain)) == [.applicationSupport, .caches, .preferences])

            let expected = fixture.allocatedSize(of: [
                support.appending(path: "payload.bin"),
                caches.appending(path: "payload.bin"),
                prefs
            ])
            #expect(group.bytes == expected)
        }
    }

    @Test("Groups are ordered largest first")
    func sortsGroupsBySize() throws {
        try withLibraryFixture { fixture in
            try fixture.makeBundleDirectory(.applicationSupport, "com.dead.Small", bytes: 1_024)
            try fixture.makeBundleDirectory(.applicationSupport, "com.dead.Large", bytes: 200_000)
            try fixture.makeBundleDirectory(.applicationSupport, "com.dead.Medium", bytes: 50_000)

            let groups = LibraryScanner.group(
                LibraryScanner.orphans(
                    among: LibraryScanner.collectOrphanCandidates(in: fixture.library),
                    presence: .fake(installed: [])
                )
            )

            #expect(groups.map(\.bundleID) == ["com.dead.Large", "com.dead.Medium", "com.dead.Small"])
        }
    }

    @Test("Display name is the last identifier component")
    func derivesDisplayName() {
        let group = OrphanGroup(bundleID: "com.acme.WidgetPro", paths: [])
        #expect(group.displayName == "WidgetPro")
    }
}
