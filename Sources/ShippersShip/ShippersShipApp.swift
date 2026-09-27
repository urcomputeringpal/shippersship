import AppKit
import ShipKit
import SwiftUI
import UserNotifications

@main
struct ShippersShipApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = ShipStore()
    @State private var panel = PanelState()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store, panel: panel)
        } label: {
            MenuBarLabel(store: store)
                .task { store.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let store: ShipStore

    var body: some View {
        let attention = store.badgeEntries
        let failing = attention.contains { $0.status.tone == .bad }
        HStack(spacing: 3) {
            Image(systemName: failing ? "ferry.fill" : "ferry")
            if !attention.isEmpty {
                Text("\(attention.count)")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, even when launched via `swift run` without an Info.plist.
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Task { @MainActor in
                let store = ShipStore(demo: args.contains("--demo"))
                await store.refresh()
                await writeSnapshot(store: store, to: args[i + 1])
                NSApp.terminate(nil)
            }
            return
        }
        if let i = args.firstIndex(of: "--keytest") {
            let directory = i + 1 < args.count ? args[i + 1] : nil
            Task { @MainActor in
                let passed = await KeyTest.run(screenshotDirectory: directory)
                exit(passed ? 0 : 1)
            }
            return
        }
        #endif
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if let string = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: string) {
            await MainActor.run { _ = openWeb(url) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
