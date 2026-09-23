import AppKit
import RouteShared
import SwiftUI

@main
struct TunnelsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client: HelperClient
    @StateObject private var navigation: AppNavigation

    init() {
        // Before the first views are created: all interface texts go through L(...)
        AppLanguage.current = .system
        _client = StateObject(wrappedValue: HelperClient())
        _navigation = StateObject(wrappedValue: AppNavigation())
    }

    var body: some Scene {
        Window("Tunnelside", id: AppWindow.mainID) {
            MainView()
                .environmentObject(client)
                .environmentObject(navigation)
                .frame(minWidth: 900, minHeight: 520)
                .onAppear { AppWindow.mainWindowDidAppear() }
                .onDisappear { AppWindow.mainWindowDidDisappear() }
        }
        .defaultSize(width: 1080, height: 640)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(client)
                .environmentObject(navigation)
        } label: {
            MenuBarLabel(symbol: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        guard client.status == .running, client.state?.gateway != nil else { return "exclamationmark.triangle" }
        return client.isPaused ? "pause.circle" : "arrow.triangle.branch"
    }
}

/// Menu bar icon; also keeps openWindow so code outside views (for example, AppDelegate) can open the main window
private struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear { AppWindow.openWindowAction = openWindow }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shows the main window when the app is reopened from Finder, Spotlight or the Dock
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppWindow.showMain() }
        return false
    }
}

@MainActor
enum AppWindow {
    static let mainID = "main"
    static var openWindowAction: OpenWindowAction?

    /// Opens the main window and brings it to the front.
    /// For a menu bar app (LSUIElement) on macOS 14+ with cooperative activation, openWindow alone is not enough — the window stays behind other apps,
    /// so we first switch to a regular app, then explicitly bring the window forward.
    static func showMain(_ openWindow: OpenWindowAction? = nil) {
        if let openWindow { openWindowAction = openWindow }
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            bringToFront(window)
        } else {
            openWindowAction?(id: mainID)
        }
        NSApp.activate()
        // The new window appears only on the next run loop pass
        DispatchQueue.main.async {
            if let window = mainWindow { bringToFront(window) }
            NSApp.activate()
        }
    }

    static func mainWindowDidAppear() {
        NSApp.setActivationPolicy(.regular)
        if let window = mainWindow { bringToFront(window) }
        NSApp.activate()
    }

    static func mainWindowDidDisappear() {
        // After the main window closes, go back to menu bar mode (no Dock icon)
        DispatchQueue.main.async {
            if mainWindow?.isVisible != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(mainID) == true && !($0 is NSPanel) }
    }

    private static func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
