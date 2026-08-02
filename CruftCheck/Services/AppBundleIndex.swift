import Foundation

/// Builds the set of bundle identifiers belonging to apps actually present on disk.
///
/// This exists because `NSWorkspace.urlForApplication(withBundleIdentifier:)` answers the
/// wrong question for helpers. HandBrake ships an XPC service called
/// `fr.handbrake.HandBrakeXPCService`; LaunchServices has no app bundle under that
/// identifier, so a naive lookup calls it an orphan while HandBrake is sitting in
/// /Applications. Comparing *vendor prefixes* catches that whole class.
///
/// Pure Foundation and free of actor isolation, so it runs on the background queue.
enum AppBundleIndex {

    private static let searchRoots: [URL] = {
        let fileManager = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        ]
        roots.append(fileManager.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory))
        return roots
    }()

    /// What one sweep of the application directories found.
    struct Installed: Sendable {
        var identifiers: Set<String> = []
        /// Names as a person would recognise them: the bundle's file name without `.app`,
        /// plus `CFBundleName` when it differs. Human-named Library folders are named after
        /// these, never after identifiers.
        var names: Set<String> = []
    }

    /// Identifiers and names in a single sweep.
    ///
    /// One pass rather than two: opening every `Bundle` in `/Applications` is the expensive
    /// part, and both answers come out of the same open.
    static func installed() -> Installed {
        var result = Installed()

        for root in searchRoots {
            for appURL in appBundles(in: root) {
                result.names.insert(appURL.deletingPathExtension().lastPathComponent)

                guard let bundle = Bundle(url: appURL) else { continue }
                if let id = bundle.bundleIdentifier {
                    result.identifiers.insert(id.lowercased())
                }
                if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
                    result.names.insert(name)
                }
            }
        }

        return result
    }

    /// Every bundle identifier found in the standard application directories.
    static func installedIdentifiers() -> Set<String> {
        installed().identifiers
    }

    /// Vendor prefixes ("com.google", "fr.handbrake") of everything installed.
    ///
    /// Two components is the right granularity: it's the part of a reverse-DNS identifier
    /// that identifies who shipped the software, and helpers always share it with their app.
    static func vendorPrefixes(of identifiers: Set<String>) -> Set<String> {
        Set(identifiers.compactMap(vendorPrefix))
    }

    static func vendorPrefix(of bundleID: String) -> String? {
        let parts = bundleID.lowercased().components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        return parts[0] + "." + parts[1]
    }

    /// How far below a search root to look for `.app` bundles.
    ///
    /// Two levels missed real installations: Adobe nests as
    /// `/Applications/Adobe Creative Cloud/Adobe Photoshop 2025/Photoshop.app`, and Setapp
    /// keeps its catalogue under `/Applications/Setapp`. Missing an app means its helpers
    /// look orphaned, so the cost of stopping too shallow is a false positive — the
    /// expensive direction.
    private static let searchDepth = 4

    /// `.app` bundles beneath `directory`, to `searchDepth` levels.
    ///
    /// Not private so tests can point it at a synthetic tree — the real search roots are
    /// whatever happens to be installed on the machine running the suite.
    static func appBundles(in directory: URL, depth: Int = searchDepth) -> [URL] {
        guard depth > 0 else { return [] }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for entry in entries {
            // An .app is itself a directory. Collect it and stop — recursing inside would
            // find helper apps nested in Contents/, which aren't separately installed.
            if entry.pathExtension == "app" {
                results.append(entry)
                continue
            }

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Symlinks are skipped rather than followed: /Applications routinely holds
            // links to other volumes, and following them risks both loops and long stalls
            // on network mounts.
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { continue }

            results.append(contentsOf: appBundles(in: entry, depth: depth - 1))
        }
        return results
    }
}
