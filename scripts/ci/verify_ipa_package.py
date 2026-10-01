#!/usr/bin/env python3
"""Validate the structure of a LiveContainer IPA before release.

This is intentionally independent of Xcode and signing tools. It validates the
final archive that users will install, including extension retention and the
embedded SideStore resource boundary.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
import tempfile
import zipfile
import re
import struct
from pathlib import Path, PurePosixPath


def validate_combined_contract(app: Path, info: dict) -> None:
    manifest_path = app / "LCBuildManifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError) as exc:
        fail(f"unable to read combined build manifest: {exc}")
    if manifest.get("schema_version") != 1:
        fail("unknown combined build manifest version")
    repository = manifest.get("repository", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        fail("invalid combined source repository")
    expected_source = f"https://github.com/{repository}/releases/download/1.0/apps_ss_lc.json"
    if info.get("LCSideStoreSourceURL") != expected_source or manifest.get("update_source") != expected_source:
        fail("combined update source does not match build repository")
    if manifest.get("channel") not in {"stable", "nightly"} or info.get("LCSideStoreReleaseChannel") != manifest["channel"]:
        fail("combined release channel does not match build manifest")
    for key in ("livecontainer_commit", "sidestore_commit"):
        if not re.fullmatch(r"[0-9a-f]{40}", manifest.get(key, "")):
            fail(f"invalid build manifest commit: {key}")
    if info.get("LCSideStoreSourceCommit") != manifest["sidestore_commit"]:
        fail("embedded SideStore commit does not match build manifest")
    for key in ("sidestore_ipa_sha256", "sidestore_patch_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", manifest.get(key, "")):
            fail(f"invalid build manifest checksum: {key}")
    actions = app / "Metadata.appintents/extract.actionsdata"
    try:
        text = actions.read_text()
    except (OSError, UnicodeError) as exc:
        fail(f"unable to read combined AppIntents metadata: {exc}")
    for suffix in ("20RefreshAllAppsIntentV", "26RefreshAllAppsWidgetIntentV"):
        if f"16SideStoreSupport{suffix}" not in text or f"9SideStore{suffix}" in text:
            fail(f"invalid combined AppIntent mapping: {suffix}")
    with (app / "Frameworks/SideStoreApp.framework/SideStore").open("rb") as handle:
        header = handle.read(32)
    if len(header) < 32 or struct.unpack_from("<I", header)[0] != 0xFEEDFACF or struct.unpack_from("<I", header, 12)[0] != 6:
        fail("embedded SideStore must be a 64-bit Mach-O dylib")


def fail(message: str) -> "NoReturn":
    print(f"[ipa verifier] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def require_file(root: Path, relative: str, description: str) -> Path:
    path = root / relative
    if not path.is_file():
        fail(f"missing {description}: {relative}")
    return path


def require_directory(root: Path, relative: str, description: str) -> Path:
    path = root / relative
    if not path.is_dir():
        fail(f"missing {description}: {relative}")
    return path


def load_plist(path: Path, description: str) -> dict:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except Exception as exc:  # pragma: no cover - diagnostic path
        fail(f"unable to read {description} at {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{description} is not a dictionary: {path}")
    return value


def validate_zip_members(names: list[str]) -> None:
    for name in names:
        member = PurePosixPath(name)
        if member.is_absolute() or ".." in member.parts:
            fail(f"unsafe archive member path: {name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument(
        "--mode",
        required=True,
        choices=("standalone", "combined"),
        help="standalone LiveContainer or LiveContainer+SideStore",
    )
    args = parser.parse_args()

    if not args.ipa.is_file():
        fail(f"IPA does not exist: {args.ipa}")

    with zipfile.ZipFile(args.ipa) as archive:
        names = archive.namelist()
        validate_zip_members(names)

        payload_apps = sorted(
            name.rstrip("/")
            for name in names
            if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/")
        )
        if payload_apps != ["Payload/LiveContainer.app"]:
            fail(f"expected exactly one LiveContainer.app, found: {payload_apps}")

        with tempfile.TemporaryDirectory(prefix="livecontainer-ipa-") as temporary:
            root = Path(temporary)
            archive.extractall(root)

            app = require_directory(root, "Payload/LiveContainer.app", "host application")
            info = load_plist(
                require_file(root, "Payload/LiveContainer.app/Info.plist", "host Info.plist"),
                "host Info.plist",
            )

            bundle_id = info.get("CFBundleIdentifier")
            executable_name = info.get("CFBundleExecutable")
            if not isinstance(bundle_id, str) or not bundle_id:
                fail("host CFBundleIdentifier is missing")
            if not isinstance(executable_name, str) or not executable_name:
                fail("host CFBundleExecutable is missing")
            require_file(
                app,
                executable_name,
                "host executable",
            )

            live_process_info_path = (
                "Payload/LiveContainer.app/PlugIns/LiveProcess.appex/Info.plist"
            )
            live_process_info = load_plist(
                require_file(root, live_process_info_path, "LiveProcess Info.plist"),
                "LiveProcess Info.plist",
            )
            live_process_executable = live_process_info.get("CFBundleExecutable")
            if not isinstance(live_process_executable, str) or not live_process_executable:
                fail("LiveProcess CFBundleExecutable is missing")
            require_file(
                root,
                f"Payload/LiveContainer.app/PlugIns/LiveProcess.appex/{live_process_executable}",
                "LiveProcess executable",
            )

            if args.mode == "combined":
                widget_info_path = (
                    "Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist"
                )
                widget_info = load_plist(
                    require_file(root, widget_info_path, "LiveWidgetExtension Info.plist"),
                    "LiveWidgetExtension Info.plist",
                )
                if widget_info.get("CFBundleIdentifier") != "com.kdt.livecontainer.LiveWidget":
                    fail(
                        "LiveWidgetExtension bundle identifier is not "
                        "com.kdt.livecontainer.LiveWidget"
                    )
                widget_executable = widget_info.get("CFBundleExecutable")
                if not isinstance(widget_executable, str) or not widget_executable:
                    fail("LiveWidgetExtension CFBundleExecutable is missing")
                require_file(
                    root,
                    f"Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/{widget_executable}",
                    "LiveWidgetExtension executable",
                )

                framework = require_directory(
                    root,
                    "Payload/LiveContainer.app/Frameworks/SideStoreApp.framework",
                    "embedded SideStore framework",
                )
                require_file(
                    framework,
                    "SideStore",
                    "embedded SideStore executable",
                )
                validate_combined_contract(app, info)
                require_file(
                    framework,
                    "LCAppInfo.plist",
                    "embedded SideStore metadata",
                )
                if (framework / "PlugIns/AltWidgetExtension.appex").exists():
                    fail("unmoved AltWidgetExtension.appex remains inside SideStore framework")
                if (root / "Payload/SideStore.app").exists():
                    fail("raw SideStore.app remains beside the host application")

                for language in ["zh-Hans", "zh-Hant"]:
                    localization_root = framework / f"{language}.lproj"
                    if not localization_root.is_dir():
                        fail(f"embedded SideStore {language}.lproj is missing")
                    resources = {item.name for item in localization_root.iterdir() if item.is_file()}
                    required_resources = {"Localizable.strings", "InfoPlist.strings",
                                          "InterfaceFallback.strings", "CombinedLocalizable.strings"}
                    missing = sorted(required_resources - resources)
                    if missing:
                        fail(f"embedded SideStore {language} resources are missing: " + ", ".join(missing))
                    if len(resources) < 8:
                        fail(f"embedded SideStore {language} resource count is below 8: {len(resources)}")
                require_file(framework, "en.lproj/CombinedLocalizable.strings", "SideStore English recovery fallback")
                for language in ["en", "zh-Hans", "zh-Hant"]:
                    require_file(app, f"Frameworks/SideStoreSupport.framework/{language}.lproj/RefreshLocalizable.strings",
                                 f"refresh coordinator {language} translations")

            result = {
                "ipa": str(args.ipa),
                "mode": args.mode,
                "host_bundle_identifier": bundle_id,
                "host_version": info.get("CFBundleShortVersionString", ""),
                "liveprocess_bundle_identifier": live_process_info.get(
                    "CFBundleIdentifier", ""
                ),
            }
            if args.mode == "combined":
                result["embedded_sidestore_zh_hans_resources"] = len(resources)
            print("[ipa verifier] PASS " + json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
