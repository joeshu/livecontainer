import Foundation

private final class RefreshLocalizationBundleMarker: NSObject {}

enum RefreshLocalization {
    static let resourceBundle = Bundle(for: RefreshLocalizationBundleMarker.self)

    static func text(_ key: String, default fallback: String) -> String {
        // Coordinator failures belong to the containing app, whose preferences
        // remain separate from SideStore's guest language.
        let preferences: [String]
        if let snapshot = ProcessInfo.processInfo.environment["LC_HOST_LANGUAGES"],
           let data = snapshot.data(using: .utf8),
           let languages = try? JSONDecoder().decode([String].self, from: data),
           !languages.isEmpty {
            preferences = languages
        } else {
            preferences = Locale.preferredLanguages
        }
        let language = Bundle.preferredLocalizations(from: ["en", "zh-Hans", "zh-Hant"], forPreferences: preferences).first ?? "en"
        let missing = "__RefreshLocalizationMissing__"
        for code in [language, "en"] {
            guard let path = resourceBundle.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            let value = bundle.localizedString(forKey: key, value: missing, table: "RefreshLocalizable")
            if value != missing { return value }
        }
        return fallback
    }
}
