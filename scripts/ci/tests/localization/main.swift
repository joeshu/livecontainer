import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
let cases: [(String?, [String], String)] = [
    (nil, ["zh-CN"], "zh-Hans"), (nil, ["zh-SG"], "zh-Hans"),
    (nil, ["zh-TW"], "zh-Hant"), (nil, ["zh-HK"], "zh-Hant"),
    (nil, ["zh_MO"], "zh-Hant"), (nil, ["zh-Hans-HK"], "zh-Hans"),
    (nil, ["zh-Hant-CN"], "zh-Hant"), (nil, ["en-GB", "zh-TW"], "en"),
    ("system", ["fr-FR", "zh-TW"], "zh-Hant"), (nil, [], "en"),
    ("invalid", ["de-DE"], "en"), ("en", ["zh-TW"], "en"),
    ("zh-Hans", ["en-US"], "zh-Hans"), ("zh-Hant", ["zh-CN"], "zh-Hant")
]
for (preference, inherited, expected) in cases {
    expect(SideStoreLanguagePolicy.resolve(preference: preference, inheritedLanguages: inherited) == expected,
           "Language resolution failed: \(preference ?? "nil"), \(inherited)")
}
expect(SideStoreLanguagePolicy.inheritedLanguages(environment: ["LC_HOST_LANGUAGES": "[\"zh-Hant-HK\"]"], fallback: ["en"]) == ["zh-Hant-HK"], "Host snapshot lost")
for invalid in ["{", "[]", "[1]", "null"] {
    expect(SideStoreLanguagePolicy.inheritedLanguages(environment: ["LC_HOST_LANGUAGES": invalid], fallback: ["zh-CN"]) == ["zh-CN"], "Malformed snapshot must fall back")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let bundle = Bundle(url: root)!
for language in ["en", "zh-Hans", "zh-Hant"] {
    let result = LocalizedResourceLookup.text(bundle: bundle, language: language, key: "signing.title", fallback: "MISSING", table: "CombinedLocalizable")
    let expected = ["en": "Update Signature", "zh-Hans": "更新签名", "zh-Hant": "更新簽名"][language]!
    expect(result == expected, "Resource lookup failed for \(language): \(result)")
}
expect(LocalizedResourceLookup.text(bundle: bundle, language: "fr", key: "signing.title", fallback: "MISSING", table: "CombinedLocalizable") == "Update Signature", "Missing language must use English")
expect(LocalizedResourceLookup.text(bundle: bundle, language: "zh-Hant", key: "missing.key", fallback: "Readable fallback", table: "CombinedLocalizable") == "Readable fallback", "Missing key must use caller fallback")
expect(LCFormatLocalizedString("%2$lld items for %1$@ (100%%)", locale: Locale(identifier: "en_US_POSIX"), arguments: ["SideStore", Int64(42)]) == "42 items for SideStore (100%)", "Positional variadic formatting failed")
expect(LCFormatLocalizedString("%@ / %@ / %d", arguments: ["证书", "描述文件", Int32(7)]) == "证书 / 描述文件 / 7", "Mixed argument formatting failed")
print("PASS: \(cases.count) language cases, snapshot fallback, resource ownership, English fallback and mixed/positional formatting")
