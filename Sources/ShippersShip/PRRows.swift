import ShipKit
import SwiftUI

/// Opens a link in the browser. Refuses anything that isn't http(s); see `URL.isWebURL`.
@discardableResult
func openWeb(_ url: URL) -> Bool {
    guard url.isWebURL else { return false }
    return NSWorkspace.shared.open(url)
}

struct PRSection: View {
    let section: PanelSection
    @Environment(PanelState.self) private var panel

    var body: some View {
        if !section.entries.isEmpty {
            let expanded = panel.isExpanded(section)
            let selected = panel.selection == .section(section.id)
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.snappy) { panel.toggle(section) } } label: {
                    HStack(spacing: 4) {
                        Label {
                            Text(verbatim: "\(section.group == nil ? section.title.uppercased() : section.title)  \(section.entries.count)")
                        } icon: {
                            Image(systemName: section.symbol)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer()
                        if !expanded, let summary = collapsedSummary {
                            Text(summary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.2) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(section.tint)
                .id(PanelItem.section(section.id).scrollID)
                .help(section.group.map { "Group: \($0.rules.joined(separator: " OR "))" } ?? section.title)
                if expanded {
                    // Open PRs get full cards; merged PRs get one-line rows, batched together. Order is kept.
                    ForEach(runs, id: \.first!.id) { run in
                        if run[0].pr.isMerged {
                            VStack(spacing: 0) {
                                ForEach(run) { CompactPRRow(entry: $0).id($0.id) }
                            }
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                        } else {
                            ForEach(run) { PRRow(entry: $0).id($0.id) }
                        }
                    }
                }
            }
        }
    }

    /// Consecutive entries split wherever merged-ness changes.
    private var runs: [[Entry]] {
        section.entries.reduce(into: [[Entry]]()) { runs, entry in
            if let last = runs.last?.last, last.pr.isMerged == entry.pr.isMerged {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
    }

    /// For collapsed groups: how many need attention, so nothing important hides silently.
    private var collapsedSummary: String? {
        guard section.group != nil else { return nil }
        let attention = section.entries.filter(\.status.needsAttention).count
        return attention > 0 ? "\(attention) need\(attention == 1 ? "s" : "") you" : nil
    }
}

struct PRRow: View {
    let entry: Entry
    @State private var hovering = false
    @Environment(PanelState.self) private var panel
    private var isSelected: Bool { panel.selection == .pr(entry.id) }

    private var pr: PullRequest { entry.pr }
    private var status: ShipStatus { entry.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(verbatim: "\(pr.repo)#\(pr.number)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if !pr.relations.contains(.authored) {
                    Text("@\(pr.author)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Badges(pr: pr)
                Text(age).font(.caption).foregroundStyle(.tertiary)
            }
            Text(pr.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(pr.isDraft ? .secondary : .primary)
            if !pr.labels.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(pr.labels, id: \.self) { LabelChip(label: $0) }
                }
            }
            HStack(alignment: .center, spacing: 10) {
                PipelineView(pipeline: status.pipeline)
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.headline)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.tone.color)
                        .lineLimit(1)
                    if let detail = status.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0))
        .overlay(alignment: .leading) {
            if status.needsAttention {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                    .fill(status.tone.color)
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { openWeb(pr.url) }
        .contextMenu { PRMenu(pr: pr) }
        .help(pr.title)
    }

    private var age: String { shortAge(pr.mergedAt ?? pr.updatedAt) }
}

/// One-line row for landed PRs: status icon, short repo#number, title, deploy state, age.
struct CompactPRRow: View {
    let entry: Entry
    @State private var hovering = false
    @Environment(PanelState.self) private var panel
    private var isSelected: Bool { panel.selection == .pr(entry.id) }

    private var pr: PullRequest { entry.pr }
    private var status: ShipStatus { entry.status }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(status.tone.color)
                .symbolEffect(.pulse, isActive: status.kind == .deploying)
                .frame(width: 14)
            Text(verbatim: "\(pr.repo.split(separator: "/").last ?? "")#\(pr.number)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(pr.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(shortStatus)
                .font(.caption2.weight(.medium))
                .foregroundStyle(status.tone.color)
                .lineLimit(1)
                .fixedSize()
            Text(age)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.2) : hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { openWeb(pr.url) }
        .contextMenu { PRMenu(pr: pr) }
        .help("\(pr.repo)#\(pr.number): \(pr.title)\n\(status.headline)" + (status.detail.map { "\n\($0)" } ?? ""))
    }

    private var symbol: String {
        switch status.kind {
        case .deployed: pr.isLive ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill"
        case .deploying: "arrow.up.circle.fill"
        case .deployFailed: "xmark.octagon.fill"
        default: "arrow.triangle.merge"
        }
    }

    /// Environments are listed in the tooltip; the row keeps just the state.
    private var shortStatus: String {
        let n = pr.deployments.count > 1 ? " ×\(pr.deployments.count)" : ""
        if pr.isLive, status.kind == .deployed {
            return pr.liveEnvironments.count > 1 ? "live ×\(pr.liveEnvironments.count)" : "live"
        }
        switch status.kind {
        case .deployed: return "deployed\(n)"
        case .deploying: return "deploying\(n)"
        case .deployFailed: return "deploy failed"
        default: return "merged"
        }
    }

    private var age: String { shortAge(pr.mergedAt ?? pr.updatedAt) }
}

struct PRMenu: View {
    let pr: PullRequest
    @Environment(ShipStore.self) private var store
    @Environment(PanelState.self) private var panel

    var body: some View {
        Button("Open Pull Request") { openWeb(pr.url) }
        Button("Labels…") {
            panel.selection = .pr(pr.id)
            panel.labelingID = pr.id
        }
        if pr.isOpen && pr.relations.contains(.authored) {
            if pr.isDraft {
                Button("Mark Ready for Review") { Task { await store.setDraft(false, on: pr.id) } }
            } else {
                Button("Convert to Draft") { Task { await store.setDraft(true, on: pr.id) } }
                    .disabled(pr.isInMergeQueue)
            }
        }
        Button("Open Checks") { openWeb(pr.checksURL) }
        if !pr.checks.failed.isEmpty {
            Menu("Failing Checks") {
                ForEach(pr.checks.failed, id: \.self) { check in
                    Button(check.name) { openWeb(check.url ?? pr.checksURL) }
                }
            }
        }
        if !pr.deployments.isEmpty {
            Menu("Deployments") {
                ForEach(pr.deployments, id: \.self) { d in
                    Button("\(d.environment) — \(d.state.lowercased())") {
                        if let url = d.logURL ?? d.environmentURL { openWeb(url) }
                    }
                }
            }
        }
        Divider()
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pr.url.absoluteString, forType: .string)
        }
        Menu("Move to Group") {
            let suggestions = FilterSuggestion.suggestions(for: pr)
            if let current = store.group(for: pr) {
                Text("Currently in “\(current.name)”")
                Divider()
            }
            ForEach(store.groups) { group in
                Menu(group.name) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion.title) { store.addRule(suggestion.rule, to: group.id) }
                    }
                }
            }
            if !store.groups.isEmpty { Divider() }
            Menu("New Group") {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button(suggestion.title) { _ = store.addGroup(name: suggestion.groupName, rules: [suggestion.rule]) }
                }
            }
        }
    }
}

/// "now", "12m", "3h", "2d", "5w", "1y"
func shortAge(_ date: Date, now: Date = .now) -> String {
    let s = max(0, now.timeIntervalSince(date))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<86400: return "\(Int(s / 3600))h"
    case ..<(86400 * 14): return "\(Int(s / 86400))d"
    case ..<(86400 * 365): return "\(Int(s / (86400 * 7)))w"
    default: return "\(Int(s / (86400 * 365)))y"
    }
}

/// Small icons for comment/thread activity and merge-queue/auto-merge flags.
struct Badges: View {
    let pr: PullRequest

    var body: some View {
        HStack(spacing: 6) {
            if pr.isLive {
                Text("LIVE")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(.green))
                    .help("Live on " + pr.liveEnvironments.joined(separator: ", "))
            }
            if pr.unresolvedThreads > 0 {
                Label("\(pr.unresolvedThreads)", systemImage: "text.bubble.fill")
                    .foregroundStyle(.orange)
                    .help("\(pr.unresolvedThreads) unresolved review threads")
            }
            if pr.totalComments > 0 {
                Label("\(pr.totalComments)", systemImage: "bubble.left")
                    .foregroundStyle(.secondary)
                    .help(pr.lastCommenter.map { "Last comment by @\($0)" } ?? "Comments")
            }
            if pr.autoMergeEnabled && !pr.isMerged {
                Image(systemName: "wand.and.stars").foregroundStyle(.blue).help("Auto-merge enabled")
            }
        }
        .labelStyle(CompactLabel())
        .font(.caption2)
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon; configuration.title }
    }
}

// MARK: - Pipeline
