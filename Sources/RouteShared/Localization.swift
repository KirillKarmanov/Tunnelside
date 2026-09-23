import Foundation

/// Язык интерфейса и сообщений службы. Приложение берёт его из языков системы,
/// служба (root-демон без пользовательской локали) — из конфигурации, которую присылает приложение.
public enum AppLanguage: String, Codable, Sendable {
    case en, ru

    public static var current: AppLanguage = .en

    /// Первый из поддерживаемых языков в списке предпочитаемых языков системы
    public static var system: AppLanguage {
        let preferred = Bundle.preferredLocalizations(from: ["en", "ru"], forPreferences: Locale.preferredLanguages).first
        return preferred == "ru" ? .ru : .en
    }
}

/// Текст на текущем языке: `L("Rules", "Правила")`
public func L(_ en: String, _ ru: String) -> String {
    AppLanguage.current == .ru ? ru : en
}
