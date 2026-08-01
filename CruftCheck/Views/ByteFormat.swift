import Foundation

/// One formatter for the whole app, so "1.2 GB" never renders as "1,234,567,890 bytes"
/// in one view and something else in another.
enum ByteFormat {
    /// File-style (base 10) units, matching what Finder shows for the same folder.
    static func string(_ bytes: UInt64) -> String {
        bytes.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: false))
    }
}
