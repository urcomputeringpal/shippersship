import Foundation
import Observation
import ShipKit
import SwiftUI

struct PanelSection: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let entries: [Entry]
    var expandedByDefault = true
    /// Set for user-defined groups.
    var group: PRGroup?
}

extension ShipStore {
    /// The panel's sections, top to bottom: what's shipping, what needs you, other open work,
    /// then groups in the order they're defined, then Landed.
    var sections: [PanelSection] {
        [
            PanelSection(id: "watching", title: "Worth watching", symbol: "eyes", tint: .cyan, entries: watching),
            PanelSection(id: "attention", title: "Needs you", symbol: "hand.raised.fill", tint: .orange, entries: attention),
            PanelSection(id: "authored", title: "Your PRs", symbol: "arrow.triangle.pull", tint: .blue, entries: authored),
            PanelSection(id: "reviewing", title: "Reviewing", symbol: "eye", tint: .purple, entries: reviewing),
            PanelSection(id: "drafts", title: "Drafts", symbol: "pencil.and.outline", tint: .secondary, entries: drafts, expandedByDefault: false),
        ] + groups.map { group in
            PanelSection(
                id: "group:\(group.id.uuidString)",
                title: group.name,
                symbol: group.quiet ? "tray.full" : "folder",
                tint: .teal,
                entries: groupedEntries[group.id] ?? [],
                expandedByDefault: false,
                group: group
            )
        } + [
            PanelSection(id: "landed", title: "Landed", symbol: "shippingbox.fill", tint: .green, entries: landed),
        ]
    }
}

/// Something the keyboard can select: a section header or a PR row.
enum PanelItem: Hashable {
    case section(String)
    case pr(String)

    /// Stable id for `ScrollViewReader.scrollTo`.
    var scrollID: String {
        switch self {
        case let .section(id): "section:\(id)"
        case let .pr(id): id
        }
    }
}

/// UI state for the panel: which sections are expanded, the keyboard selection, and the open label picker.
@MainActor
@Observable
final class PanelState {
    private static let expansionKey = "sectionExpansion"

    /// Sections the user has expanded or collapsed, overriding each section's default. Saved across launches.
    private var expansion: [String: Bool] {
        didSet { if persists { UserDefaults.standard.set(expansion, forKey: Self.expansionKey) } }
    }
    var selection: PanelItem?
    var labelingID: String?
    private let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
        expansion = persists ? UserDefaults.standard.dictionary(forKey: Self.expansionKey) as? [String: Bool] ?? [:] : [:]
    }

    /// The selected PR's id, if a PR (not a header) is selected.
    var selectedPRID: String? {
        if case let .pr(id) = selection { id } else { nil }
    }

    func isExpanded(_ section: PanelSection) -> Bool {
        expansion[section.id] ?? section.expandedByDefault
    }

    func setExpanded(_ expanded: Bool, _ section: PanelSection) {
        expansion[section.id] = expanded
    }

    func toggle(_ section: PanelSection) {
        setExpanded(!isExpanded(section), section)
    }

    /// Headers of non-empty sections, followed by their PRs when expanded: what ↑/↓ walk through.
    func items(in sections: [PanelSection]) -> [PanelItem] {
        sections.filter { !$0.entries.isEmpty }.flatMap { section in
            [PanelItem.section(section.id)] + (isExpanded(section) ? section.entries.map { .pr($0.id) } : [])
        }
    }

    func move(_ delta: Int, in sections: [PanelSection]) {
        let items = items(in: sections)
        guard !items.isEmpty else { selection = nil; return }
        if let selection, let index = items.firstIndex(of: selection) {
            self.selection = items[max(0, min(items.count - 1, index + delta))]
        } else {
            // Start on the first PR rather than the first header.
            selection = delta > 0 ? (items.first { if case .pr = $0 { true } else { false } } ?? items.first) : items.last
        }
    }

    /// The section containing the current selection.
    func selectedSection(in sections: [PanelSection]) -> PanelSection? {
        switch selection {
        case let .section(id): sections.first { $0.id == id }
        case let .pr(id): sections.first { $0.entries.contains { $0.id == id } }
        case nil: nil
        }
    }

    /// ← collapses the selected section (moving the selection to its header); → expands it.
    func setSelectedSectionExpanded(_ expanded: Bool, in sections: [PanelSection]) {
        guard let section = selectedSection(in: sections) else { return }
        setExpanded(expanded, section)
        if !expanded { selection = .section(section.id) }
    }

    /// Expands or collapses every section at once (⌥← / ⌥→).
    func setAllExpanded(_ expanded: Bool, in sections: [PanelSection]) {
        for section in sections { setExpanded(expanded, section) }
        if !expanded, let section = selectedSection(in: sections) { selection = .section(section.id) }
    }
}
