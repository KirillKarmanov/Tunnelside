import AppKit
import RouteShared
import SwiftUI

@main
struct TunnelsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client: HelperClient
    @StateObject private var navigation: AppNavigation

    init() {
        // До создания первых экранов: все тексты интерфейса берутся через L(...)
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

/// Иконка в строке меню; заодно сохраняет openWindow, чтобы главное окно мог открыть код вне вью (например, AppDelegate)
private struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear { AppWindow.openWindowAction = openWindow }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Показывает главное окно при повторном открытии приложения из Finder, Spotlight или Dock
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppWindow.showMain() }
        return false
    }
}

@MainActor
enum AppWindow {
    static let mainID = "main"
    static var openWindowAction: OpenWindowAction?

    /// Открывает главное окно и выводит его на передний план.
    /// У приложения строки меню (LSUIElement) в macOS 14+ с кооперативной активацией одного openWindow мало — окно остаётся позади других приложений,
    /// поэтому сначала переключаемся в обычное приложение, затем явно выводим окно вперёд.
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
        // Новое окно появляется только на следующем проходе run loop
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
        // После закрытия главного окна возвращаемся к режиму строки меню (без значка в Dock)
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
