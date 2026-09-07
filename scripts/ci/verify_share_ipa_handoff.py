#!/usr/bin/env python3
"""Regression guard for Share Extension -> LiveContainer IPA handoff."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ShareExtension/ShareExtensionViewModel.swift"


def fail(message: str) -> None:
    print(f"[share IPA handoff] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if not SOURCE.is_file():
        fail(f"missing source: {SOURCE.relative_to(ROOT)}")

    text = SOURCE.read_text(encoding="utf-8")
    required = [
        "stageSharedInstallFile(fileURL)",
        'appendingPathComponent("ImportInbox", isDirectory: true)',
        "fileURL.startAccessingSecurityScopedResource()",
        "cleanupSharedInstallInbox(inboxURL)",
        'URLQueryItem(name: "url", value: stagedURL.absoluteString)',
        'URLQueryItem(name: "mode", value: "container")',
        "fileSize > 0",
    ]
    for marker in required:
        if marker not in text:
            fail(f"missing required marker: {marker}")

    install_start = text.find("func installSharedFileInLiveContainer")
    install_end = text.find("private func stageSharedInstallFile", install_start)
    if install_start < 0 or install_end < 0:
        fail("unable to isolate installSharedFileInLiveContainer")
    install_body = text[install_start:install_end]

    if 'URLQueryItem(name: "url", value: fileURL.absoluteString)' in install_body:
        fail("extension-scoped file URL is still handed directly to the main app")

    if "completeRequest" not in install_body or install_body.find("stageSharedInstallFile") > install_body.find("completeRequest"):
        fail("IPA must be staged before the extension request is completed")

    print("[share IPA handoff] PASS: IPA is staged into App Group before host handoff")


if __name__ == "__main__":
    main()
