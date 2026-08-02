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
