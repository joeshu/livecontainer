# LiveContainer + SideStore localization

SideStore offers Follow System, 简体中文, 繁體中文 and English. An explicit
choice applies to SideStore's guest defaults only and requires restarting it.
Follow System inherits the containing app's language list captured before
LiveContainer redirects guest preferences. Other guest language overrides are
unchanged. Unsupported languages fall back to English. The picker no longer
forces regional formatting to en_US or zh_CN; the old forced values are removed
when changing language.

Chinese scripts are distinct. Explicit Hans/Hant scripts take precedence over
region; zh-TW, zh-HK and zh-MO use Traditional Chinese, while zh-CN and zh-SG use
Simplified Chinese. Locale preferences remain ordered rather than treating any
Chinese entry in the list as the selected language.

## Resource ownership and wording

`SideStoreLocalization` locates the SideStore framework through a marker class.
Its stable `CombinedLocalizable` table contains language settings, signature
recovery and package validation. `LocalizedResourceLookup` falls back from the
selected language to English, then a readable caller default. Legacy strings
and storyboard fallbacks use the same owning bundle. The runtime storyboard
fallback looks up only its static interface allowlist and App ID count template;
app names and other model text are not passed through unrestricted catalog lookup.

Refresh coordinator errors use a separate `RefreshLocalizable` table owned by
SideStoreSupport and follow the containing app's language. Shortcut labels and
success text are included in the host string catalog. All current host keys
now include both Chinese scripts; previously missing storage, signing, emulator
and sharing copy was filled, and misleading Team ID / temporary-file wording
was corrected. Technical errors supplied
by Apple or other dependencies may retain the dependency's language.

Keep semantic keys independent of English wording. Format templates must be
localized before values are inserted. Preserve every printf argument position
and type; use the arguments initializer for Swift and a correctly initialized
va_list for Objective-C. Dates use the chosen display language with the current
region rather than forcing China or US formatting.

Preferred terminology:

| English | 简体中文 | 繁體中文 |
| --- | --- | --- |
| Update Signature | 更新签名 | 更新簽名 |
| Signing certificate | 签名证书 | 簽名憑證 |
| Provisioning profile | 描述文件 | 佈署描述檔 |
| Keychain | 钥匙串 | 鑰匙圈 |
| Widget extension | 小组件扩展 | 小工具擴充功能 |

Recovery copy distinguishes expiration, revocation, account/team changes and
missing keys. Creating a certificate for a free account explicitly warns about
revoking the previous certificate. Combined reinstall instructions say to keep
extensions and install over the existing app. Expiry dates identify the host
being signed. Recovery labels support multiline text and Dynamic Type. On iOS, the recovery
content scrolls above a fixed action bar, so long warnings and large text do not
cover the reinstall and later buttons.

Traditional Chinese legacy resources started from value-only OpenCC conversion,
followed by terminology corrections; resource IDs, English keys and placeholders
were preserved. This is a baseline, not a claim of complete human review of all
legacy pages. The critical recovery and language-setting copy was reviewed
separately. Future translation changes should be reviewed in context.

## Validation

CI applies the complete patch to the pinned SideStore revision, runs the existing
Chinese guards and `verify_combined_localization.py`, and executes production
Foundation language resolution, bundle lookup, English fallback and both Swift
and Objective-C formatting. The IPA verifier checks English recovery resources,
both Chinese resource directories, and the refresh coordinator's three tables.

Device QA before release: system/en/Hans/Hant choices across restarts, zh-HK and
zh-TW, host and guest language isolation, large text on small screens, VoiceOver,
expired versus revoked certificates, certificate/profile dates, refresh failure
messages, and reinstall preserving data and both extensions. CI compilation and
resource checks cannot establish actual iOS layout or private API behavior.
