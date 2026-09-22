import AppKit
import SwiftUI

/// Иконка фоновой службы из PNG в Contents/Resources.
/// Каталог Assets.xcassets компилирует только Xcode, а сборка идёт через `swift build`,
/// поэтому светлый/тёмный вариант выбираем сами по текущей теме.
struct HelperIconImage: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = NSImage(named: colorScheme == .dark ? "HelperIcon-dark" : "HelperIcon") {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted").resizable().scaledToFit()
        }
    }
}
