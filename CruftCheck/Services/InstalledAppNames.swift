import Foundation

/// Decides whether any installed app plausibly owns a human-named Library folder.
///
/// `AppPresence` can't answer this: a folder called `Proxyman` yields no bundle identifier,
/// so there is nothing to ask LaunchServices about. Names are the only handle available, and
/// names are a weaker signal than identifiers — so this type is used only to *withhold* a
/// claim, never to make one. A folder it fails to match is merely unexplained, not
/// condemned.
///
/// Every rule below is a reason to stay quiet. Matching too eagerly costs a badge that
/// wasn't shown; matching too rarely means labelling a folder that belongs to something
/// installed. The first is invisible, so the rules lean hard that way.
struct InstalledAppNames: Sendable {

    /// Normalised full names — "googlechrome" from "Google Chrome.app".
    var names: Set<String> = []
    /// Every word of every app name — "google", "chrome".
    var words: Set<String> = []
    /// Vendor tokens taken from bundle identifiers — "google" from "com.google.Chrome".
    var vendors: Set<String> = []

    /// Shortest folder name eligible for prefix matching.
    ///
    /// Without a floor, a two-letter folder prefixes half of `/Applications` and the rule
    /// spares everything — which is safe but useless. Four is long enough to mean something.
    private static let minimumPrefixLength = 4

    /// Whether something installed plausibly owns `folderName`.
    func claims(_ folderName: String) -> Bool {
        // No index means no evidence. An empty set must not read as "nothing is installed",
        // or a failed bundle scan would badge the user's entire Library.
        guard !names.isEmpty || !vendors.isEmpty else { return true }

        let normalized = Self.normalize(folderName)
        guard !normalized.isEmpty else { return true }

        // "Proxyman" ↔ Proxyman.app
        if names.contains(normalized) { return true }

        // "Google" ↔ Google Chrome.app
        if words.contains(normalized) { return true }

        // "google-sdks-events" ↔ any com.google.* bundle
        if let first = Self.words(in: folderName).first, vendors.contains(first) { return true }

        // "Sublime Text 4" ↔ Sublime Text.app, and the reverse
        if normalized.count >= Self.minimumPrefixLength {
            for name in names where name.count >= Self.minimumPrefixLength {
                if normalized.hasPrefix(name) || name.hasPrefix(normalized) { return true }
            }
        }

        return false
    }

    // MARK: - Normalisation

    /// Lowercased, with everything that isn't a letter or digit removed, so spacing and
    /// punctuation stop mattering: "Sublime Text 4" and "sublime-text-4" are one string.
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The lowercased alphanumeric words of a name, in order.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Builds the index from what `AppBundleIndex` found on disk.
    init(appNames: Set<String> = [], identifiers: Set<String> = []) {
        names = Set(appNames.map(Self.normalize).filter { !$0.isEmpty })
        words = Set(appNames.flatMap(Self.words))
        vendors = Set(identifiers.compactMap { identifier in
            AppBundleIndex.vendorPrefix(of: identifier)?
                .split(separator: ".")
                .last
                .map(String.init)
        })
    }
}
