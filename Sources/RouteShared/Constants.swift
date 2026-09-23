import Foundation

public enum RouteConstants {
    public static let appBundleID = "io.github.kirillkarmanov.Tunnelside"
    public static let helperLabel = "io.github.kirillkarmanov.Tunnelside.helper"
    public static let machServiceName = helperLabel
    /// Идентификаторы службы из старых версий — удаляются при установке / удалении
    public static let legacyHelperLabels = ["com.hyperits.app.MacOSRoute.helper", "com.castorworks.macosroute.helper"]
    /// Папка правил MacOSRoute, из которого вырос Tunnelside: при первой установке правила переносятся оттуда
    public static let legacySupportDirectory = "/Library/Application Support/MacOSRoute"

    /// Увеличивать после изменения поведения службы — приложение предложит обновить установленную службу.
    public static let helperVersion = "1.3.0"

    public static let helperInstallPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let supportDirectory = "/Library/Application Support/Tunnelside"
    public static let helperLogPath = "/Library/Logs/Tunnelside/helper.log"
}
