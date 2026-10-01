#!/usr/bin/env python3
"""Configure and validate the commit-pinned LiveContainer+SideStore integration."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
from pathlib import Path

DEFAULT_REPOSITORY = "joeshu/livecontainer"
INTENT_TYPES = {
    "9SideStore20RefreshAllAppsIntentV": "16SideStoreSupport20RefreshAllAppsIntentV",
    "9SideStore26RefreshAllAppsWidgetIntentV": "16SideStoreSupport26RefreshAllAppsWidgetIntentV",
}


def source_url(repository):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    return f"https://github.com/{repository}/releases/download/1.0/apps_ss_lc.json"


def configure(app, repository, channel, sidestore_commit, sidestore_sha256, host_commit):
    url = source_url(repository)
    if channel not in {"stable", "nightly"}:
        raise ValueError("Unknown release channel")
    if not re.fullmatch(r"[0-9a-f]{40}", sidestore_commit):
        raise ValueError("SideStore source commit is missing or invalid")
    if not re.fullmatch(r"[0-9a-f]{64}", sidestore_sha256):
        raise ValueError("SideStore IPA checksum is missing or invalid")
    if not re.fullmatch(r"[0-9a-f]{40}", host_commit):
        raise ValueError("LiveContainer source commit is missing or invalid")
    actions = app / "Metadata.appintents/extract.actionsdata"
    text = actions.read_text()
    for original, replacement in INTENT_TYPES.items():
        if original not in text:
            raise ValueError(f"Embedded SideStore intent contract changed: {original}")
        text = text.replace(original, replacement)
    actions.write_text(text)
    info_path = app / "Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    info.update(LCSideStoreSourceURL=url, LCSideStoreReleaseChannel=channel,
                LCSideStoreSourceCommit=sidestore_commit)
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle)
    manifest = {
        "schema_version": 1,
        "repository": repository,
        "channel": channel,
        "update_source": url,
        "livecontainer_commit": host_commit,
        "sidestore_commit": sidestore_commit,
        "sidestore_ipa_sha256": sidestore_sha256,
        "sidestore_patch_sha256": hashlib.sha256(
            (Path(__file__).resolve().parents[1] / "patches/sidestore-combined-reinstall.patch").read_bytes()
        ).hexdigest(),
    }
    (app / "LCBuildManifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    host_commit = os.environ.get("GITHUB_SHA") or subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    configure(args.app, os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPOSITORY),
              os.environ.get("LC_RELEASE_CHANNEL", "stable"), os.environ["SIDESTORE_SOURCE_SHA"],
              os.environ["SIDESTORE_IPA_SHA256"], host_commit)


if __name__ == "__main__":
    main()
