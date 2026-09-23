import Foundation

/// Language of the interface and service messages. The app takes it from the system languages,
/// the service (a root daemon without a user locale) takes it from the configuration the app sends.
public enum AppLanguage: String, Codable, Sendable {
    case en, ru

    public static var current: AppLanguage = .en

    /// The first supported language in the system's preferred languages
    public static var system: AppLanguage {
        let preferred = Bundle.preferredLocalizations(from: ["en", "ru"], forPreferences: Locale.preferredLanguages).first
        return preferred == "ru" ? .ru : .en
    }
}

/// Text in the current language: `L("Rules", "Правила")`
public func L(_ en: String, _ ru: String) -> String {
    AppLanguage.current == .ru ? ru : en
}
