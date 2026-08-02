import Foundation
import Testing
@testable import CruftCheck

/// Names are a weaker signal than bundle identifiers, so this matcher is only ever used to
/// withhold a claim. Every test here is therefore about it staying quiet: a folder it fails
/// to match gets a badge, and a badge on something an installed app owns is the failure.
@Suite("Installed app names")
struct InstalledAppNamesTests {

    private let index = InstalledAppNames(
        appNames: ["Proxyman", "Google Chrome", "Sublime Text", "GoLand", "Visual Studio Code"],
        identifiers: ["com.google.chrome", "com.jetbrains.goland", "fr.handbrake.handbrake"]
    )

    // MARK: - Rules that spare

    @Test("An exact name match is claimed")
    func claimsExactName() {
        #expect(index.claims("Proxyman"))
    }

    @Test("A word inside a longer app name is claimed")
    func claimsWordWithinName() {
        // ~/Library/Caches/Google belongs to Google Chrome.app.
        #expect(index.claims("Google"))
        #expect(index.claims("Chrome"))
    }

    @Test("A vendor token from any installed identifier is claimed")
    func claimsVendorToken() {
        // No app is called "handbrake" outright; the identifier is the only link.
        #expect(index.claims("handbrake"))
        #expect(index.claims("handbrake-nightly-logs"))
    }

    @Test("A folder name extending an app name is claimed")
    func claimsPrefixExtension() {
        #expect(index.claims("Sublime Text 4"))
    }

    @Test("Case and punctuation are ignored")
    func normalisesAggressively() {
        #expect(index.claims("google-chrome"))
        #expect(index.claims("SUBLIME TEXT"))
        #expect(index.claims("visual_studio_code"))
    }

    /// The case that made the vendor rule worth having: a Firebase artifact whose name is
    /// nothing like any app, but whose first word matches an installed vendor.
    @Test("Regression: google-sdks-events is claimed by an installed Google app")
    func claimsGoogleSDKFolder() {
        #expect(index.claims("google-sdks-events"))
    }

    // MARK: - Rules that don't

    @Test("A name matching nothing installed is not claimed")
    func doesNotClaimUnknownName() {
        #expect(!index.claims("Proxyfoo"))
        #expect(!index.claims("Cypress"))
    }

    /// Without a length floor, two letters prefix half of /Applications and the matcher
    /// spares everything — safe, but useless.
    @Test("Short names don't prefix-match their way to a claim")
    func enforcesPrefixFloor() {
        #expect(!index.claims("Go"), "Go must not be claimed by GoLand")
    }

    // MARK: - The failure that matters most

    /// An empty index means the bundle sweep found nothing — a failure, or a sandbox. It
    /// must not read as "nothing is installed", which would badge the entire Library.
    @Test("An empty index claims everything rather than nothing")
    func emptyIndexStaysSilent() {
        let empty = InstalledAppNames()

        #expect(empty.claims("Proxyman"))
        #expect(empty.claims("literally anything"))
    }

    @Test("A folder with no alphanumerics is claimed rather than judged")
    func unjudgeableNameIsClaimed() {
        #expect(index.claims("..."))
        #expect(index.claims(""))
    }
}

/// Discovery decides which vendors count as installed, and a vendor it misses is a vendor
/// whose helpers get flagged as orphans. Every test here is about reaching further.
@Suite("Installed app discovery")
struct AppBundleDiscoveryTests {

    private func makeTree(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "CruftCheckApps-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeApp(_ path: String, in root: URL) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url.appending(path: "Contents/MacOS", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        return url
    }

    /// Two levels was the old limit, and it missed real installations: Adobe nests under
    /// a vendor folder inside a suite folder, and Setapp keeps a catalogue directory.
    @Test("Apps are found several folders deep, not just one")
    func findsDeeplyNestedApps() throws {
        try makeTree { root in
            _ = try makeApp("Top.app", in: root)
            _ = try makeApp("Vendor/Nested.app", in: root)
            _ = try makeApp("Adobe Creative Cloud/Photoshop 2025/Photoshop.app", in: root)

            let found = Set(AppBundleIndex.appBundles(in: root).map(\.lastPathComponent))

            #expect(found == ["Top.app", "Nested.app", "Photoshop.app"])
        }
    }

    /// Helper apps inside Contents/ aren't separately installed, and treating them as such
    /// would inflate the vendor set with identifiers no user ever chose to install.
    @Test("Helpers nested inside an app bundle are not collected separately")
    func doesNotDescendIntoAppBundles() throws {
        try makeTree { root in
            let parent = try makeApp("Parent.app", in: root)
            _ = try makeApp("Contents/Library/LoginItems/Helper.app", in: parent)

            let found = AppBundleIndex.appBundles(in: root).map(\.lastPathComponent)

            #expect(found == ["Parent.app"])
        }
    }

    /// /Applications routinely holds links to other volumes. Following them risks loops and
    /// long stalls on network mounts.
    @Test("Symlinked directories are skipped rather than followed")
    func skipsSymlinks() throws {
        try makeTree { root in
            let real = root.appending(path: "Real", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            _ = try makeApp("Real/Hidden.app", in: root)

            // A link back to the root would loop forever if followed.
            try FileManager.default.createSymbolicLink(
                at: root.appending(path: "Loop", directoryHint: .isDirectory),
                withDestinationURL: root
            )

            let found = AppBundleIndex.appBundles(in: root).map(\.lastPathComponent)

            #expect(found == ["Hidden.app"])
        }
    }

    @Test("Depth is bounded")
    func stopsAtTheDepthLimit() throws {
        try makeTree { root in
            _ = try makeApp("a/b/c/d/e/TooDeep.app", in: root)

            #expect(AppBundleIndex.appBundles(in: root, depth: 2).isEmpty)
        }
    }
}

@Suite("Staleness phrasing")
struct StalenessTests {

    @Test("No date yields no month count")
    func noDateNoMonths() {
        #expect(Staleness.months(since: nil) == nil)
    }

    @Test("Durations coarsen as they lengthen")
    func phrasesDurations() {
        #expect(Staleness.duration(months: 5) == "5 months")
        #expect(Staleness.duration(months: 12) == "over a year")
        #expect(Staleness.duration(months: 23) == "over a year")
        #expect(Staleness.duration(months: 24) == "2 years")
        #expect(Staleness.duration(months: 40) == "3 years")
    }
}
