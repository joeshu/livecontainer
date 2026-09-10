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
    tweak_loader = read("TweakLoader/TweakLoader.m")

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
    require(shared, "appBundle == nil", "bundle lookup failure guard")
    require(shared, "LCAppInfo.plist", "bundle metadata validation")
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
