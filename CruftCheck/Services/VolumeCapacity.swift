import Foundation

/// The size of the volume `~/Library` lives on.
///
/// Exists to give the reclaimable figure a denominator. On its own "2.34 GB" has no scale —
/// it could be most of the disk or a rounding error, and nothing else on screen says which.
///
/// Cheap and prompt-free, unlike measuring the directories the scan deliberately skips: one
/// `resourceValues` call against the home directory's volume. TCC has no opinion about
/// volume capacity, so this costs nothing and raises nothing, with or without Full Disk
/// Access.
///
/// It does *not* reveal how much the unmeasured system caches hold — that stays folded into
/// `used`, because the app still refuses to walk them. What it does is stop the app quoting
/// a number with no frame of reference.
struct VolumeCapacity: Equatable, Sendable {
    var total: UInt64
    var available: UInt64

    var used: UInt64 { total > available ? total - available : 0 }

    /// What fraction of the volume `bytes` represents, clamped to a sane range.
    func share(of bytes: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(bytes) / Double(total))
    }

    /// `nil` when the volume won't answer — an unusual filesystem, or a home directory on
    /// something that doesn't report capacity. The UI omits the bar rather than guessing.
    static func current(for directory: URL? = nil) -> VolumeCapacity? {
        let url = directory ?? FileManager.default.homeDirectoryForCurrentUser

        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return nil }

        // "Important usage" is the figure Finder shows: it counts space macOS would free by
        // evicting purgeable content, which is what the user will actually get back.
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage,
              total > 0
        else { return nil }

        return VolumeCapacity(
            total: UInt64(max(0, total)),
            available: UInt64(max(0, available))
        )
    }
}
