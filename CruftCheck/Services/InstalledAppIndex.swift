import AppKit

/// Answers "is an app with this bundle identifier still installed?"
///
/// Pinned to the main actor on purpose. `NSWorkspace` is AppKit, and AppKit is
/// main-actor-isolated under Swift 6 strict concurrency — but that costs us nothing,
/// because the lookup hits an in-memory LaunchServices database rather than the disk.
/// Resolving a few hundred identifiers takes single-digit milliseconds, so the expensive
/// work (enumeration and sizing) stays on the background queue while this one cheap step
/// runs where AppKit requires it.
@MainActor
final class InstalledAppIndex {
    private var cache: [String: Bool] = [:]

    /// Vendor prefixes of every app bundle on disk, supplied by `AppBundleIndex` from the
    /// background queue. Empty until `load(vendorPrefixes:)` is called, in which case the
    /// index simply falls back to the stricter LaunchServices-only behaviour.
    private var vendorPrefixes: Set<String> = []

    func load(vendorPrefixes: Set<String>) {
        self.vendorPrefixes = vendorPrefixes
        cache.removeAll(keepingCapacity: true)
    }

    func reset() { cache.removeAll(keepingCapacity: true) }

    /// The presence rule, backed by this index's LaunchServices cache.
    /// The rule itself lives in `AppPresence` so it can be tested without AppKit.
    var presence: AppPresence {
        AppPresence(resolve: { self.resolves($0) }, vendorPrefixes: vendorPrefixes)
    }

    func isInstalled(_ bundleID: String) -> Bool {
        presence.isInstalled(bundleID)
    }

    private func resolves(_ bundleID: String) -> Bool {
        if let known = cache[bundleID] { return known }

        var installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil

        // Second signal: an app can be running from a location LaunchServices hasn't
        // registered (a fresh build, a disk image). Never call that orphaned.
        if !installed {
            installed = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }

        cache[bundleID] = installed
        return installed
    }
}
