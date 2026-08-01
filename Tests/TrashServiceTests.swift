import Foundation
import Testing
@testable import CruftCheck

@Suite("Trash service")
struct TrashServiceTests {

    @Test("Protected items are refused even if they somehow reach the trash call")
    func refusesProtectedItems() throws {
        try withLibraryFixture { fixture in
            let passKit = try fixture.makeBundleDirectory(.caches, "PassKit")

            let outcome = TrashService.trash([passKit])

            #expect(outcome.trashed.isEmpty)
            #expect(outcome.failures.count == 1)
            #expect(outcome.reclaimedBytes == 0)
            #expect(FileManager.default.fileExists(atPath: passKit.path), "the item must still be there")
        }
    }

    @Test("An item that has already gone counts as done, not as a failure")
    func toleratesMissingItems() throws {
        try withLibraryFixture { fixture in
            let vanished = fixture.library.directory(for: .caches).appending(path: "com.acme.Gone")

            let outcome = TrashService.trash([vanished], expectedBytes: [vanished: 5_000])

            #expect(outcome.didFullySucceed)
            #expect(outcome.trashed == [vanished])
            #expect(outcome.reclaimedBytes == 0, "nothing was actually reclaimed")
        }
    }

    /// The one test that really moves something. It trashes a uniquely named file it just
    /// created, then removes that exact item from the Trash so the run leaves no residue.
    /// `removeItem` is banned in app code, not in a test cleaning up its own artifact.
    @Test("Items are moved to the Trash, never deleted")
    func movesItemsToTrash() throws {
        try withLibraryFixture { fixture in
            let name = "CruftCheckTest-\(UUID().uuidString).bin"
            let file = fixture.library.directory(for: .caches).appending(path: name)
            try fixture.writeFile(at: file, bytes: 4_096)
            let expected = fixture.allocatedSize(of: [file])

            let outcome = TrashService.trash([file], expectedBytes: [file: expected])

            #expect(outcome.didFullySucceed)
            #expect(outcome.trashed == [file])
            #expect(outcome.reclaimedBytes == expected)
            #expect(!FileManager.default.fileExists(atPath: file.path), "source must be gone")

            // The file is recoverable — that is the entire safety guarantee.
            let inTrash = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".Trash", directoryHint: .isDirectory)
                .appending(path: name)
            #expect(FileManager.default.fileExists(atPath: inTrash.path), "must be recoverable from the Trash")

            try? FileManager.default.removeItem(at: inTrash)
        }
    }

    // MARK: - Why a removal failed
    //
    // The two refusals look alike and aren't. One is fixed in System Settings; the other is
    // the safety list doing its job and will never succeed. Telling them apart is what lets
    // the UI offer a way out only when one exists.

    @Test("A safety-list refusal is not reported as a permissions problem")
    func protectedIsNotPermissionDenied() throws {
        try withLibraryFixture { fixture in
            let passKit = try fixture.makeBundleDirectory(.caches, "PassKit")

            let outcome = TrashService.trash([passKit])

            #expect(outcome.failures.first?.reason == .protectedItem)
            #expect(!outcome.needsFullDiskAccess, "no setting will ever make this succeed")
            #expect(outcome.blockedURLs.isEmpty)
        }
    }

    /// The real thing: a directory the process genuinely cannot write to. `trashItem` needs
    /// to remove the entry from the parent, so a read-only parent denies it the same way
    /// TCC does when Full Disk Access is missing.
    @Test("A genuine permission denial is classified as one")
    func classifiesPermissionDenied() throws {
        try withLibraryFixture { fixture in
            let locked = try fixture.makeBundleDirectory(.caches, "locked", bytes: 256)
            let victim = locked.appending(path: "payload.bin")

            try fixture.setPosixPermissions(0o500, at: locked)
            defer { try? fixture.setPosixPermissions(0o700, at: locked) }

            let outcome = TrashService.trash([victim])

            #expect(outcome.trashed.isEmpty)
            #expect(outcome.failures.first?.reason == .permissionDenied)
            #expect(outcome.needsFullDiskAccess)
            #expect(outcome.blockedURLs == [victim])
            #expect(outcome.failures.first?.message.contains("Full Disk Access") == true)
        }
    }

    @Test("Blocked items are offered back for revealing, protected ones are not")
    func onlyBlockedItemsAreRevealed() throws {
        try withLibraryFixture { fixture in
            let locked = try fixture.makeBundleDirectory(.caches, "locked2", bytes: 256)
            let victim = locked.appending(path: "payload.bin")
            let passKit = try fixture.makeBundleDirectory(.caches, "PassKit")

            try fixture.setPosixPermissions(0o500, at: locked)
            defer { try? fixture.setPosixPermissions(0o700, at: locked) }

            let outcome = TrashService.trash([victim, passKit])

            #expect(outcome.failures.count == 2)
            // Finder can get past the first and shouldn't be pointed at the second.
            #expect(outcome.blockedURLs == [victim])
        }
    }

    @Test("A mixed batch reports each item's outcome independently")
    func reportsPerItemOutcomes() throws {
        try withLibraryFixture { fixture in
            let protected = try fixture.makeBundleDirectory(.caches, "GameKit")
            let missing = fixture.library.directory(for: .caches).appending(path: "com.acme.Gone")

            let outcome = TrashService.trash([protected, missing])

            #expect(outcome.trashed == [missing])
            #expect(outcome.failures.count == 1)
            #expect(FileManager.default.fileExists(atPath: protected.path))
        }
    }
}

@Suite("Presence rule")
struct AppPresenceTests {

    @Test("Vendor prefix is the first two components")
    func derivesVendorPrefix() {
        #expect(AppBundleIndex.vendorPrefix(of: "fr.handbrake.HandBrakeXPCService") == "fr.handbrake")
        #expect(AppBundleIndex.vendorPrefix(of: "com.Google.Chrome") == "com.google")
        #expect(AppBundleIndex.vendorPrefix(of: "single") == nil)
    }

    @Test("Ancestors stop at three components")
    func stopsAtThreeComponents() {
        #expect(LibraryPaths.ancestorIdentifiers(of: "com.acme.Widget.Helper.Inner")
                == ["com.acme.Widget.Helper", "com.acme.Widget"])
        #expect(LibraryPaths.ancestorIdentifiers(of: "com.acme.Widget").isEmpty)
    }

    @Test("Lookups are case-insensitive")
    func matchesCaseInsensitively() {
        let presence = AppPresence.fake(installed: ["COM.ACME.WIDGET"])
        #expect(presence.isInstalled("com.acme.widget"))
    }
}
