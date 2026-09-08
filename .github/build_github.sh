#!/bin/bash
set -euo pipefail

workdir="$(pwd)"
DYLIBIFY_URL="\${DYLIBIFY_URL:-https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify}"
DYLIBIFY_SHA256="\${DYLIBIFY_SHA256:-6d23f6a2fc4d8442f87caa1161aebe6ecaafd0e8c41ce205da007efb04fc82c7}"

curl -fsSL --retry 3 "$DYLIBIFY_URL" -o dylibify
printf '%s  %s\n' "$DYLIBIFY_SHA256" dylibify | shasum -a 256 -c -
chmod +x dylibify
command -v ldid >/dev/null 2>&1 || brew install ldid
command -v zip >/dev/null
command -v unzip >/dev/null

# move lc to working folder
archive_products="$archive_path.xcarchive/Products/Applications"
[[ -d "$archive_products/LiveContainer.app" ]] || {
    echo "LiveContainer.app is missing from the archive"
    exit 1
}
[[ -d "$archive_products/LiveContainer.app/PlugIns/LiveProcess.appex" ]] || {
    echo "LiveProcess.appex is missing from the archive"
    exit 1
}
[[ ! -e Payload ]] || {
    echo "Payload already exists; refusing to overwrite it"
    exit 1
}
mv "$archive_products" Payload

# temporarily move SideStore support framework before the standalone IPA is zipped
tmp="$(mktemp -d "$workdir/.sidestore-embed.XXXXXX")"
trap 'cd "$workdir"; rm -rf "$tmp" "$workdir/dylibify"' EXIT
mv Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework "$tmp/SideStoreSupport.framework"

zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

mv ./tmp/SideStoreSupport.framework Payload/LiveContainer.app/Frameworks

# put sidestore related keys into Info.plist and settings bundle
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups array' ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :INIntentsSupported array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Title string Open SideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Key string LCOpenSideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:DefaultValue bool false" ./Payload/LiveContainer.app/Settings.bundle/Root.plist

# Use a locally built, commit-pinned SideStore IPA for CI and release builds.
SIDESTORE_IPA_PATH="\${SIDESTORE_IPA_PATH:-}"
SIDESTORE_IPA_URL="\${SIDESTORE_IPA_URL:-}"
SIDESTORE_IPA_SHA256="\${SIDESTORE_IPA_SHA256:-}"

if [[ "\${CI:-}" == "true" ]]; then
    [[ -n "$SIDESTORE_IPA_PATH" ]] || {
        echo "CI builds must provide SIDESTORE_IPA_PATH"
        exit 1
    }
    [[ -n "$SIDESTORE_IPA_SHA256" ]] || {
        echo "CI builds must provide SIDESTORE_IPA_SHA256"
        exit 1
    }
fi

if [[ -n "$SIDESTORE_IPA_PATH" ]]; then
    [[ -f "$SIDESTORE_IPA_PATH" ]] || {
        echo "SideStore IPA does not exist: $SIDESTORE_IPA_PATH"
        exit 1
    }
    echo "Embedding locally built SideStore: $SIDESTORE_IPA_PATH"
    cp "$SIDESTORE_IPA_PATH" "$tmp/SideStore.ipa"
elif [[ "\${ALLOW_REMOTE_SIDESTORE:-false}" == "true" ]]; then
    [[ -n "$SIDESTORE_IPA_URL" ]] || {
        echo "ALLOW_REMOTE_SIDESTORE requires SIDESTORE_IPA_URL"
        exit 1
    }
    echo "Embedding explicitly allowed remote SideStore: $SIDESTORE_IPA_URL"
    curl -fsSL --retry 3 "$SIDESTORE_IPA_URL" -o "$tmp/SideStore.ipa"
else
    echo "No SideStore IPA supplied; refusing an unpinned fallback"
    exit 1
fi

ACTUAL_SIDESTORE_SHA256="$(shasum -a 256 "$tmp/SideStore.ipa" | awk '{print $1}')"
if [[ -n "$SIDESTORE_IPA_SHA256" ]]; then
    if [[ "$ACTUAL_SIDESTORE_SHA256" != "$SIDESTORE_IPA_SHA256" ]]; then
        echo "SideStore IPA checksum mismatch"
        echo "Expected: $SIDESTORE_IPA_SHA256"
        echo "Actual:   $ACTUAL_SIDESTORE_SHA256"
        exit 1
    fi
    echo "SideStore IPA checksum verified: $ACTUAL_SIDESTORE_SHA256"
else
    echo "Embedded SideStore SHA256: $ACTUAL_SIDESTORE_SHA256"
fi

(cd "$tmp" && unzip -q SideStore.ipa)

# SideStore
mv "$tmp/Payload/SideStore.app" ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework
./dylibify ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib
rm ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
ldid -S"" ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
cp ./.github/sidelc/LCAppInfo.plist ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/

# copy intents
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Intents.intentdefinition ./Payload/LiveContainer.app/
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/ViewApp.intentdefinition ./Payload/LiveContainer.app/
cp -r ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Metadata.appintents ./Payload/LiveContainer.app/Metadata.appintents
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata

# AltWidgetExtension
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/PlugIns/AltWidgetExtension.appex ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kdt.livecontainer.LiveWidget"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LiveWidgetExtension"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
mv ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/AltWidgetExtension ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Remove stale signatures from bundles whose Info.plist was rewritten.
if [[ -d "$workdir/.zsign_cache" ]]; then
    rm -rf "$workdir/.zsign_cache"
fi
find "$workdir/Payload" -type d -name "_CodeSignature" -prune -exec rm -rf {} +

ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Final structural preconditions before packaging.
[[ -d "$workdir/Payload/LiveContainer.app/PlugIns/LiveProcess.appex" ]] || {
    echo "Final payload lost LiveProcess.appex"
    exit 1
}
[[ -f "$workdir/Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore" ]] || {
    echo "Final payload lost embedded SideStore"
    exit 1
}
[[ -d "$workdir/Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex" ]] || {
    echo "Final payload lost LiveWidgetExtension.appex"
    exit 1
}

# package
zip -qr "$scheme+SideStore.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"