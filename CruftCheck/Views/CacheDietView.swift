import AppKit
import SwiftUI

/// Mode 2. Caches and logs for apps you still use, biggest first.
///
/// No selection model here — each row clears independently, because clearing one app's
/// cache is a small, reversible, per-app decision rather than a batch operation.
///
/// Rows below `TailSplitRule.threshold` are collapsed behind one summary row. Their bars
/// would all render at the same minimum width, so drawing them individually spends most of
/// the list on rows that can't be told apart.
struct CacheDietView: View {
    @Bindable var scanner: ScannerViewModel

    /// Owned here rather than inside the summary row, because the rows it reveals are
    /// siblings in the `List` rather than children of that row — see `TailSummary`.
    @State private var isTailExpanded = false

    var body: some View {
        List {
            ForEach(split.major) { entry in
                CacheRow(
                    entry: entry,
                    share: share(of: entry),
                    unclaimed: scanner.unclaimedLabel(for: entry)
                ) {
                    Task { await scanner.clearCache(entry) }
                }
            }

            if !split.tail.isEmpty {
                TailSummary(
                    count: split.tail.count,
                    bytes: split.tailBytes,
                    isExpanded: $isTailExpanded
                )

                if isTailExpanded {
                    // Emitted flat into the List, not nested under the summary row. A
                    // `ForEach` inside a row's own stack lays out as one row and renders
                    // its children blank.
                    //
                    // No bars in here either: every one would draw at the minimum width,
                    // which is why these were grouped in the first place.
                    ForEach(split.tail) { entry in
                        CacheRow(
                            entry: entry,
                            share: nil,
                            unclaimed: scanner.unclaimedLabel(for: entry)
                        ) {
                            Task { await scanner.clearCache(entry) }
                        }
                        .padding(.leading, 18)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var split: TailSplit<CacheEntry> { TailSplit(scanner.caches, bytes: \.bytes) }

    /// Each row's size relative to the largest row, for the proportion bar.
    private func share(of entry: CacheEntry) -> Double {
        guard let largest = scanner.caches.first?.bytes, largest > 0 else { return 0 }
        return Double(entry.bytes) / Double(largest)
    }
}

// MARK: - Tail

/// The one row standing in for the collapsed remainder of the list.
///
/// Expandable rather than hidden: those rows are still reachable and still individually
/// clearable, they just stop competing for attention with the entries holding real space.
private struct TailSummary: View {
    let count: Int
    let bytes: UInt64
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) smaller items")
                        .font(.body.weight(.medium))
                    Text("None above 1% of the total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Empty, but the column stays so the sizes still line up with the rows above.
                Color.clear.frame(width: CacheRow.barWidth, height: 3)

                Text(ByteFormat.string(bytes))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 84, alignment: .trailing)

                // Reserves the width of a row's Clear button so the columns don't shift.
                Button("Clear") {}.hidden()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) smaller items, \(ByteFormat.string(bytes)) combined")
        .accessibilityHint(isExpanded ? "Collapse" : "Expand to clear them individually")
    }
}

// MARK: - Row

private struct CacheRow: View {
    static let barWidth: CGFloat = 120

    let entry: CacheEntry
    /// `nil` inside the tail group, where a bar would carry no information.
    let share: Double?
    /// Set when nothing installed appears to own this folder — see `unclaimedLabel(for:)`.
    let unclaimed: String?
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
                HStack(spacing: 7) {
                    Text(entry.domain.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let unclaimed {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 4, height: 4)
                            Text(unclaimed)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                        .fixedSize()
                    }
                }
            }
            // Flexible, so every column to the right lines up regardless of name length.
            // Without this a long name pushes the byte counts out of alignment and the
            // list stops being scannable, which is the only thing it's for.
            .frame(maxWidth: .infinity, alignment: .leading)

            // The proportion gets its own column rather than sitting under the name, where
            // a bar wider than a short name just reads as an underline. The track makes it
            // legible as a meter even when the fill is a sliver.
            if let share {
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
            } else {
                Color.clear.frame(width: Self.barWidth, height: 3)
            }

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
                    // The promise changes with the badge. "The app rebuilds this" is the
                    // normal case and the reason clearing a cache is safe; it's also the
                    // reason clearing one is temporary. When nothing claims the folder,
                    // neither half holds — so say the truer, more useful thing.
                    Text(
                        unclaimed == nil
                            ? "Frees \(ByteFormat.string(entry.bytes)). The app rebuilds this cache as needed, and you can restore it from the Trash."
                            : "Frees \(ByteFormat.string(entry.bytes)). Nothing on this Mac appears to own this folder, so unlike a normal cache nothing should rebuild it. You can restore it from the Trash."
                    )
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
