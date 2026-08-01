import Foundation

/// The rule that decides whether a bundle identifier still belongs to installed software.
///
/// Extracted from `InstalledAppIndex` so the rule is one testable value rather than
/// something welded to `NSWorkspace`. The production path supplies a `resolve` backed by
/// LaunchServices; tests supply a set of pretend-installed identifiers.
///
/// Deliberately biased toward answering *true*: this app moves things to the Trash, so a
/// missed orphan costs the user disk space while a false orphan costs them working
/// software. Every clause below is a reason **not** to flag something.
struct AppPresence {
    /// Exact bundle-identifier lookup — LaunchServices in production.
    var resolve: (String) -> Bool
    /// Vendor prefixes ("com.google", "fr.handbrake") of every app bundle on disk.
    var vendorPrefixes: Set<String>

    /// What the rule concluded, and — when it concluded "orphaned" — on what basis.
    enum Verdict: Hashable, Sendable {
        case installed
        case orphaned(OrphanEvidence)
    }

    /// The rule. Every `return .installed` below is a reason **not** to flag something;
    /// reaching the end means all of them declined, and the accumulated checks are the
    /// record of that.
    ///
    /// Clause order and short-circuiting are load-bearing and identical to the `Bool`
    /// version this replaced: a later clause never runs once an earlier one has spared the
    /// identifier, so recording evidence cannot change a verdict.
    func verdict(for bundleID: String) -> Verdict {
        if resolve(bundleID) { return .installed }

        var checks: [OrphanEvidence.Check] = [.noLaunchServicesMatch]

        // "com.acme.Widget.Helper" is not an orphan if "com.acme.Widget" is installed.
        let ancestors = LibraryPaths.ancestorIdentifiers(of: bundleID)
        if ancestors.contains(where: resolve) { return .installed }
        if !ancestors.isEmpty { checks.append(.noInstalledAncestor(checked: ancestors)) }

        // Helpers and XPC services that share a vendor with an installed app —
        // "fr.handbrake.HandBrakeXPCService" while HandBrake.app is present. Their own
        // identifiers never resolve, because they aren't apps.
        if let vendor = AppBundleIndex.vendorPrefix(of: bundleID) {
            if vendorPrefixes.contains(vendor) { return .installed }
            checks.append(.noInstalledVendor(prefix: vendor))
        }

        return .orphaned(OrphanEvidence(checks: checks))
    }

    func isInstalled(_ bundleID: String) -> Bool {
        if case .installed = verdict(for: bundleID) { return true }
        return false
    }

    /// Convenience for tests and previews: everything in `installed` counts as present.
    static func fake(installed: Set<String>, vendorPrefixes: Set<String> = []) -> AppPresence {
        let lowered = Set(installed.map { $0.lowercased() })
        return AppPresence(
            resolve: { lowered.contains($0.lowercased()) },
            vendorPrefixes: vendorPrefixes
        )
    }
}
