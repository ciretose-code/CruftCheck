import Foundation
import Testing
@testable import CruftCheck

@Suite("Full Disk Access probe")
struct FullDiskAccessTests {

    /// The regression this suite exists for. macOS 27 took `~/Library/Application Support/
    /// com.apple.TCC` away from apps, so the old probe was never found, every check came back
    /// `.unknown`, and the banner asking for the grant silently stopped appearing.
    @Test("The default probe answers on this Mac rather than returning unknown")
    func defaultProbeIsPresent() {
        #expect(FullDiskAccess.status() != .unknown)
    }

    @Test("A readable probe means the grant is present")
    func readableProbeIsGranted() throws {
        try withLibraryFixture { fixture in
            let probe = fixture.root.appending(path: "Readable", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: probe)

            #expect(FullDiskAccess.status(probes: [probe]) == .granted)
        }
    }

    @Test("A probe that exists but refuses a listing means the grant is missing")
    func unreadableProbeIsDenied() throws {
        try withLibraryFixture { fixture in
            let probe = fixture.root.appending(path: "Refused", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: probe)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: probe.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path) }

            #expect(FullDiskAccess.status(probes: [probe]) == .denied)
        }
    }

    /// One OS release has already removed a probe. Falling through to the next candidate is
    /// what keeps the next removal from silencing the banner again.
    @Test("A missing probe falls through to the next candidate")
    func missingProbeFallsThrough() throws {
        try withLibraryFixture { fixture in
            let missing = fixture.root.appending(path: "Gone", directoryHint: .isDirectory)
            let present = fixture.root.appending(path: "Present", directoryHint: .isDirectory)
            try fixture.makeDirectory(at: present)

            #expect(FullDiskAccess.status(probes: [missing, present]) == .granted)
        }
    }

    @Test("With no probe present the answer is unknown, never a denial")
    func noProbeIsUnknown() throws {
        try withLibraryFixture { fixture in
            let missing = fixture.root.appending(path: "Gone", directoryHint: .isDirectory)

            #expect(FullDiskAccess.status(probes: [missing]) == .unknown)
        }
    }
}
