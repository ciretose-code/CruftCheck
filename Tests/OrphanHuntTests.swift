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
