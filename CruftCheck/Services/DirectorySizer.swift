import Foundation

/// Computes on-disk sizes for directory trees.
///
/// Everything here is synchronous and free of actor isolation on purpose: the functions
/// are meant to be handed to `Background.run`, never called from the main actor.
enum DirectorySizer {

    /// Resource keys prefetched for every visited URL.
    ///
    /// Passing these to the enumerator means each later `resourceValues(forKeys:)` call is
    /// served from the enumerator's own cache instead of issuing a fresh `stat(2)`. On a
    /// 200k-file Caches folder this is the difference between ~1s and ~15s.
    private static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey
    ]

    /// Total bytes occupied by `url`, recursing through every subdirectory.
    ///
    /// - Parameters:
    ///   - url: A file or directory. Missing paths return 0 rather than throwing —
    ///     cruft disappears between the scan and the sizing pass more often than you'd think.
    ///   - isCancelled: Polled every 512 files so a cancelled scan stops walking a
    ///     multi-gigabyte tree instead of running to completion in the background.
    /// - Returns: Size in bytes. Never throws; unreadable subtrees are skipped and simply
    ///   contribute nothing to the total.
    static func size(of url: URL, isCancelled: () -> Bool = { false }) -> UInt64 {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            return 0
        }

        // A bare file (a stray .plist in Preferences, say) needs no enumerator.
        guard isDirectory.boolValue else { return bytes(at: url) }

        // NSDirectoryEnumerator does not descend into symlinked directories, so a symlink
        // pointing at /Applications can't inflate the total or send us in a loop.
        // The error handler returns `true` to keep walking past permission-denied subtrees
        // (common under ~/Library/Containers without Full Disk Access).
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: UInt64 = 0
        var visited = 0

        for case let fileURL as URL in enumerator {
            visited += 1
            if visited & 0x1FF == 0, isCancelled() { break }
            total &+= bytes(at: fileURL)
        }

        return total
    }

    /// Sizes a batch of roots, reporting each completion so the UI can show real progress.
    ///
    /// - Parameter onProgress: Invoked on the calling (background) queue after each root.
    ///   Callers are responsible for hopping to the main actor before touching UI state.
    static func sizes(
        of urls: [URL],
        isCancelled: () -> Bool = { false },
        onProgress: (ScanProgress) -> Void = { _ in }
    ) -> [URL: UInt64] {
        var results: [URL: UInt64] = [:]
        results.reserveCapacity(urls.count)

        for (index, url) in urls.enumerated() {
            if isCancelled() { break }
            results[url] = size(of: url, isCancelled: isCancelled)
            onProgress(ScanProgress(
                completed: index + 1,
                total: urls.count,
                label: url.lastPathComponent
            ))
        }

        return results
    }

    /// Bytes contributed by a single URL.
    ///
    /// Prefers *allocated* size over logical size: allocated is what the SSD actually
    /// hands back when the file is trashed, and it accounts for block rounding, APFS
    /// compression and sparse files. `fileSize` is the logical length and is only a
    /// fallback for volumes that don't report allocation.
    private static func bytes(at url: URL) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }

        // Directories carry their own inode overhead and symlinks their target path;
        // counting either would double-count or lie. Only regular files contribute.
        guard values.isRegularFile == true else { return 0 }

        if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
            return UInt64(max(0, allocated))
        }
        return UInt64(max(0, values.fileSize ?? 0))
    }
}
