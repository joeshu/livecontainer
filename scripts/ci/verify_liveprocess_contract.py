#!/usr/bin/env python3
"""Validate the LiveProcess reinstall/launch state contract.

The previous guard only searched for independent strings. This checker extracts
the relevant Objective-C function bodies and verifies the ordering and
relationship of the state transitions that protect against stale launches.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = ROOT / "LiveContainerSwiftUI/Utilities/LCUtils.m"


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

    source = SOURCE_PATH.read_text(encoding="utf-8")
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

    result = {
        "source": str(SOURCE_PATH.relative_to(ROOT)),
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
    }
    print("[liveprocess contract] PASS " + json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
