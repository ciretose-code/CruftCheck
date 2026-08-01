import AppKit
import SwiftUI

/// Mode 2. Caches and logs for apps you still use, biggest first.
///
/// No selection model here — each row clears independently, because clearing one app's
/// cache is a small, reversible, per-app decision rather than a batch operation.
struct CacheDietView: View {
    @Bindable var scanner: ScannerViewModel

    var body: some View {
        List {
            ForEach(scanner.caches) { entry in
                CacheRow(entry: entry, share: share(of: entry)) {
                    Task { await scanner.clearCache(entry) }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    /// Each row's size relative to the largest row, for the proportion bar.
    private func share(of entry: CacheEntry) -> Double {
        guard let largest = scanner.caches.first?.bytes, largest > 0 else { return 0 }
        return Double(entry.bytes) / Double(largest)
    }
}

private struct CacheRow: View {
    static let barWidth: CGFloat = 120

    let entry: CacheEntry
    let share: Double
    let clear: () -> Void

    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.domain.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Caches and Logs both feed this list and can hold the same name.
                Text(entry.domain.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Flexible, so every column to the right lines up regardless of name length.
            // Without this a long name pushes the byte counts out of alignment and the
            // list stops being scannable, which is the only thing it's for.
            .frame(maxWidth: .infinity, alignment: .leading)

            // The proportion gets its own column rather than sitting under the name, where
            // a bar wider than a short name just reads as an underline. The track makes it
            // legible as a meter even when the fill is a sliver.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 3)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(2, Self.barWidth * share), height: 3)
            }
            .frame(width: Self.barWidth)
            .accessibilityHidden(true)

            Text(ByteFormat.string(entry.bytes))
                .font(.body.weight(.semibold).monospacedDigit())
                .frame(minWidth: 84, alignment: .trailing)

            Button("Clear") { isConfirming = true }
                .confirmationDialog(
                    "Move “\(entry.name)” to the Trash?",
                    isPresented: $isConfirming,
                    titleVisibility: .visible
                ) {
                    Button("Move to Trash", role: .destructive, action: clear)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Frees \(ByteFormat.string(entry.bytes)). The app rebuilds this cache as needed, and you can restore it from the Trash.")
                }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
    }
}
