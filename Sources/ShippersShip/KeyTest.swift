import AppKit
import SwiftUI

#if DEBUG
/// UI harness: `ShippersShip --keytest [screenshot-dir]` hosts the panel with demo data in a real window,
/// drives it with key events, and checks the selection/expansion state after each step.
/// Exits non-zero if any check fails.
@MainActor
enum KeyTest {
    static func run(screenshotDirectory: String?) async -> Bool {
        let store = ShipStore(demo: true)
        let panel = PanelState(persists: false)

        let host = NSHostingView(rootView: ContentView(store: store, panel: panel)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 440, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(800))

        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print(condition ? "  ✓ \(message)" : "  ✗ \(message)")
            if !condition { failures += 1 }
        }
        func expanded(_ id: String) -> Bool {
            store.sections.first { $0.id == id }.map(panel.isExpanded) ?? false
        }
        func shot(_ name: String) {
            guard let directory = screenshotDirectory, let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
        }
        func press(_ key: Key, option: Bool = false) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: option ? [.option] : [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) {
                    window.sendEvent(event)
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        func type(_ text: String) async {
            for c in text { await press(Key(characters: String(c), code: 0)) }
        }

        let firstPR = store.watching.first!.id
        let attentionPR = store.attention.first!.id
        let groupID = "group:\(store.groups[0].id.uuidString)"

        print("Section order")
        check(store.sections.first?.id == "watching", "Worth watching is the first section")
        check(store.watching.map(\.pr.number) == [475, 486, 489, 474], "deploying, then queued, then live (newest first)")
        check(store.watching.contains { $0.pr.isOpen && $0.pr.isLive }, "open PRs live on an environment are worth watching")
        check(!store.landed.contains { $0.status.kind == .deploying }, "deploying PRs aren't also in Landed")
        check(!store.authored.contains { $0.status.kind == .queued }, "queued PRs aren't also in Your PRs")
        let ids = store.sections.map(\.id)
        check(ids.firstIndex(of: groupID)! < ids.firstIndex(of: "landed")!, "groups come before Landed")


        print("Keyboard navigation")
        await press(.down)
        check(panel.selection == .pr(firstPR), "↓ selects the first PR")
        await press(.left)
        check(!expanded("watching") && panel.selection == .section("watching"), "← collapses its section and selects the header")
        await press(.right)
        check(expanded("watching"), "→ expands it again")
        await press(.down)
        check(panel.selection == .pr(firstPR), "↓ from the header moves into the section")
        await press(.up); await press(.return)
        check(!expanded("watching"), "⏎ on a header toggles it")
        await press(.space)
        check(expanded("watching"), "space on a header toggles it")

        print("Expand/collapse all")
        await press(.left, option: true)
        check(store.sections.allSatisfy { !panel.isExpanded($0) }, "⌥← collapses every section")
        check(panel.items(in: store.sections).allSatisfy { if case .section = $0 { true } else { false } }, "only headers remain navigable")
        await press(.right, option: true)
        check(store.sections.allSatisfy { panel.isExpanded($0) }, "⌥→ expands every section")
        try? await Task.sleep(for: .milliseconds(700))
        shot("1-expanded")

        print("Groups")
        check(store.groupedEntries[store.groups[0].id]?.count == 2, "dependabot PRs are pulled into their group")
        check(!store.attention.contains { $0.pr.author.hasPrefix("dependabot") }, "…and out of Needs you")
        check(!store.badgeEntries.contains { $0.pr.author.hasPrefix("dependabot") }, "quiet group doesn't count toward the badge")
        for _ in 0..<40 where panel.selection != .section(groupID) { await press(.down) }
        check(panel.selection == .section(groupID), "↓ reaches the group header")
        await press(.left)
        check(!expanded(groupID), "← collapses the group")
        shot("2-group-collapsed")

        print("Label picker")
        panel.selection = .pr(attentionPR)
        await press(Key(characters: "l", code: 37))
        check(panel.labelingID == attentionPR, "L opens the label picker")
        try? await Task.sleep(for: .milliseconds(300))
        await type("dprod")
        try? await Task.sleep(for: .milliseconds(300))
        shot("3-picker")
        await press(.return)
        try? await Task.sleep(for: .milliseconds(300))
        check(store.entry(id: attentionPR)?.pr.labels.contains { $0.name == "deploy:production" } == true, "“dprod” ⏎ adds deploy:production")
        await press(.escape)
        check(panel.labelingID == nil, "esc closes the picker")
        try? await Task.sleep(for: .milliseconds(500))
        await press(.down)
        check(panel.selection != .pr(attentionPR), "focus returns to the list")
        await press(.escape)
        check(panel.selection == nil, "esc clears the selection")

        print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
        return failures == 0
    }

    struct Key {
        let characters: String
        let code: UInt16
        static let down = Key(characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        static let up = Key(characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        static let left = Key(characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
        static let right = Key(characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        static let `return` = Key(characters: "\r", code: 36)
        static let space = Key(characters: " ", code: 49)
        static let escape = Key(characters: "\u{1b}", code: 53)
    }
}
#endif
