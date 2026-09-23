#if DEBUG
import AppKit
import SwiftUI

/// Только для Debug-сборки: создаёт скриншоты для публикации.
/// Использование: TUNNELSIDE_DEV_AGENT=1 TUNNELSIDE_SCREENSHOT_DIR=<папка> Tunnelside.app/Contents/MacOS/Tunnelside
/// Приложение по очереди переключает страницы и светлое / тёмное оформление, снимает своё главное окно (разрешение на запись экрана не нужно) и завершается.
@MainActor
enum ScreenshotMode {
    private static var started = false

    static func startIfRequested(navigation: AppNavigation) {
        guard !started, let dir = ProcessInfo.processInfo.environment["TUNNELSIDE_SCREENSHOT_DIR"] else { return }
        started = true
        Task { await run(outputDirectory: URL(fileURLWithPath: dir), navigation: navigation) }
    }

    private static func run(outputDirectory: URL, navigation: AppNavigation) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let pages: [(AppNavigation.Section, String)] = [(.rules, "rules"), (.routeTable, "routetable"), (.diagnostics, "diagnostics"), (.logs, "logs"), (.settings, "settings")]
        await pause(3)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(AppWindow.mainID) == true }) else {
            print("screenshot: main window not found")
            exit(1)
        }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (section, name) in pages {
                if section == .diagnostics {
                    navigation.diagnose(ProcessInfo.processInfo.environment["TUNNELSIDE_SCREENSHOT_DIAGNOSE"] ?? "example.com")
                } else {
                    navigation.section = section
                }
                window.orderFrontRegardless()
                await pause(section == .diagnostics ? 7 : 1.5)
                capture(window, to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        exit(0)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            print("screenshot: capture failed for \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("screenshot: \(url.lastPathComponent) \(image.width)x\(image.height)")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
#endif
