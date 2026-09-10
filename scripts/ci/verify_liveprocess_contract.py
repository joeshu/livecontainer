#!/usr/bin/env python3
"""Validate the LiveProcess reinstall/launch state contract.

The previous guard only searched for independent strings. This checker extracts
the relevant Objective-C function bodies and verifies the ordering and
relationship of the state transitions that protect against stale launches.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = ROOT / "LiveContainerSwiftUI/Utilities/LCUtils.m"
LIVE_PROCESS_SOURCE_PATH = ROOT / "LiveProcess/main.m"
SIDESTORE_REFRESH_SOURCE_PATH = ROOT / "SideStoreSupport/SideStore.swift"
APP_INFO_SOURCE_PATH = ROOT / "LiveContainerSwiftUI/Models/LCAppInfo.m"
MACHO_SOURCE_PATH = ROOT / "LiveContainer/LCMachOUtils.m"
APP_LIST_SOURCE_PATH = ROOT / "LiveContainerSwiftUI/Views/AppList/LCAppListView.swift"


def fail(message: str) -> "NoReturn":
    print(f"[liveprocess contract] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def extract_function(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        fail(f"missing function marker: {marker}")

    opening = source.find("{", start)
    if opening < 0:
        fail(f"missing opening brace after: {marker}")

    depth = 0
    in_string = False
    escaped = False
    in_line_comment = False
    in_block_comment = False
    index = opening

    while index < len(source):
        character = source[index]
        next_character = source[index + 1] if index + 1 < len(source) else ""

        if in_line_comment:
            if character == "\n":
                in_line_comment = False
        elif in_block_comment:
            if character == "*" and next_character == "/":
                in_block_comment = False
                index += 1
        elif in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        else:
            if character == "/" and next_character == "/":
                in_line_comment = True
                index += 1
            elif character == "/" and next_character == "*":
                in_block_comment = True
                index += 1
            elif character == '"':
                in_string = True
            elif character == "{":
                depth += 1
            elif character == "}":
                depth -= 1
                if depth == 0:
                    return source[start : index + 1]

        index += 1

    fail(f"unbalanced braces in: {marker}")


def require_all(body: str, markers: list[str], label: str) -> None:
    missing = [marker for marker in markers if marker not in body]
    if missing:
        fail(f"{label} is missing: {', '.join(missing)}")


def main() -> None:
    if not SOURCE_PATH.is_file():
        fail(f"missing source: {SOURCE_PATH.relative_to(ROOT)}")
    if not LIVE_PROCESS_SOURCE_PATH.is_file():
        fail(f"missing source: {LIVE_PROCESS_SOURCE_PATH.relative_to(ROOT)}")
    if not SIDESTORE_REFRESH_SOURCE_PATH.is_file():
        fail(f"missing source: {SIDESTORE_REFRESH_SOURCE_PATH.relative_to(ROOT)}")
    if not APP_INFO_SOURCE_PATH.is_file():
        fail(f"missing source: {APP_INFO_SOURCE_PATH.relative_to(ROOT)}")
    if not MACHO_SOURCE_PATH.is_file():
        fail(f"missing source: {MACHO_SOURCE_PATH.relative_to(ROOT)}")
    if not APP_LIST_SOURCE_PATH.is_file():
        fail(f"missing source: {APP_LIST_SOURCE_PATH.relative_to(ROOT)}")

    source = SOURCE_PATH.read_text(encoding="utf-8")
    live_process_source = LIVE_PROCESS_SOURCE_PATH.read_text(encoding="utf-8")
    sidestore_refresh_source = SIDESTORE_REFRESH_SOURCE_PATH.read_text(encoding="utf-8")
    app_info_source = APP_INFO_SOURCE_PATH.read_text(encoding="utf-8")
    macho_source = MACHO_SOURCE_PATH.read_text(encoding="utf-8")
    app_list_source = APP_LIST_SOURCE_PATH.read_text(encoding="utf-8")
    clear_body = extract_function(
        source, "static void LCClearPendingGuestLaunchState(void)"
    )
    diagnostics_body = extract_function(
        source, "static NSDictionary *LCCollectLiveProcessDiagnostics(void)"
    )
    wrapper_body = extract_function(
        source,
        "+ (void)launchMultitaskGuestApp:(NSString *)displayName "
        "completionHandler:",
    )
    launch_body = extract_function(
        source,
        "+ (void)launchMultitaskGuestApp:(NSString *)displayName "
        "remainingLiveProcessRetries:(NSUInteger)remainingRetries",
    )

    require_all(
        clear_body,
        [
            'removeObjectForKey:@"selected"',
            'removeObjectForKey:@"selectedContainer"',
            'removeObjectForKey:@"launchAppUrlScheme"',
        ],
        "pending-state clear function",
    )

    require_all(
        diagnostics_body,
        [
            "bundlePathExists",
            "infoPlistExists",
            "executableExists",
            "executableIsExecutable",
            "nsBundleLoaded",
            "nsextensionFound",
            "nsextensionError",
        ],
        "LiveProcess diagnostics",
    )

    require_all(
        wrapper_body,
        ["remainingLiveProcessRetries:3"],
        "LiveProcess launch wrapper",
    )

    require_all(
        launch_body,
        [
            "remainingRetries > 0",
            "dispatch_after",
            "remainingRetries - 1",
            "LCClearPendingGuestLaunchState()",
            "LCCollectLiveProcessDiagnostics()",
            "LiveProcessDiagnostics",
            "fully close and reopen it",
            "completionHandler(nil, error)",
        ],
        "LiveProcess launch path",
    )

    macho_body = extract_function(
        macho_source,
        "NSString *LCParseMachO(const char *path, bool readOnly, LCParseMachOCallback callback)",
    )
    require_all(
        macho_body,
        [
            "if (fd < 0)",
            '@"Failed to open %s',
            "if (fstat(fd, &fileStat) != 0)",
            '@"Failed to stat %s',
            "fileStat.st_size <= 0",
            "if (map == MAP_FAILED)",
            "munmap(map",
            "close(fd);",
        ],
        "Mach-O mapping diagnostics",
    )
    if "fstat(fd, &s)" in macho_body:
        fail("LCParseMachO must not ignore fstat failures")

    executable_replacement_body = extract_function(
        app_info_source,
        "- (void)patchExecAndSignIfNeedWithCompletionHandler:",
    )
    require_all(
        executable_replacement_body,
        [
            "fileExistsAtPath:execPath",
            '"Executable not found:',
            '"Failed to back up executable:',
            "rename(backupPath.fileSystemRepresentation",
            '"Failed to replace executable safely:',
        ],
        "executable replacement safety",
    )
    copy_index = executable_replacement_body.find("copyItemAtPath:execPath")
    remove_exec_index = executable_replacement_body.find("removeItemAtPath:execPath")
    replace_index = executable_replacement_body.find("rename(backupPath.fileSystemRepresentation")
    if copy_index >= 0 and remove_exec_index >= 0 and (
        replace_index < 0 or copy_index < remove_exec_index < replace_index
    ):
        fail("executable replacement must not delete the original before an atomic replacement")

    selected_read = launch_body.find('stringForKey:@"selected"')
    container_read = launch_body.find('stringForKey:@"selectedContainer"')
    selected_clear = launch_body.find('removeObjectForKey:@"selected"')
    container_clear = launch_body.find('removeObjectForKey:@"selectedContainer"')
    if selected_read < 0 or selected_clear < 0 or selected_read > selected_clear:
        fail("selected must be read before it is cleared")
    if container_read < 0 or container_clear < 0 or container_read > container_clear:
        fail("selectedContainer must be read before it is cleared")

    retry_branch = launch_body.find("if (remainingRetries > 0)")
    clear_after_retry = launch_body.find("LCClearPendingGuestLaunchState()", retry_branch)
    if retry_branch < 0 or clear_after_retry < 0:
        fail("stale launch state must be cleared only after retries are exhausted")

    # The embedded SideStore refresh path passes security-scoped bookmarks
    # through LiveProcess. Indexed assignment into a newly-created mutable
    # array is an out-of-bounds crash; require append-based handling instead.
    if re.search(r"\b(?:bookmarkedUrls|accessibleBookmarkedUrls)\s*\[", live_process_source):
        fail("security-scoped bookmarks must not use indexed mutable-array assignment")
    require_all(
        live_process_source,
        [
            "isKindOfClass:NSArray.class",
            "isKindOfClass:NSData.class",
            "[accessibleBookmarkedUrls addObject:resolvedURL]",
            "startAccessingSecurityScopedResource",
        ],
        "security-scoped bookmark handling",
    )

    require_all(
        app_info_source,
        [
            "isKindOfClass:NSArray.class",
            "isKindOfClass:NSDictionary.class",
            "isKindOfClass:NSString.class",
            "[urlSchemes addObject:rawScheme]",
        ],
        "app URL scheme metadata parsing",
    )
    if "objectAtIndex:" in app_info_source.split("- (NSMutableArray<NSString *>*)urlSchemes", 1)[1].split("- (NSString*)displayName", 1)[0]:
        fail("app URL scheme parsing must not index malformed plist arrays")
    if "as! [Any]" in app_list_source:
        fail("app URL scheme consumers must not force-cast malformed metadata")
    if "fileUrls[0]" in app_list_source:
        fail("file importer callback must tolerate an empty selection")
    if "signProgress!" in app_list_source:
        fail("install progress callback must tolerate a missing progress object")

    if "UnsafeContinuation" in sidestore_refresh_source:
        fail("embedded SideStore refresh bridge must use checked continuations")
    if "bookmarkForURL(sideStoreHomeURL)!" in sidestore_refresh_source:
        fail("embedded SideStore refresh bridge must not force-unwrap bookmark creation")
    if "self.client?.refreshAllApps" in sidestore_refresh_source:
        fail("embedded SideStore refresh bridge must validate its XPC client before calling it")
    require_all(
        sidestore_refresh_source,
        [
            "withCheckedThrowingContinuation",
            "setRefreshContinuation",
            "resumeRefresh",
            "SideStore refresh timed out.",
            "The embedded SideStore XPC client is unavailable.",
        ],
        "embedded SideStore refresh bridge",
    )

    result = {
        "source": str(SOURCE_PATH.relative_to(ROOT)),
        "live_process_source": str(LIVE_PROCESS_SOURCE_PATH.relative_to(ROOT)),
        "macho_source": str(MACHO_SOURCE_PATH.relative_to(ROOT)),
        "sidestore_refresh_source": str(SIDESTORE_REFRESH_SOURCE_PATH.relative_to(ROOT)),
        "app_info_source": str(APP_INFO_SOURCE_PATH.relative_to(ROOT)),
        "app_list_source": str(APP_LIST_SOURCE_PATH.relative_to(ROOT)),
        "checked_functions": [
            "LCClearPendingGuestLaunchState",
            "LCCollectLiveProcessDiagnostics",
            "launchMultitaskGuestApp:completionHandler:",
            "launchMultitaskGuestApp:remainingLiveProcessRetries:",
        ],
        "state_clear_keys": 3,
        "diagnostic_fields_checked": 7,
        "ordering_checks": [
            "selected-read-before-clear",
            "selectedContainer-read-before-clear",
            "clear-after-retries",
        ],
        "bookmark_checks": [
            "typed-bookmark-array",
            "typed-bookmark-data",
            "append-only-accessible-bookmarks",
            "security-scoped-access",
            "no-indexed-bookmark-assignment",
        ],
        "metadata_checks": [
            "typed-url-types",
            "typed-url-type-entry",
            "typed-url-scheme",
            "append-only-url-schemes",
            "empty-file-selection",
            "no-force-cast-url-schemes",
            "optional-sign-progress",
        ],
        "macho_checks": [
            "open-failure-diagnostic",
            "fstat-failure-diagnostic",
            "empty-file-guard",
            "mmap-failure-diagnostic",
            "descriptor-and-mapping-cleanup",
        ],
        "executable_replacement_checks": [
            "source-executable-exists",
            "backup-error-propagation",
            "atomic-replacement",
            "no-delete-before-replace",
        ],
        "bridge_checks": [
            "checked-continuations",
            "guarded-bookmark-creation",
            "guarded-xpc-client",
            "refresh-timeout",
        ],
    }
    print("[liveprocess contract] PASS " + json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
