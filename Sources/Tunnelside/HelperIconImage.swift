import AppKit
import SwiftUI

/// Background service icon from PNGs in Contents/Resources.
/// Only Xcode compiles Assets.xcassets, and the build uses `swift build`,
/// so the light/dark variant is picked here from the current appearance.
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
