import ServiceManagement
import ShipKit
import SwiftUI

struct SettingsView: View {
    let store: ShipStore

    private enum Tab: String, CaseIterable { case general = "General", groups = "Groups" }
    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            switch tab {
            case .general: GeneralSettings(store: store)
            case .groups: GroupsEditor(store: store)
            }
        }
        .frame(height: 540)
    }
}

private struct GeneralSettings: View {
    let store: ShipStore

    @AppStorage(Prefs.refreshSeconds) private var refreshSeconds = 60
    @AppStorage(Prefs.mergedWindowDays) private var mergedWindowDays = 3
    @AppStorage(Prefs.notifications) private var notifications = true
    @AppStorage(Prefs.activeWithinDays) private var activeWithinDays = 30
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var token = ""

    var body: some View {
        Form {
            Picker("Refresh every", selection: $refreshSeconds) {
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("2 minutes").tag(120)
                Text("5 minutes").tag(300)
            }
            Picker("Show landed PRs from", selection: $mergedWindowDays) {
                Text("Last day").tag(1)
                Text("Last 3 days").tag(3)
                Text("Last week").tag(7)
            }
            Picker("Hide open PRs idle for", selection: $activeWithinDays) {
                Text("2 weeks").tag(14)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Never hide").tag(0)
            }
            Toggle("Notify on status changes", isOn: $notifications)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Section("GitHub token") {
                LabeledContent("Using", value: store.tokenSource?.rawValue ?? "none")
                SecureField("Paste a token to override", text: $token)
                HStack {
                    if store.tokenSource == .keychain {
                        Button("Forget Saved Token") { store.clearSavedToken() }
                    }
                    Spacer()
                    Button("Save") { store.saveToken(token); token = "" }.disabled(token.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: refreshSeconds) { store.restart() }
        .onChange(of: mergedWindowDays) { store.restart() }
        .onChange(of: activeWithinDays) { store.restart() }
    }
}

private struct GroupsEditor: View {
    let store: ShipStore

    var body: some View {
        Form {
            Section {
                Text("Groups pull matching PRs out of the regular sections into their own collapsible section. A PR joins the first group that matches it. Quiet groups don't count toward the menu bar badge and don't send notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    _ = store.addGroup(name: "New Group")
                } label: {
                    Label("New Group", systemImage: "plus")
                }
            }
            ForEach(store.groups) { group in
                GroupEditor(store: store, group: group)
            }
            Section("Filter syntax") {
                Text("Like a GitHub search. Every term in a rule must match, and a group matches if any of its rules do. Qualifiers: `repo:` `org:` `author:` `label:` `title:` `is:draft|open|merged|authored|review-requested|reviewed`. Use `*` wildcards, `\"quoted phrases\"`, and a leading `-` to negate. Plain words match the title.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GroupEditor: View {
    let store: ShipStore
    let group: PRGroup
    @State private var draft = ""

    var body: some View {
        Section {
            TextField("Name", text: binding(\.name))
            Toggle("Quiet (no badge or notifications)", isOn: binding(\.quiet))
            ForEach(group.rules, id: \.self) { rule in
                let filter = PRFilter(rule)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule).font(.callout.monospaced()).textSelection(.enabled)
                        if let error = filter.errors.first {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Text(countText(store.matchCount(filter))).font(.caption).foregroundStyle(.secondary)
                    Button { remove(rule) } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove rule")
                }
            }
            HStack {
                TextField("Add rule", text: $draft, prompt: Text("repo:org/* author:dependabot label:wip"))
                    .font(.callout.monospaced())
                    .onSubmit(add)
                Button("Add", action: add).disabled(preview?.isValid != true)
            }
            if let preview {
                Text(preview.errors.first ?? "Matches \(countText(store.matchCount(preview))) right now")
                    .font(.caption)
                    .foregroundStyle(preview.errors.isEmpty ? Color.secondary : .red)
            }
        } header: {
            HStack {
                Text(group.name)
                Spacer()
                Button(role: .destructive) { store.deleteGroup(group) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete group")
            }
        }
    }

    private var preview: PRFilter? {
        let text = draft.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : PRFilter(text)
    }

    private func countText(_ n: Int) -> String { n == 1 ? "1 PR" : "\(n) PRs" }

    private func binding<T>(_ keyPath: WritableKeyPath<PRGroup, T>) -> Binding<T> {
        Binding(
            get: { group[keyPath: keyPath] },
            set: { value in
                var copy = group
                copy[keyPath: keyPath] = value
                store.updateGroup(copy)
            }
        )
    }

    private func add() {
        guard preview?.isValid == true else { return }
        store.addRule(draft, to: group.id)
        draft = ""
    }

    private func remove(_ rule: String) {
        var copy = group
        copy.rules.removeAll { $0 == rule }
        store.updateGroup(copy)
    }
}
