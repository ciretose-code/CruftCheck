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

    /// Every bundle identifier found in the standard application directories.
    static func installedIdentifiers() -> Set<String> {
        var identifiers: Set<String> = []

        for root in searchRoots {
            for appURL in appBundles(in: root) {
                if let id = Bundle(url: appURL)?.bundleIdentifier {
                    identifiers.insert(id.lowercased())
                }
            }
        }

        return identifiers
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

    /// `.app` bundles one level down, plus one nested level so folders like
    /// "/Applications/Adobe Photoshop 2024/Photoshop.app" are seen.
    private static func appBundles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for entry in entries {
            if entry.pathExtension == "app" {
                results.append(entry)
            } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let nested = (try? fileManager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                results.append(contentsOf: nested.filter { $0.pathExtension == "app" })
            }
        }
        return results
    }
}
