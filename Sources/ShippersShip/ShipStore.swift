import Foundation
import Observation
import ShipKit
import UserNotifications

struct Entry: Identifiable, Hashable {
    let pr: PullRequest
    let status: ShipStatus
    var id: String { pr.id }
}

enum Prefs {
    static let refreshSeconds = "refreshSeconds"
    static let mergedWindowDays = "mergedWindowDays"
    static let notifications = "notificationsEnabled"
    static let activeWithinDays = "activeWithinDays"
    static let groups = "groups"
    /// Pre-groups ignore rules; migrated into an "Ignored" group on first launch.
    static let legacyIgnoreRules = "ignoreRules"

    static func register() {
        UserDefaults.standard.register(defaults: [
            refreshSeconds: 60,
            mergedWindowDays: 3,
            notifications: true,
            activeWithinDays: 30,
        ])
    }
}

@MainActor
@Observable
final class ShipStore {
    /// Everything fetched.
    private(set) var allEntries: [Entry] = [] { didSet { applyGroups() } }
    /// Entries not claimed by any group; these fill the built-in sections.
    private(set) var entries: [Entry] = []
    /// Entries claimed by each group, attention first, then open, then landed.
    private(set) var groupedEntries: [UUID: [Entry]] = [:]
    private(set) var groups: [PRGroup] = []
    private(set) var viewer: String?
    private(set) var tokenSource: TokenProvider.Source?
    private(set) var lastUpdated: Date?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var needsToken = false

    /// Labels defined in each repo, loaded on demand by the label picker.
    private(set) var repoLabels: [String: [RepoLabel]] = [:]
    private var token: String?

    private var loop: Task<Void, Never>?
    private var previousKinds: [String: StatusKind]?

    /// Moving on its own: deploying right now first, then in the merge queue by position.
    var watching: [Entry] {
        let deploying = entries.filter { $0.status.kind == .deploying }
        let queued = entries.filter { $0.status.kind == .queued }
            .sorted { ($0.pr.queuePosition ?? .max) < ($1.pr.queuePosition ?? .max) }
        return deploying + queued
    }
    private func isWatching(_ e: Entry) -> Bool { e.status.kind == .deploying || e.status.kind == .queued }
    var attention: [Entry] { entries.filter(\.status.needsAttention) }
    /// What the menu bar badge counts: "Needs you" plus attention items in groups that aren't quiet.
    var badgeEntries: [Entry] {
        attention + groups.filter { !$0.quiet }.flatMap { (groupedEntries[$0.id] ?? []).filter(\.status.needsAttention) }
    }
    var authored: [Entry] { entries.filter { !$0.status.needsAttention && !isWatching($0) && $0.pr.isOpen && !$0.pr.isDraft && $0.pr.relations.contains(.authored) } }
    var drafts: [Entry] { entries.filter { !$0.status.needsAttention && $0.pr.isOpen && $0.pr.isDraft && $0.pr.relations.contains(.authored) } }
    var reviewing: [Entry] { entries.filter { !$0.status.needsAttention && !isWatching($0) && $0.pr.isOpen && !$0.pr.relations.contains(.authored) } }
    var landed: [Entry] { entries.filter { !$0.status.needsAttention && !isWatching($0) && $0.pr.isMerged } }

    /// Demo stores use made-up data, never hit the network, and don't save groups.
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        Prefs.register()
        if demo {
            viewer = DemoData.viewer
            repoLabels = DemoData.labels
            tokenSource = .environment
            groups = DemoData.groups
            allEntries = DemoData.pullRequests().map { Entry(pr: $0, status: ShipStatus(for: $0)) }
            lastUpdated = .now
        } else {
            groups = Self.loadGroups()
        }
    }

    // MARK: - Labels

    func entry(id: String) -> Entry? {
        allEntries.first { $0.id == id }
    }

    func loadLabels(for repo: String, force: Bool = false) async {
        guard force || repoLabels[repo] == nil, let token else { return }
        do {
            repoLabels[repo] = try await GitHubClient(token: token).labels(inRepo: repo)
        } catch {
            errorMessage = "Couldn't load labels for \(repo): \(error.localizedDescription)"
        }
    }

    /// Adds or removes a label. The UI updates immediately and is reverted if GitHub refuses.
    func toggle(_ label: RepoLabel, on prID: String) async {
        guard let entry = entry(id: prID) else { return }
        let applied = entry.pr.labels.contains { $0.name == label.name }
        let before = entry.pr.labels
        setLabels(applied ? before.filter { $0.name != label.name } : before + [PRLabel(name: label.name, color: label.color)], on: prID)
        guard !isDemo, let token else { return }
        do {
            let result = try await GitHubClient(token: token).updateLabels(
                pullRequestID: prID, add: applied ? [] : [label.id], remove: applied ? [label.id] : []
            )
            setLabels(result, on: prID)
        } catch {
            setLabels(before, on: prID)
            errorMessage = "Couldn't \(applied ? "remove" : "add") “\(label.name)”: \(error.localizedDescription)"
        }
    }

    private func setLabels(_ labels: [PRLabel], on prID: String) {
        guard let index = allEntries.firstIndex(where: { $0.id == prID }) else { return }
        var pr = allEntries[index].pr
        pr.labels = labels
        allEntries[index] = Entry(pr: pr, status: ShipStatus(for: pr))
    }

    // MARK: - Groups

    func addGroup(name: String, rules: [String] = []) -> PRGroup {
        let group = PRGroup(name: name, rules: rules)
        saveGroups(groups + [group])
        return group
    }

    func updateGroup(_ group: PRGroup) {
        saveGroups(groups.map { $0.id == group.id ? group : $0 })
    }

    func deleteGroup(_ group: PRGroup) {
        saveGroups(groups.filter { $0.id != group.id })
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var copy = groups
        copy.move(fromOffsets: source, toOffset: destination)
        saveGroups(copy)
    }

    func addRule(_ rule: String, to groupID: UUID) {
        let rule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty, var group = groups.first(where: { $0.id == groupID }), !group.rules.contains(rule) else { return }
        group.rules.append(rule)
        updateGroup(group)
    }

    /// How many fetched PRs a filter matches, regardless of which group ends up claiming them.
    func matchCount(_ filter: PRFilter) -> Int {
        allEntries.filter { filter.matches($0.pr) }.count
    }

    func group(for pr: PullRequest) -> PRGroup? {
        PRGroup.group(for: pr, in: groups)
    }

    private func saveGroups(_ newGroups: [PRGroup]) {
        groups = newGroups
        if !isDemo, let data = try? JSONEncoder().encode(newGroups) {
            UserDefaults.standard.set(data, forKey: Prefs.groups)
        }
        applyGroups()
    }

    private static func loadGroups() -> [PRGroup] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Prefs.groups),
           let groups = try? JSONDecoder().decode([PRGroup].self, from: data) {
            return groups
        }
        // Migrate ignore rules from earlier versions.
        guard let legacy = defaults.stringArray(forKey: Prefs.legacyIgnoreRules), !legacy.isEmpty else { return [] }
        let groups = [PRGroup(name: "Ignored", rules: legacy, quiet: true)]
        if let data = try? JSONEncoder().encode(groups) {
            defaults.set(data, forKey: Prefs.groups)
            defaults.removeObject(forKey: Prefs.legacyIgnoreRules)
        }
        return groups
    }

    private func applyGroups() {
        var ungrouped: [Entry] = []
        var grouped: [UUID: [Entry]] = [:]
        for entry in allEntries {
            if let group = group(for: entry.pr) {
                grouped[group.id, default: []].append(entry)
            } else {
                ungrouped.append(entry)
            }
        }
        // Keep the time ordering within each tier.
        func tier(_ e: Entry) -> Int { e.status.needsAttention ? 0 : e.pr.isOpen ? 1 : 2 }
        entries = ungrouped
        groupedEntries = grouped.mapValues { list in
            list.enumerated().sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }.map(\.element)
        }
    }

    func start() {
        guard loop == nil, !isDemo else { return }
        Notifier.requestAuthorization()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = max(UserDefaults.standard.integer(forKey: Prefs.refreshSeconds), 15)
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    /// Restart the polling loop, e.g. after the token or interval changes.
    func restart() {
        loop?.cancel()
        loop = nil
        start()
    }

    func refresh() async {
        guard !isLoading, !isDemo else { return }
        isLoading = true
        defer { isLoading = false }

        guard let (token, source) = await TokenProvider.resolve() else {
            needsToken = true
            errorMessage = nil
            return
        }
        needsToken = false
        tokenSource = source
        self.token = token

        do {
            let days = UserDefaults.standard.integer(forKey: Prefs.mergedWindowDays)
            let active = UserDefaults.standard.integer(forKey: Prefs.activeWithinDays)
            let snapshot = try await GitHubClient(token: token).fetch(mergedWithinDays: days, activeWithinDays: active)
            viewer = snapshot.viewer
            let newEntries = snapshot.pullRequests
                .map { Entry(pr: $0, status: ShipStatus(for: $0)) }
                .sorted(by: Self.order)
            notifyTransitions(newEntries)
            allEntries = newEntries
            lastUpdated = .now
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveToken(_ token: String) {
        Keychain.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        restart()
    }

    func clearSavedToken() {
        Keychain.delete()
        restart()
    }

    private static func order(_ a: Entry, _ b: Entry) -> Bool {
        (a.pr.mergedAt ?? a.pr.updatedAt) > (b.pr.mergedAt ?? b.pr.updatedAt)
    }

    // MARK: - Notifications

    /// Kinds worth interrupting for when a PR moves into them.
    private static let notableKinds: Set<StatusKind> = [
        .reviewRequested, .changesRequested, .ciFailing, .conflicts, .ready,
        .queueFailed, .merged, .deployed, .deployFailed,
    ]

    private func notifyTransitions(_ newEntries: [Entry]) {
        let kinds = Dictionary(newEntries.map { ($0.id, $0.status.kind) }, uniquingKeysWith: { a, _ in a })
        defer { previousKinds = kinds }
        // Stay quiet on the first load so launching the app doesn't spam.
        guard let previous = previousKinds,
              UserDefaults.standard.bool(forKey: Prefs.notifications) else { return }

        for entry in newEntries where group(for: entry.pr)?.quiet != true {
            let kind = entry.status.kind
            guard Self.notableKinds.contains(kind), previous[entry.id] != kind else { continue }
            // A reviewer only cares about new review requests and failures on PRs they merged.
            if !entry.pr.relations.contains(.authored), !entry.status.needsAttention { continue }
            Notifier.post(
                id: "\(entry.id)-\(kind.rawValue)",
                title: entry.status.headline,
                subtitle: "\(entry.pr.repo)#\(entry.pr.number)",
                body: entry.pr.title,
                url: entry.pr.url
            )
        }
    }
}

enum Notifier {
    /// UNUserNotificationCenter crashes when there's no app bundle (e.g. `swift run`).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(id: String, title: String, subtitle: String, body: String, url: URL) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.userInfo = ["url": url.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
