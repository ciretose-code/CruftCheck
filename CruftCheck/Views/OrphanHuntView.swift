import AppKit
import SwiftUI

/// Mode 1. Leftovers from apps that are no longer installed, grouped by bundle identifier.
///
/// Selection is explicit checkboxes rather than List row selection: this list drives a
/// destructive action, and a click that both highlights and arms deletion is too easy to
/// trigger by accident.
struct OrphanHuntView: View {
    @Bindable var scanner: ScannerViewModel

    var body: some View {
        List {
            ForEach(scanner.orphans) { group in
                OrphanRow(group: group, isOn: binding(for: group))
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .safeAreaInset(edge: .top) {
            HStack {
                Button(allSelected ? "Deselect All" : "Select All") {
                    scanner.selection = allSelected ? [] : Set(scanner.orphans.map(\.id))
                }
                .buttonStyle(.link)
                Spacer()
                Text("Verified against Launch Services — nothing here resolves to an installed app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var allSelected: Bool {
        !scanner.orphans.isEmpty && scanner.selection.count == scanner.orphans.count
    }

    private func binding(for group: OrphanGroup) -> Binding<Bool> {
        Binding(
            get: { scanner.selection.contains(group.id) },
            set: { isOn in
                if isOn { scanner.selection.insert(group.id) }
                else { scanner.selection.remove(group.id) }
            }
        )
    }
}

private struct OrphanRow: View {
    let group: OrphanGroup
    @Binding var isOn: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(isOn: $isOn) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.body.weight(.medium))
                    Text(group.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Text(ByteFormat.string(group.bytes))
                    .font(.body.weight(.semibold).monospacedDigit())

                Button {
                    withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show the \(group.paths.count) affected location\(group.paths.count == 1 ? "" : "s")")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.paths) { path in
                        HStack(spacing: 8) {
                            Image(systemName: path.domain.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(path.domain.rawValue)
                                .foregroundStyle(.secondary)
                            Text(path.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteFormat.string(path.bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Button("Reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([path.url])
                            }
                            .buttonStyle(.link)
                        }
                        .font(.caption)
                    }
                }
                .padding(.leading, 32)
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
