import AppKit
import SwiftUI

/// Mode 1. Leftovers from apps that are no longer installed, grouped by bundle identifier.
///
/// Selection is explicit checkboxes rather than List row selection: this list drives a
/// destructive action, and a click that both highlights and arms deletion is too easy to
/// trigger by accident.
///
/// Rows carry the evidence behind each verdict — the checks in `OrphanEvidence` that
/// declined to claim the identifier. The app's caution is the reason to trust it, so it
/// belongs on screen rather than only in the README.
struct OrphanHuntView: View {
    @Bindable var scanner: ScannerViewModel

    @State private var isTailExpanded = false

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.groups) { group in
                        OrphanRow(
                            group: group,
                            share: share(of: group),
                            isOn: binding(for: group)
                        )
                    }
                } header: {
                    SectionHeader(section: section)
                }
            }

            if !split.tail.isEmpty {
                TailSummary(
                    count: split.tail.count,
                    bytes: split.tailBytes,
                    isExpanded: $isTailExpanded,
                    isOn: tailBinding
                )

                if isTailExpanded {
                    // Flat siblings rather than children of the summary row: a `ForEach`
                    // nested inside a row's own stack lays out as one row and renders blank.
                    ForEach(split.tail) { group in
                        OrphanRow(group: group, share: nil, isOn: binding(for: group))
                            .padding(.leading, 18)
                    }
                }
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
                Text("Every row lists the checks that found no installed owner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Sectioning

    /// One identifier commonly holds most of the bytes — 91% of the total, on the machine
    /// this was built against — which leaves every other bar at the minimum width. The tail
    /// is split off before sectioning so the sections describe rows worth reading.
    private var split: TailSplit<OrphanGroup> { TailSplit(scanner.orphans, bytes: \.bytes) }

    private var tailBinding: Binding<Bool> {
        let ids = Set(split.tail.map(\.id))
        return Binding(
            get: { !ids.isEmpty && ids.isSubset(of: scanner.selection) },
            set: { isOn in
                if isOn { scanner.selection.formUnion(ids) }
                else { scanner.selection.subtract(ids) }
            }
        )
    }

    /// Groups bucketed by where their bytes actually live, largest bucket first, with
    /// preferences-only leftovers pushed to the end regardless of count.
    private var sections: [OrphanSection] {
        let preferencesOnly = split.major.filter(\.isPreferencesOnly)
        let substantial = split.major.filter { !$0.isPreferencesOnly }

        var sections = Dictionary(grouping: substantial, by: \.primaryDomain)
            .map { OrphanSection(domain: $0.key, isPreferencesOnly: false, groups: $0.value) }
            .sorted { $0.bytes > $1.bytes }

        if !preferencesOnly.isEmpty {
            sections.append(
                OrphanSection(domain: .preferences, isPreferencesOnly: true, groups: preferencesOnly)
            )
        }
        return sections
    }

    /// Each row's size relative to the largest orphan, for the proportion bar.
    private func share(of group: OrphanGroup) -> Double {
        guard let largest = scanner.orphans.first?.bytes, largest > 0 else { return 0 }
        return Double(group.bytes) / Double(largest)
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

// MARK: - Sections

private struct OrphanSection: Identifiable {
    let domain: LibraryDomain
    let isPreferencesOnly: Bool
    let groups: [OrphanGroup]

    var id: String { isPreferencesOnly ? "preferences-only" : domain.rawValue }
    var bytes: UInt64 { groups.reduce(0) { $0 + $1.bytes } }
    var title: String { isPreferencesOnly ? "Preferences only" : domain.rawValue }
}

private struct SectionHeader: View {
    let section: OrphanSection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: section.domain.symbol)
                .foregroundStyle(.secondary)
            Text(section.title)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(ByteFormat.string(section.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .textCase(nil)
    }
}

// MARK: - Tail

/// The one row standing in for every orphan too small to rank visually.
///
/// Unlike the Cache Diet's equivalent this carries a checkbox, because the Orphan Hunt acts
/// on a selection: "take all forty-three of the tiny ones" is a reasonable thing to want,
/// and making the user expand the group to tick them individually would be busywork.
private struct TailSummary: View {
    let count: Int
    let bytes: UInt64
    @Binding var isExpanded: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Select all \(count) smaller orphans")

            Button {
                withAnimation(.snappy(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(count) smaller orphans")
                            .font(.body.weight(.medium))
                        Text("None above 1% of the total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Text(ByteFormat.string(bytes))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse" : "Expand to review them individually")
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Rows

private struct OrphanRow: View {
    let group: OrphanGroup
    /// `nil` inside the tail group, where a bar would carry no information.
    let share: Double?
    @Binding var isOn: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Toggle(isOn: $isOn) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                Image(systemName: group.primaryDomain.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.displayName)
                        .font(.body.weight(.medium))

                    Text("\(group.bundleID) · \(group.paths.count) location\(group.paths.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // A hairline bar ranks rows by size without adding a second number.
                    // Width-capped: stretched across the full text column it stops reading
                    // as a meter and starts reading as an underline.
                    if let share {
                        GeometryReader { geometry in
                            Capsule()
                                .fill(.tint)
                                .frame(width: max(2, geometry.size.width * share), height: 3)
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                        .frame(height: 3)
                    }

                    EvidenceChips(evidence: group.evidence, staleness: group.stalenessLabel)
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
                .padding(.leading, 50)
                .padding(.bottom, 2)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// The checks that failed to find an owner for this identifier, plus how long it has sat
/// untouched.
///
/// Rendered as passed checks rather than warnings: each one is a reason the app was willing
/// to flag the item, so the colour is reassurance, not alarm.
///
/// Staleness gets a clock rather than a dot because it comes from somewhere else entirely —
/// the presence rule proves nothing owns the identifier, the filesystem says nothing has
/// used it. Giving both the same mark would imply one source.
private struct EvidenceChips: View {
    let evidence: OrphanEvidence
    let staleness: String?

    var body: some View {
        if !evidence.checks.isEmpty || staleness != nil {
            FlowLayout(spacing: 5, lineSpacing: 4) {
                ForEach(evidence.checks, id: \.self) { check in
                    Chip {
                        Circle()
                            .fill(.green)
                            .frame(width: 4, height: 4)
                        Text(check.label)
                    }
                }

                if let staleness {
                    Chip {
                        Image(systemName: "clock")
                        Text(staleness)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct Chip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                Capsule().strokeBorder(.quaternary, lineWidth: 1)
            )
            .fixedSize()
    }
}
