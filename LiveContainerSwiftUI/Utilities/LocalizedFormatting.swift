import Foundation

/// Expand variadic values through Foundation's arguments initializer.
func LCFormatLocalizedString(_ format: String, locale: Locale = .current,
                             arguments: [CVarArg]) -> String {
    String(format: format, locale: locale, arguments: arguments)
}
