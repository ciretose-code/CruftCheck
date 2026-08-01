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
    let entry: CacheEntry
    let share: Double
    let clear: () -> Void

    @State private var isConfirming = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.domain.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // A single hairline bar reads size at a glance without adding chrome.
                GeometryReader { geometry in
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(2, geometry.size.width * share), height: 3)
                }
                .frame(height: 3)
            }

            Text(ByteFormat.string(entry.bytes))
                .font(.body.weight(.semibold).monospacedDigit())
                .frame(minWidth: 78, alignment: .trailing)

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
