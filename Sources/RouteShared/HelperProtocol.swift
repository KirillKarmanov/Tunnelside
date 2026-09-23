import Foundation

/// XPC-протокол между приложением и root-службой. Сложные данные передаются как JSON Data, чтобы обойтись без шаблонного кода NSSecureCoding.
/// При изменении протокола обязательно увеличить RouteConstants.helperVersion.
@objc(RouteHelperProtocol)
public protocol RouteHelperProtocol {
    /// Возвращает HelperState в JSON
    func fetchState(withReply reply: @escaping (Data?, String?) -> Void)
    /// Принимает HelperConfig в JSON. Его revision должна совпадать с текущей revision службы,
    /// иначе конфигурация не сохраняется и возвращается conflict = true — вызывающий повторяет на свежем состоянии.
    /// Возвращает сразу после сохранения, синхронизация маршрутов идёт в фоне.
    func updateConfig(_ configData: Data, withReply reply: @escaping (_ error: String?, _ conflict: Bool) -> Void)
    /// Заново определить шлюз, обновить адреса доменов и применить все маршруты (возвращает после синхронизации)
    func reapplyAll(withReply reply: @escaping (String?) -> Void)
    /// Удалить все маршруты, добавленные службой, и поставить синхронизацию на паузу (вызывается перед удалением)
    func removeAllRoutes(withReply reply: @escaping (String?) -> Void)
    /// Удалить статические маршруты, которыми не управляет Tunnelside (для очистки устаревших маршрутов)
    func deleteSystemRoutes(_ addresses: [String], withReply reply: @escaping (String?) -> Void)
}
