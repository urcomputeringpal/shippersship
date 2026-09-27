import ShipKit
import SwiftUI

struct ContentView: View {
    let store: ShipStore
    @State private var panel: PanelState
    @State private var showingSettings = false
    @State private var listHeight: CGFloat = 0
    @FocusState private var listFocused: Bool

    init(store: ShipStore, panel: PanelState = PanelState()) {
        self.store = store
        _panel = State(initialValue: panel)
    }

    var body: some View {
        VStack(spacing: 0) {
            Header(store: store, showingSettings: $showingSettings)
            Divider()
            if showingSettings {
                SettingsView(store: store)
            } else if store.needsToken {
                TokenSetupView(store: store)
            } else if let id = panel.labelingID {
                LabelPicker(store: store, prID: id) { panel.labelingID = nil }
            } else {
                list
            }
            Divider()
            Footer(store: store, hints: showingSettings || panel.labelingID != nil ? nil : panel.selection)
        }
        .frame(width: 440)
        .environment(store)
        .environment(panel)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            // Menu bar windows size to the content's minimum height, and a ScrollView's minimum is zero,
            // so pin the scroll area to the list's measured height (capped).
            ScrollView {
                PRList(store: store)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
            }
            .frame(height: min(max(listHeight, 80), 560))
            .onChange(of: panel.selection) { _, item in
                if let item { withAnimation(.snappy) { proxy.scrollTo(item.scrollID) } }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        // Focus once the list is actually onscreen: setting it in the same update that brings the list
        // back (e.g. closing the label picker) can be dropped on slower machines.
        .task { listFocused = true }
        .onKeyPress(.downArrow) { panel.move(1, in: store.sections); return .handled }
        .onKeyPress(.upArrow) { panel.move(-1, in: store.sections); return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let expand = press.key == .rightArrow
            withAnimation(.snappy) {
                if press.modifiers.contains(.option) {
                    panel.setAllExpanded(expand, in: store.sections)
                } else {
                    panel.setSelectedSectionExpanded(expand, in: store.sections)
                }
            }
            return .handled
        }
        .onKeyPress(keys: [.return, .space]) { press in
            switch panel.selection {
            case let .section(id):
                if let section = store.sections.first(where: { $0.id == id }) {
                    withAnimation(.snappy) { panel.toggle(section) }
                }
                return .handled
            case let .pr(id):
                guard press.key == .return, let entry = store.entry(id: id) else { return .ignored }
                openWeb(entry.pr.url)
                return .handled
            case nil:
                return .ignored
            }
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "lL")) { _ in
            guard let id = panel.selectedPRID, store.entry(id: id) != nil else { return .ignored }
            panel.labelingID = id
            return .handled
        }
        .onKeyPress(.escape) {
            guard panel.selection != nil else { return .ignored }
            panel.selection = nil
            return .handled
        }
    }
}

struct PRList: View {
    let store: ShipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = store.errorMessage {
                Banner(text: error)
            }
            ForEach(store.sections) { PRSection(section: $0) }
            if store.entries.isEmpty && store.lastUpdated != nil {
                EmptyState()
            }
        }
        .padding(12)
    }
}

#if DEBUG
/// Renders the whole panel (unscrolled) to a PNG: `ShippersShip --snapshot out.png [--demo]`.
/// Uses a real window rather than ImageRenderer, which can't draw buttons.
@MainActor
func writeSnapshot(store: ShipStore, to path: String) async {
    let view = VStack(spacing: 0) {
        Header(store: store, showingSettings: .constant(false))
        Divider()
        PRList(store: store)
        Divider()
        Footer(store: store, hints: nil)
    }
    .frame(width: 440)
    .fixedSize(horizontal: false, vertical: true)
    .environment(store)
    .environment(PanelState(persists: false))
    .background(Color(nsColor: .windowBackgroundColor))

    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(500))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    window.orderOut(nil)
}
#endif

struct Header: View {
    let store: ShipStore
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ferry.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Shippers Ship").font(.headline)
                Group {
                    if let viewer = store.viewer {
                        Text("@\(viewer)") + Text(updatedText)
                    } else {
                        Text("Getting PRs over the line")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("r")
                    .help("Refresh")
            }
            Button { showingSettings.toggle() } label: {
                Image(systemName: showingSettings ? "xmark.circle" : "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(12)
    }

    private var updatedText: String {
        guard let date = store.lastUpdated else { return "" }
        return " · updated " + date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

struct Footer: View {
    let store: ShipStore
    /// When something is selected, show the keys that apply to it instead of the summary.
    let hints: PanelItem?

    var body: some View {
        HStack {
            Text(hintText ?? summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summary: String {
        let open = store.entries.filter(\.pr.isOpen).count
        let shipping = store.entries.filter { $0.status.kind == .deploying || $0.status.kind == .queued }.count
        let grouped = store.groupedEntries.values.reduce(0) { $0 + $1.count }
        return "\(open) open · \(shipping) shipping · \(store.landed.count) landed" + (grouped > 0 ? " · \(grouped) grouped" : "")
    }

    private var hintText: String? {
        switch hints {
        case .section: "↑↓ move · ←→ collapse/expand · ⏎ toggle · ⌥←→ all"
        case .pr: "↑↓ move · ⏎ open · L labels · ← collapse · esc"
        case nil: nil
        }
    }
}

struct Banner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "water.waves").font(.largeTitle).foregroundStyle(.tertiary)
            Text("Calm seas. Nothing in flight.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

// MARK: - Sections & rows

struct TokenSetupView: View {
    let store: ShipStore
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect to GitHub", systemImage: "key.fill").font(.headline)
            Text("Shippers Ship uses your GitHub CLI login automatically. Run `gh auth login` in a terminal, or paste a personal access token with `repo` scope.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("ghp_… or github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button("Try gh again") { store.restart() }
                Spacer()
                Button("Save Token", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty)
            }
        }
        .padding(16)
    }

    private func save() {
        guard !token.isEmpty else { return }
        store.saveToken(token)
        token = ""
    }
}
