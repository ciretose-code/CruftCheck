# Cruft/Check

A lightweight macOS utility that finds wasted SSD space in `~/Library` and moves it to the
Trash. Two modes, native SwiftUI, no background agent, no subscription.

- **The Orphan Hunt** — support files, preferences and containers left behind by apps that
  are no longer installed.
- **The Cache Diet** — cache and log directories for apps you still use, largest first.

## Requirements

macOS 14+, Xcode 26+. `xcodegen` is only needed if you change `project.yml`.

## Build

```sh
open CruftCheck.xcodeproj      # ⌘R to run, ⌘U to test
```

The project is generated from `project.yml`, which is the source of truth for targets and
build settings. After editing it:

```sh
brew install xcodegen   # once
xcodegen generate
```

`CruftCheck/Info.plist` and `CruftCheck/CruftCheck.entitlements` are generated the same way —
edit the `info:` and `entitlements:` blocks in `project.yml`, not those files.

## Tests

```sh
xcodebuild -project CruftCheck.xcodeproj -scheme CruftCheck -destination 'platform=macOS' test
```

94 tests run against a synthetic `~/Library` built in a temp directory (`Tests/LibraryFixture.swift`),
so the safety-critical paths are exercised without waiting for real cruft to accumulate.
One test in `TrashServiceTests` genuinely moves a uniquely-named file to the Trash — that
recoverability is the whole safety guarantee — and removes that exact item afterward.

## Releasing

```sh
./Scripts/release.sh              # bump the build number, keep the version
./Scripts/release.sh 0.2          # set the version to 0.2 and bump the build
./Scripts/release.sh --dry-run    # build, sign and package; publish nothing
```

The script tests, archives, exports with Developer ID, builds a drag-to-Applications DMG,
notarizes and staples it, commits the version bump, and publishes a GitHub release.

Two prerequisites, both one-time:

```sh
# 1. A Developer ID Application certificate in the login keychain.
#    Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application
#    An "Apple Development" certificate cannot be notarized.

# 2. Notary credentials, stored in the keychain
xcrun notarytool store-credentials "cruftcheck-notary" \
  --key ~/.private_keys/AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

Both are verified in preflight, along with a clean tree on `main` in sync with `origin`,
before anything slow runs — a missing certificate should cost a second, not a full archive.
Set `NOTARY_PROFILE=<name>` to reuse credentials stored under another name.

**The version lives in `project.yml`, not in `project.pbxproj`.** `agvtool` writes to the
pbxproj, which the next `xcodegen generate` overwrites, so the bump would silently vanish.
The script edits `MARKETING_VERSION`, `CFBundleShortVersionString` and `CFBundleVersion` in
`project.yml`, regenerates, then reads the values back out of the generated `Info.plist` to
confirm they took.

**Signing is not in `project.yml`.** It lives in `Config/Signing.xcconfig`, whose committed
defaults sign ad-hoc — no team, no certificate, no Apple account — so a fresh clone or CI
outside the team builds and runs the full suite without configuring anything. That matters
more than usual here: the tests *are* the safety argument, and a contributor who can't run
them can't check their own work.

To sign with a team, create `Config/Signing.local.xcconfig` (gitignored):

```
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
```

The xcconfig pulls it in with `#include?`, so its absence isn't an error. Nothing may set
`CODE_SIGN_*` in `project.yml` — a target-level value outranks an xcconfig and would defeat
the arrangement.

**Developer ID signing happens at export, not at build.** `release.sh` reads
`DEVELOPMENT_TEAM` back out of the resolved build settings and generates export options
from it, so no team identifier is committed anywhere; `xcodebuild -exportArchive` re-signs
the archived app with the distribution certificate on the way out. The script fails if the
exported app isn't Developer ID signed, which is the check that matters — it tests the
artefact that actually ships.

Pinning `CODE_SIGN_IDENTITY` to `Developer ID Application` on Release instead is precisely
what Xcode's "Switch to Development Signing" recommendation exists to undo, so it comes back
as a pending project change every time the project is opened. `project.yml` therefore
matches Xcode's recommended settings exactly — including `LastUpgradeCheck` via
`options.xcodeVersion`, which XCodeGen otherwise stamps at 1430 and which alone makes Xcode
offer the upgrade dialog on every open. Accepting that dialog edits the generated project,
which the next `xcodegen generate` discards, so the two must agree.

## Safety model

The app is deliberately biased toward doing nothing:

- **Nothing is ever permanently deleted.** `TrashService` is the only code that removes
  anything, and it calls `FileManager.trashItem(at:resultingItemURL:)` exclusively.
  `removeItem`, `unlink` and shelling out to `rm` are banned in app code.
- **A missed orphan costs disk space; a false orphan costs working software.** Every clause
  in `AppPresence` is a reason *not* to flag something. An identifier is spared if it
  resolves in LaunchServices, if any ancestor identifier resolves (helpers), or if it shares
  a vendor prefix with an installed app bundle (XPC services such as
  `fr.handbrake.HandBrakeXPCService`, whose own identifier never resolves).
- **The verdict shows its work.** `AppPresence.verdict(for:)` returns the checks that
  declined to claim an identifier, not a bare `Bool`, and every row in the Orphan Hunt
  displays them. Caution the user can't see is caution they have to take on faith. The
  clause order short-circuits exactly as before, so recording evidence can never change a
  verdict — `isInstalled` is now a wrapper over `verdict(for:)`.
- **An action that frees nothing never looks like one that does.** Zero-byte caches are
  partitioned out of the Cache Diet list — a row that can't free anything can't help you
  choose — and counted in the header instead. They can be trashed via "Tidy N Empty
  Folders", an ordinary button rather than the prominent one, whose confirmation says
  plainly that it frees no space and that apps you still use may recreate the folders.
  `reclaimedBytes` comes from `expectedBytes`, which is zero for all of them, so running it
  cannot inflate the figure the footer reports.
- **Recency is reported only when it means something.** `DirectorySizer.measure` takes the
  newest modification date across a whole tree (a directory's own mtime doesn't move when a
  file three levels down is rewritten), and `stalenessLabel` withholds the claim entirely
  when nothing was readable or when the age is under three months — an app uninstalled last
  week leaves recent files behind, and "Untouched 1 month" is a number the user would have
  to know to discount.
- **Names are only ever used to stay quiet.** A folder called `Proxyman` yields no bundle
  identifier, so `AppPresence` has nothing to ask LaunchServices about, and the Orphan Hunt
  is silent about it by design. `InstalledAppNames` matches such folders against installed
  app names — but only to *withhold* a Cache Diet badge, never to flag anything. Its rules
  are deliberately over-generous, and an empty index claims everything, so a failed bundle
  sweep reads as "no evidence" rather than "nothing is installed".
  Human-named folders in `Application Support` remain out of scope: that is where apps keep
  data that exists nowhere else, and an app run from a disk image is indistinguishable from
  a departed one.
- **System paths are excluded before they are opened**, not merely disabled in the UI.
  Apple's caches don't all carry a `com.apple.` prefix — `AMSDataMigratorTool`, `PassKit`,
  `GameKit`, `GeoServices` are bare names, and several are TCC-guarded, so merely *measuring*
  them raises a privacy prompt for directories the app would never offer to delete.

The blocklists live in one place, `Services/LibraryPaths.swift`, and are heuristic — they
will need extending as other machines turn up new system directories.

## Architecture

```
CruftCheck/
├─ CruftCheckApp.swift            @main, Window scene
├─ Models/                        ScanMode, OrphanGroup, OrphanEvidence, CacheEntry, ScanProgress
├─ Services/
│   ├─ Background.swift           the one place the app leaves the main actor
│   ├─ DirectorySizer.swift       enumerator-based sizing + recency, allocated size, cancellable
│   ├─ LibraryScanner.swift       both scans; pure functions over a LibraryRoot
│   ├─ LibraryPaths.swift         safety lists + bundle-ID extraction  ← safety-critical
│   ├─ AppPresence.swift          the "is it still installed?" rule + its evidence, injectable
│   ├─ InstalledAppIndex.swift    LaunchServices lookups (@MainActor)
│   ├─ AppBundleIndex.swift       identifiers and names of installed .app bundles
│   ├─ InstalledAppNames.swift    name matcher; only ever withholds a claim
│   ├─ CancellationFlag.swift
│   ├─ FullDiskAccess.swift       probes the grant before a scan spends effort on it
│   ├─ VolumeCapacity.swift       the denominator: prompt-free, unlike measuring ~/Library
│   └─ TrashService.swift         the only code that removes anything
├─ ViewModels/ScannerViewModel.swift   @MainActor @Observable
└─ Views/                         ContentView, OrphanHuntView, CacheDietView, FlowLayout
```

Three constraints shape the concurrency design:

1. **`@MainActor` on the view model** makes "publish results on the main thread" a compile-time
   guarantee. All expensive work escapes through `Background.run`.
2. **`Task.isCancelled` is useless inside `DispatchQueue.global()`** — there is no enclosing
   task, so it reads `false` forever. `CancellationFlag` is polled by the walk instead.
3. **`NSWorkspace` is AppKit and main-actor-bound.** The Orphan Hunt is therefore three
   phases: enumerate on background → resolve identifiers on the main actor (in-memory
   LaunchServices, milliseconds) → deep-size only the survivors on background.

## Permissions

The App Sandbox is **off** by design: a sandboxed app cannot enumerate `~/Library` or trash
arbitrary paths there without the user hand-picking every folder in an open panel. Grant the
built app Full Disk Access in System Settings › Privacy & Security to read every subpath.

That grant is keyed to the bundle identifier *and* the code signature, so changing either
invalidates it. Re-grant Full Disk Access after any signing or identifier change, and remove
the stale entry from the list while you're there.

The app checks for the grant at the start of every scan rather than discovering its absence
when a removal is refused — by then the user has already chosen items and confirmed a
destructive action. `FullDiskAccess` probes `~/Library/Application Support/com.apple.TCC`,
which is readable only with the grant and, unlike the purpose-limited directories, fails
*silently* instead of raising a consent dialog just for asking.

When a removal is refused anyway, `TrashService.Failure` separates "macOS said no" from "the
safety list said no". Only the first is fixable, so only the first offers System Settings —
and it also offers Finder, which holds privileges this app doesn't and can move the item to
the Trash without the grant or a relaunch.
