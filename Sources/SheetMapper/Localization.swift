import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "sheetmapper.language"
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var locale: Locale { self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue) }
    var displayName: String {
        switch self {
        case .system: return L10n.text("language.system")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

enum L10n {
    static var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.storageKey) ?? "system") ?? .system
    }

    static var bundle: Bundle {
        let code: String
        switch selectedLanguage {
        case .system:
            code = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        case .simplifiedChinese: code = "zh-Hans"
        case .english: code = "en"
        }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let localized = Bundle(path: path) else { return .main }
        return localized
    }

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: selectedLanguage.locale, arguments: arguments)
    }
}
