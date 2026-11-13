import Foundation

/// Looks up `key`, which is the English text, in Localizable.strings and fills in `args`.
///
/// Static SwiftUI literals (`Text("Save")`) are looked up the same way by SwiftUI itself. Use `L` for
/// anything with arguments and for text built outside a view. `scripts/check-strings.py` checks that
/// every key has a translation.
func L(_ key: String, _ args: CVarArg...) -> String {
    localized(key, args)
}

/// Picks the singular or plural key by `count`, which is also the first format argument.
func LN(_ count: Int, _ one: String, _ other: String, _ args: CVarArg...) -> String {
    localized(count == 1 ? one : other, [count] + args)
}

private func localized(_ key: String, _ args: [CVarArg]) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L("System Default")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    /// How to name the language when asking an agent to write in it.
    var promptName: String {
        self == .simplifiedChinese ? "Simplified Chinese (简体中文)" : "English"
    }

    /// The language the interface is in right now. Audits and merge notes are written in it too.
    static var active: AppLanguage {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    private static var domain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    /// The choice made in Settings. AppKit reads it once at launch, so a change applies the next time the app opens.
    static var saved: AppLanguage {
        get {
            let own = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
            return own?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }
}
