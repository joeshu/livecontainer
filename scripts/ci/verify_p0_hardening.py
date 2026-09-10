#!/usr/bin/env python3
"""Static contract checks for P0 hardening.

This is intentionally Xcode-free. GitHub Actions still owns the real build
and device tests; this script prevents obvious security-regression diffs.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise AssertionError(f"missing {label}: {needle}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle in text:
        raise AssertionError(f"forbidden {label}: {needle}")


def main() -> int:
    archive = read("LiveContainerSwiftUI/Utilities/unarchive.m")
    install = read("LiveContainerSwiftUI/Views/AppList/LCAppListView.swift")
    shared = read("LiveContainer/LCSharedUtils.m")
    bootstrap = read("LiveContainer/LCBootstrap.m")
    app_model = read("LiveContainerSwiftUI/Models/LCAppModel.swift")
    launch_extension = read("LaunchAppExtension/LaunchAppExtension.swift")
    share_extension = read("ShareExtension/ShareExtensionViewModel.swift")
    cleanup = read("LiveContainerSwiftUI/Utilities/LCDataCleanupService.swift")
    tweak_loader = read("TweakLoader/TweakLoader.m")
    bootstrap_source = read("LiveContainer/LCBootstrap.m")
    live_process = read("LiveProcess/main.m")
    launch_bookmark_source = read("LaunchAppExtension/LaunchAppExtension.swift")
    share_bookmark_source = read("ShareExtension/ShareExtensionViewModel.swift")
    ipa_bookmark_source = read("LiveContainerSwiftUI/Views/AppList/LCAppListView.swift")
    tweak_bookmark_source = read("TweakLoader/UIKit+GuestHooks.m")

    for flag in (
        "ARCHIVE_EXTRACT_SECURE_NODOTDOT",
        "ARCHIVE_EXTRACT_SECURE_SYMLINKS",
        "ARCHIVE_EXTRACT_SAFE_WRITES",
    ):
        require(archive, flag, f"archive safety flag {flag}")
    for guard in (
        "LCMaxArchiveEntries",
        "LCMaxArchiveFileSize",
        "LCMaxArchiveTotalSize",
        "LCMaxArchivePathLength",
        "LCMaxArchivePathDepth",
        "archive_entry_symlink",
        "archive_entry_hardlink",
        "archive_entry_filetype",
        "seenPaths",
    ):
        require(archive, guard, f"archive guard {guard}")
    require(archive, "return ARCHIVE_FATAL", "archive failure return")
    require(install, 'appendingPathComponent("LiveContainerInstall"', "unique install root")
    require(install, "UUID().uuidString", "per-operation install ID")
    require(install, "defer { try? fm.removeItem(at: installRoot) }", "staging cleanup")
    require(install, "ownsInput: Bool = false", "source ownership flag")
    forbid(install, "try FileManager.default.removeItem(at: fileUrl)", "unconditional source deletion")
    require(shared, "LCIsSafePathComponent", "native deep-link component guard")
    require(shared, "LCAppInfoContainsContainer", "native container ownership guard")
    require(shared, "LCPendingLaunch", "atomic native pending launch")
    require(shared, "appBundle == nil", "bundle lookup failure guard")
    require(shared, "LCAppInfo.plist", "bundle metadata validation")
    for source, label in (
        (bootstrap, "bootstrap"),
        (app_model, "app model"),
        (launch_extension, "launch extension"),
        (share_extension, "share extension"),
    ):
        require(source, "requestID", f"{label} request ID")
        require(source, "createdAt", f"{label} request timestamp")
        if label != "app model":
            require(source, "targetScheme", f"{label} target scheme")
    require(bootstrap, "LCIsFreshBootstrapDate", "bootstrap TTL validation")
    require(bootstrap, "LCClearBootstrapPending", "ordinary pending consumption")
    require(bootstrap, "LCClearLaunchExtensionPending", "extension pending consumption")
    require(bootstrap, "LCValidateBootstrapLaunchTarget", "bootstrap target validation")
    require(app_model, '"LCPendingLaunch"', "ordinary atomic pending write")
    require(launch_extension, '"LCLaunchExtensionPending"', "extension atomic pending write")
    require(share_extension, '"LCLaunchExtensionPending"', "share atomic pending write")
    require(cleanup, '"LCPendingLaunch"', "ordinary pending cleanup")
    require(cleanup, '"LCLaunchExtensionPending"', "extension pending cleanup")

    # Phase 1 path-boundary contracts.
    container = read("LiveContainerSwiftUI/Models/LCContainer.swift")
    storage = read("LiveContainerSwiftUI/Models/LCStorageManagementModel.swift")
    swift_shared = read("LiveContainerSwiftUI/Utilities/Shared.swift")
    require(shared, "@import Security", "Security entitlement API import")
    require(shared, "LCApplicationGroupEntitlements", "signed App Group lookup")
    require(shared, "LCIsKnownStoreAppGroup", "known App Group allowlist")
    require(shared, "cfans && CFGetTypeID", "Team ID null guard")
    require(container, "hasUsableStorage", "unusable bookmark state")
    require(container, "Bookmark must resolve to an accessible directory", "bookmark directory guard")
    require(container, "Do not fall back", "external bookmark no-fallback contract")
    require(storage, "Unable to access external container", "storage scoped-access failure")
    require(cleanup, "Unable to access external container", "cleanup scoped-access failure")
    require(cleanup, "resolvingSymlinksInPath", "cleanup canonical containment")
    require(swift_shared, "resolvingSymlinksInPath", "shared canonical containment")
    forbid(swift_shared, '"group.com.SideStore.SideStore")', "hardcoded App Group fallback")
    for source, label in (
        (container, "container bookmark"),
        (bootstrap_source, "bootstrap bookmark"),
        (live_process, "live process bookmark"),
        (launch_bookmark_source, "launch extension bookmark"),
        (share_bookmark_source, "share extension bookmark"),
        (ipa_bookmark_source, "IPA bookmark"),
        (tweak_bookmark_source, "tweak bookmark"),
    ):
        if "resolvingBookmarkData" in source or "URLByResolvingBookmarkData" in source:
            require(source, "withSecurityScope" if "resolvingBookmarkData" in source else "NSURLBookmarkResolutionWithSecurityScope", f"{label} security scope option")
    payload = read("LiveProcess/main.m")
    for guard in ("realpath", "S_ISREG", "RTLD_LOCAL", "dlclose(handle)", "custom payload entry not found"):
        require(payload, guard, f"custom payload guard {guard}")
    forbid(payload, "NSCAssert(appInfo, @\"Failed to load custom payload", "wrong custom payload assertion")
    for guard in (
        "LCPathIsUnderRoot",
        "LCPathHasSymlinkComponent",
        "LCIsRegularFile",
        "RTLD_LOCAL",
        "invalid CFBundleExecutable",
    ):
        require(tweak_loader, guard, f"tweak-loader guard {guard}")
    forbid(tweak_loader, "loadTweakAtURL(fileURL)", "unchecked tweak loader call")

    print("PASS: P0 hardening static contracts")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
