import Foundation

public enum RouteConstants {
    public static let appBundleID = "com.hyperits.app.MacOSRoute"
    public static let helperLabel = "com.hyperits.app.MacOSRoute.helper"
    public static let machServiceName = helperLabel
    /// Идентификаторы службы из старых версий — удаляются при установке / удалении
    public static let legacyHelperLabels = ["com.castorworks.macosroute.helper"]

    /// Увеличивать после изменения поведения службы — приложение предложит обновить установленную службу.
    public static let helperVersion = "1.2.0"

    public static let helperInstallPath = "/Library/PrivilegedHelperTools/\(helperLabel)"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/\(helperLabel).plist"
    public static let supportDirectory = "/Library/Application Support/MacOSRoute"
    public static let helperLogPath = "/Library/Logs/MacOSRoute/helper.log"
}
