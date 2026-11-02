import AppKit
import SwiftUI
import UserNotifications

let githubURL = URL(string: "https://github.com/techtheoryio/pressure-cooker")!

/// assets/icons/icon-mono.svg, inlined so the bare SwiftPM build needs no resource bundle. A template image: macOS tints it.
@MainActor let menuBarIcon: NSImage = {
    let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><g stroke="#000" stroke-width="2.5" stroke-linecap="round"><line x1="10" y1="20" x2="10" y2="13"/><line x1="16" y1="20" x2="16" y2="10"/><line x1="22" y1="20" x2="22" y2="15"/></g><circle cx="10" cy="11" r="2.75" fill="#000"/><circle cx="16" cy="7.5" r="3.25" fill="#000"/><circle cx="22" cy="13" r="2.25" fill="none" stroke="#000" stroke-width="1.75"/><rect x="5" y="20" width="22" height="3.5" rx="1.75" fill="#000"/><path d="M7.5 23.5 H24.5 V24.5 A3 3 0 0 1 21.5 27.5 H10.5 A3 3 0 0 1 7.5 24.5 Z" fill="#000"/></svg>"##
    let image = NSImage(data: Data(svg.utf8))!
    image.size = NSSize(width: 18, height: 18)
    image.isTemplate = true
    return image
}()

@main
struct PressureCookerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView(compact: true)
        } label: {
            let count = store.snapshot?.attention ?? 0
            Image(nsImage: menuBarIcon)
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // the .app has LSUIElement; a bare SwiftPM executable needs this
        if isBundled {  // UNUserNotificationCenter crashes without a bundle identifier
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        _ = updater  // starts Sparkle's scheduled checks
        store.start()
        if let dir = ProcessInfo.processInfo.environment["PC_SNAPSHOT"] { Task { await writeSnapshots(to: URL(filePath: dir)) } }
    }

    /// Debug: PNGs of the list (compact and in a window) and each settings tab, light and dark, after the first refresh, then quit.
    /// With PC_DEMO=1 for made-up data; `-owners '(a, b)'` on the command line watches accounts without saving them.
    @MainActor private func writeSnapshots(to dir: URL) async {
        while store.lastRefresh == nil && store.error == nil { try? await Task.sleep(for: .milliseconds(200)) }
        func capture(_ name: String, _ window: NSWindow) async {
            try? await Task.sleep(for: .seconds(1.5))  // avatars load
            guard let view = window.contentView?.superview, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
        }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            await capture("compact-\(suffix)", Windows.show("Compact", DashboardView(compact: true)))
            await capture("window-\(suffix)", Windows.dashboard())
            for tab in SettingsTab.allCases {
                UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab")
                await capture("settings-\(tab.rawValue)-\(suffix)", Windows.settings())
            }
        }
        exit(0)
    }

    // Clicking a notification opens the PR or run.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let url = (response.notification.request.content.userInfo["url"] as? String).flatMap(URL.init) else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}

/// Plain AppKit windows: SwiftUI's Window/Settings scenes open behind other apps in an accessory app,
/// and a Window scene would also open at launch.
@MainActor
enum Windows {
    private static var open: [String: NSWindow] = [:]

    @discardableResult static func show(_ title: String, resizable: Bool = true, _ view: some View) -> NSWindow {
        let window = open[title] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = title
            w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName(title)
            open[title] = w
            return w
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @discardableResult static func dashboard() -> NSWindow { show("Pressure Cooker", DashboardView(compact: false)) }
    @discardableResult static func settings() -> NSWindow { show("Pressure Cooker Settings", resizable: false, SettingsView()) }
}
