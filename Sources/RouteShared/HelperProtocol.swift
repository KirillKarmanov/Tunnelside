import Foundation

/// XPC protocol between the app and the root service. Complex data is passed as JSON Data to avoid NSSecureCoding boilerplate.
/// Always bump RouteConstants.helperVersion when the protocol changes.
@objc(RouteHelperProtocol)
public protocol RouteHelperProtocol {
    /// Returns HelperState as JSON
    func fetchState(withReply reply: @escaping (Data?, String?) -> Void)
    /// Accepts HelperConfig as JSON. Its revision must equal the service's current revision,
    /// otherwise the configuration is not saved and conflict = true is returned — the caller retries on fresh state.
    /// Returns right after saving; the route sync runs in the background.
    func updateConfig(_ configData: Data, withReply reply: @escaping (_ error: String?, _ conflict: Bool) -> Void)
    /// Detect the gateway again, refresh domain addresses and apply all routes (returns after the sync)
    func reapplyAll(withReply reply: @escaping (String?) -> Void)
    /// Remove all routes added by the service and pause syncing (called before uninstalling)
    func removeAllRoutes(withReply reply: @escaping (String?) -> Void)
    /// Delete static routes not managed by Tunnelside (to clean up stale routes)
    func deleteSystemRoutes(_ addresses: [String], withReply reply: @escaping (String?) -> Void)
}
