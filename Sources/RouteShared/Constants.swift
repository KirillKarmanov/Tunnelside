import Foundation

public enum RouteConstants {
    public static let appBundleID = "io.github.kirillkarmanov.Tunnelside"
    public static let helperLabel = "io.github.kirillkarmanov.Tunnelside.helper"
    public static let machServiceName = helperLabel
    /// Service identifiers from earlier versions — removed on install / uninstall
    public static let legacyHelperLabels = ["com.hyperits.app.MacOSRoute.helper", "com.castorworks.macosroute.helper"]
    /// Rules folder of MacOSRoute, which Tunnelside grew out of: rules are carried over from it on first install
    public static let legacySupportDirectory = "/Library/Application Support/MacOSRoute"

    /// Bump after changing the service behavior — the app will offer to update the installed service.
    public static let helperVersion = "1.3.1"

    public static let helperInstallPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let supportDirectory = "/Library/Application Support/Tunnelside"
    public static let helperLogPath = "/Library/Logs/Tunnelside/helper.log"
}
