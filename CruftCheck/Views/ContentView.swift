import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var scanner: ScannerViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if scanner.diskAccess == .denied { AccessBanner(scanner: scanner) }
            Divider()
            content
            Divider()
            FooterBar(scanner: scanner)
        }
        .background(.background)
        .task { if scanner.phase == .idle { scanner.scan() } }
        .modifier(TrashFailureAlert(scanner: scanner))
    }

    // MARK: - Header

    /// A segmented Picker is the whole navigation model — two modes, one control, no chrome.
    ///
    /// Below it sits the answer to the question the app was opened with. Once a scan has
    /// results the total leads; before that, the mode's own description does.
    private var header: some View {
        VStack(spacing: 10) {
            Picker("Mode", selection: $scanner.mode) {
                ForEach(ScanMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)

            if scanner.hasResults && !scanner.isScanning {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ByteFormat.string(scanner.totalBytes))
                        .font(.title.weight(.semibold).monospacedDigit())
                    Text(headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(scanner.mode.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// The context line beside the total — what the number is made of.
    private var headline: String {
        switch scanner.mode {
        case .orphanHunt:
            let count = scanner.orphans.count
            let base = "in \(count) orphaned identifier\(count == 1 ? "" : "s")"
            return scanner.selection.isEmpty
                ? base
                : base + " · \(scanner.selection.count) selected, \(ByteFormat.string(scanner.selectedBytes))"
        case .cacheDiet:
            let count = scanner.caches.count
            var parts = ["reclaimable in \(count) item\(count == 1 ? "" : "s")"]
            if scanner.skippedSystemItems > 0 {
                parts.append("\(scanner.skippedSystemItems) system items not measured")
            }
            // Named so the list doesn't look arbitrarily short next to Finder's own count.
            if !scanner.emptyCaches.isEmpty {
                parts.append("\(scanner.emptyCaches.count) empty")
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if scanner.isScanning && !scanner.hasResults {
            ScanningView(progress: scanner.progress)
        } else if !scanner.hasResults {
            EmptyStateView(mode: scanner.mode, phase: scanner.phase) { scanner.scan() }
        } else {
            switch scanner.mode {
            case .orphanHunt: OrphanHuntView(scanner: scanner)
            case .cacheDiet:  CacheDietView(scanner: scanner)
            }
        }
    }
}

// MARK: - Failure alert

/// Extracted from `ContentView.body` to keep that expression small enough to type-check
/// quickly — inlined, it was already drawing a compiler warning about the cost.
private struct TrashFailureAlert: ViewModifier {
    @Bindable var scanner: ScannerViewModel

    func body(content: Content) -> some View {
        content.alert(
            scanner.failure?.title ?? "",
            isPresented: .init(
                get: { scanner.failure != nil },
                set: { if !$0 { scanner.clearError() } }
            ),
            presenting: scanner.failure
        ) { failure in
            if failure.needsFullDiskAccess {
                Button("Open Settings") {
                    NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                    scanner.clearError()
                }
                // Finder holds privileges this app doesn't, so this works even while the
                // grant is missing — the only route that needs no relaunch.
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(failure.blockedURLs)
                    scanner.clearError()
                }
            }
            Button("OK", role: .cancel) { scanner.clearError() }
        } message: { failure in
            Text(failure.message)
        }
    }
}

// MARK: - Access banner

/// Shown from the moment a scan starts without the grant, not at the moment a deletion is
/// refused. Told early it's a setup step; told late it's a wasted decision.
private struct AccessBanner: View {
    @Bindable var scanner: ScannerViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text("Cruft/Check can't see all of ~/Library")
                    .font(.callout.weight(.semibold))
                Text("Totals are incomplete and items can't be moved to the Trash. Grant Full Disk Access, or use Reveal on any row and delete it from Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Open Settings") {
                NSWorkspace.shared.open(FullDiskAccess.settingsURL)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Bindable var scanner: ScannerViewModel
    @State private var isConfirmingTrash = false
    @State private var isConfirmingTidy = false

    var body: some View {
        HStack(spacing: 12) {
            if scanner.isScanning {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { scanner.cancelScan() }
                    .buttonStyle(.link)
            } else {
                // The totals live in the header now; the footer is controls and outcomes.
                Button("Rescan") { scanner.scan() }
            }

            Spacer()

            if scanner.reclaimedBytes > 0 {
                Label(ByteFormat.string(scanner.reclaimedBytes) + " trashed", systemImage: "trash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Deliberately an ordinary button, not the prominent one: this frees no space,
            // so it must not look like the reason you opened the app.
            if scanner.mode == .cacheDiet && !scanner.emptyCaches.isEmpty {
                Button(tidyTitle) { isConfirmingTidy = true }
                    .disabled(scanner.isScanning)
                    .confirmationDialog(
                        tidyTitle + "?",
                        isPresented: $isConfirmingTidy,
                        titleVisibility: .visible
                    ) {
                        Button("Move to Trash") {
                            Task { await scanner.tidyEmptyCaches() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("These hold no files, so this frees no space — it only clears them out of ~/Library. Apps you still use may create them again, and you can restore them from the Trash.")
                    }
            }

            if scanner.mode == .orphanHunt {
                Button("Move to Trash", role: .destructive) { isConfirmingTrash = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanner.selection.isEmpty || scanner.isScanning)
                    .confirmationDialog(
                        "Move \(scanner.selection.count) item\(scanner.selection.count == 1 ? "" : "s") to the Trash?",
                        isPresented: $isConfirmingTrash,
                        titleVisibility: .visible
                    ) {
                        Button("Move to Trash", role: .destructive) {
                            Task { await scanner.trashSelectedOrphans() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This frees \(ByteFormat.string(scanner.selectedBytes)). Nothing is erased — you can restore it from the Trash.")
                    }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var tidyTitle: String {
        let count = scanner.emptyCaches.count
        return "Tidy \(count) Empty Folder\(count == 1 ? "" : "s")"
    }

    private var progressText: String {
        guard let progress = scanner.progress else { return "Scanning ~/Library…" }
        return "Measuring \(progress.completed) of \(progress.total) — \(progress.label)"
    }

}

// MARK: - Transient states

private struct ScanningView: View {
    let progress: ScanProgress?

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: progress?.fraction ?? 0, total: 1)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            Text(progress?.label ?? "Reading ~/Library…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyStateView: View {
    let mode: ScanMode
    let phase: ScannerViewModel.Phase
    let rescan: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: phase == .cancelled ? "stop.circle" : "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(phase == .cancelled ? "Scan stopped." : "Nothing to clean.")
                .font(.title3.weight(.medium))
            Text(phase == .cancelled ? "Run it again when you're ready." : mode.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Scan Again", action: rescan)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
