import ShipKit
import SwiftUI

/// Fuzzy-filterable list of a repo's labels. ↑/↓ move, ⏎ toggles, esc closes.
struct LabelPicker: View {
    let store: ShipStore
    let prID: String
    let close: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @State private var loading = false
    @FocusState private var fieldFocused: Bool

    private var entry: Entry? { store.entry(id: prID) }
    private var applied: Set<String> { Set(entry?.pr.labels.map(\.name) ?? []) }

    /// Applied labels first, then the rest alphabetically; ranked by match quality once there's a query.
    private var rows: [(label: RepoLabel, match: FuzzyMatch.Result?)] {
        let labels = store.repoLabels[entry?.pr.repo ?? ""] ?? []
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let applied = applied
            return (labels.filter { applied.contains($0.name) } + labels.filter { !applied.contains($0.name) }).map { ($0, nil) }
        }
        return FuzzyMatch.rank(labels, query: query, key: \.name).map { ($0.item, $0.result) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TextField("Filter labels", text: $query, prompt: Text("Type to filter labels…"))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onSubmit(toggleHighlighted)
                .onChange(of: query) { highlighted = 0 }
            Divider()
            list
        }
        .frame(height: 420)
        .onAppear { fieldFocused = true }
        .task {
            guard let repo = entry?.pr.repo else { return }
            loading = store.repoLabels[repo] == nil
            await store.loadLabels(for: repo)
            loading = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Labels", systemImage: "tag").font(.headline)
                if let pr = entry?.pr {
                    Text(verbatim: "\(pr.repo)#\(pr.number) · \(pr.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close (esc)")
        }
        .padding(12)
    }

    @ViewBuilder private var list: some View {
        let rows = rows
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            Text(query.isEmpty ? "This repository has no labels." : "No labels match “\(query)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.label.id) { index, row in
                            LabelRow(
                                label: row.label,
                                match: row.match,
                                isApplied: applied.contains(row.label.name),
                                isHighlighted: index == highlighted
                            )
                            .onTapGesture { toggle(row.label) }
                            .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, index in
                    if rows.indices.contains(index) { proxy.scrollTo(rows[index].label.id) }
                }
            }
        }
    }

    private func move(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        highlighted = max(0, min(count - 1, highlighted + delta))
    }

    private func toggleHighlighted() {
        let rows = rows
        guard rows.indices.contains(highlighted) else { return }
        toggle(rows[highlighted].label)
    }

    private func toggle(_ label: RepoLabel) {
        Task { await store.toggle(label, on: prID) }
        // Clear the filter so the next label can be typed straight away.
        if !query.isEmpty { query = "" }
        fieldFocused = true
    }
}

private struct LabelRow: View {
    let label: RepoLabel
    let match: FuzzyMatch.Result?
    let isApplied: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .opacity(isApplied ? 1 : 0)
                .frame(width: 12)
            Circle()
                .fill(Color.rgb(hex: label.color).map { Color(red: $0.0, green: $0.1, blue: $0.2) } ?? .secondary)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedName).font(.callout)
                if let description = label.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
    }

    /// Bolds the characters the query matched.
    private var highlightedName: AttributedString {
        var text = AttributedString()
        let positions = Set(match?.positions ?? [])
        for (index, character) in label.name.enumerated() {
            var piece = AttributedString(String(character))
            if positions.contains(index) {
                piece.font = .callout.bold()
                piece.foregroundColor = .accentColor
            }
            text += piece
        }
        return text
    }
}
