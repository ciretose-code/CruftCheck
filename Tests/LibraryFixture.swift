import Foundation
@testable import CruftCheck

/// A synthetic ~/Library in a temporary directory.
///
/// Lets the scanners be pointed at a Library whose contents are known exactly, instead of
/// the tester's real one — where the interesting cases (an app that is genuinely gone, an
/// XPC helper of an app that is still present) only appear by luck.
struct LibraryFixture {
    let root: URL
    let library: LibraryRoot

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "CruftCheckTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        library = LibraryRoot(url: root.appending(path: "Library", directoryHint: .isDirectory))

        for domain in LibraryDomain.allCases {
            try FileManager.default.createDirectory(
                at: library.directory(for: domain),
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Building

    /// Creates `<domain>/<name>/` containing one file of `bytes` bytes.
    @discardableResult
    func makeBundleDirectory(_ domain: LibraryDomain, _ name: String, bytes: Int = 1024) throws -> URL {
        let directory = library.directory(for: domain).appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFile(at: directory.appending(path: "payload.bin"), bytes: bytes)
        return directory
    }

    /// Creates a bare file such as `Preferences/com.acme.Widget.plist`.
    @discardableResult
    func makeFile(_ domain: LibraryDomain, _ name: String, bytes: Int = 512) throws -> URL {
        let url = library.directory(for: domain).appending(path: name)
        try writeFile(at: url, bytes: bytes)
        return url
    }

    /// Creates `Preferences/ByHost/<name>`.
    @discardableResult
    func makeByHostFile(_ name: String, bytes: Int = 256) throws -> URL {
        let byHost = library.directory(for: .preferences).appending(path: "ByHost", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: byHost, withIntermediateDirectories: true)
        let url = byHost.appending(path: name)
        try writeFile(at: url, bytes: bytes)
        return url
    }

    func makeDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeFile(at url: URL, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    func makeSymlink(at url: URL, pointingTo destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    func setPosixPermissions(_ mode: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    func setModified(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    /// Backdates an entire tree, deepest entries first.
    ///
    /// Order matters: writing a child's timestamp bumps its parent directory's, so parents
    /// have to be set last or they end up looking newer than everything inside them.
    func backdate(_ url: URL, to date: Date) throws {
        var items: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator { items.append(child) }
        }

        for item in items.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            try setModified(item, to: date)
        }
        try setModified(url, to: date)
    }

    // MARK: - Measuring

    /// Allocated size of specific files, computed independently of `DirectorySizer` so the
    /// expectation isn't just the implementation restated. Block rounding and APFS
    /// compression make literal byte counts meaningless, so the tests compare against this.
    func allocatedSize(of files: [URL]) -> UInt64 {
        files.reduce(into: UInt64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total &+= UInt64(max(0, bytes))
        }
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Creates a fixture, runs `body`, and always tears the temp directory down.
func withLibraryFixture(_ body: (LibraryFixture) throws -> Void) throws {
    let fixture = try LibraryFixture()
    defer { fixture.destroy() }
    try body(fixture)
}
