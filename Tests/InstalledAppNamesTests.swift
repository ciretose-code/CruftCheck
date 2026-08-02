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
