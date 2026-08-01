import Foundation
import Testing
@testable import CruftCheck

@Suite("Directory sizing")
struct DirectorySizerTests {

    @Test("A missing path contributes nothing rather than throwing")
    func missingPathIsZero() {
        let missing = URL(fileURLWithPath: "/tmp/cruftcheck-does-not-exist-\(UUID().uuidString)")
        #expect(DirectorySizer.size(of: missing) == 0)
    }

    // MARK: - Recency

    /// The whole point of walking for the date rather than reading the root's own mtime:
    /// a directory's timestamp doesn't move when a file deep inside it is rewritten.
    @Test("Recency is the newest date in the tree, not the root's own")
    func recencyFindsDeepestChange() throws {
        try withLibraryFixture { fixture in
            let root = fixture.library.directory(for: .caches).appending(path: "deep", directoryHint: .isDirectory)
            let nested = root.appending(path: "a/b", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: nested)
            try fixture.writeFile(at: nested.appending(path: "recent.bin"), bytes: 64)

            let old = Date(timeIntervalSinceNow: -400 * 86_400)
            try fixture.backdate(root, to: old)

            // Now touch one buried file, leaving every directory backdated.
            let recent = Date(timeIntervalSinceNow: -3 * 86_400)
            try fixture.setModified(nested.appending(path: "recent.bin"), to: recent)

            let measured = DirectorySizer.measure(of: root)
            let found = try #require(measured.lastModified)

            #expect(abs(found.timeIntervalSince(recent)) < 2)
        }
    }

    @Test("A wholly untouched tree reports its old date")
    func recencyOfUntouchedTree() throws {
        try withLibraryFixture { fixture in
            let directory = try fixture.makeBundleDirectory(.caches, "com.dead.Ghost")
            let old = Date(timeIntervalSinceNow: -500 * 86_400)
            try fixture.backdate(directory, to: old)

            let measured = DirectorySizer.measure(of: directory)
            let found = try #require(measured.lastModified)

            #expect(abs(found.timeIntervalSince(old)) < 2)
        }
    }

    @Test("A missing path has no date rather than a wrong one")
    func recencyOfMissingPathIsNil() {
        let missing = URL(fileURLWithPath: "/tmp/cruftcheck-does-not-exist-\(UUID().uuidString)")
        #expect(DirectorySizer.measure(of: missing).lastModified == nil)
    }

    @Test("Size is unchanged by measuring recency alongside it")
    func measureAgreesWithSize() throws {
        try withLibraryFixture { fixture in
            let directory = try fixture.makeBundleDirectory(.caches, "com.dead.Ghost", bytes: 5_000)

            #expect(DirectorySizer.measure(of: directory).bytes == DirectorySizer.size(of: directory))
        }
    }

    @Test("An empty directory is zero")
    func emptyDirectoryIsZero() throws {
        try withLibraryFixture { fixture in
            let empty = try fixture.makeBundleDirectory(.caches, "empty", bytes: 0)
            try FileManager.default.removeItem(at: empty.appending(path: "payload.bin"))

            #expect(DirectorySizer.size(of: empty) == 0)
        }
    }

    @Test("Nested files are counted")
    func countsNestedFiles() throws {
        try withLibraryFixture { fixture in
            let root = fixture.library.directory(for: .caches).appending(path: "deep", directoryHint: .isDirectory)
            let nested = root.appending(path: "a/b/c", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: nested)

            let files = [root.appending(path: "top.bin"), nested.appending(path: "bottom.bin")]
            for file in files { try fixture.writeFile(at: file, bytes: 10_000) }

            #expect(DirectorySizer.size(of: root) == fixture.allocatedSize(of: files))
        }
    }

    @Test("Hidden files are counted — plenty of cruft is dot-prefixed")
    func countsHiddenFiles() throws {
        try withLibraryFixture { fixture in
            let root = fixture.library.directory(for: .caches).appending(path: "dotted", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: root)
            let hidden = root.appending(path: ".hidden.bin")
            try fixture.writeFile(at: hidden, bytes: 20_000)

            #expect(DirectorySizer.size(of: root) == fixture.allocatedSize(of: [hidden]))
        }
    }

    /// A symlink to /Applications must not make a 4 KB cache folder look like 40 GB, and
    /// must not risk a cycle.
    @Test("Symlinks are not followed")
    func doesNotFollowSymlinks() throws {
        try withLibraryFixture { fixture in
            let target = fixture.library.directory(for: .caches).appending(path: "target", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: target)
            try fixture.writeFile(at: target.appending(path: "big.bin"), bytes: 500_000)

            let root = fixture.library.directory(for: .caches).appending(path: "linker", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: root)
            let own = root.appending(path: "own.bin")
            try fixture.writeFile(at: own, bytes: 1_000)
            try fixture.makeSymlink(at: root.appending(path: "link"), pointingTo: target)

            #expect(DirectorySizer.size(of: root) == fixture.allocatedSize(of: [own]))
        }
    }

    @Test("A single file sizes to its own allocation")
    func sizesBareFile() throws {
        try withLibraryFixture { fixture in
            let file = try fixture.makeFile(.preferences, "com.acme.Widget.plist", bytes: 30_000)

            #expect(DirectorySizer.size(of: file) == fixture.allocatedSize(of: [file]))
        }
    }

    @Test("Cancellation stops the walk early")
    func stopsWhenCancelled() throws {
        try withLibraryFixture { fixture in
            let root = fixture.library.directory(for: .caches).appending(path: "many", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: root)
            for index in 0..<2_000 {
                try fixture.writeFile(at: root.appending(path: "file\(index).bin"), bytes: 4_096)
            }

            let full = DirectorySizer.size(of: root)
            let cancelled = DirectorySizer.size(of: root, isCancelled: { true })

            #expect(full > 0)
            #expect(cancelled < full, "a cancelled walk must not run to completion")
        }
    }
}
