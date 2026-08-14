#!/usr/bin/env python3
"""Verify that website privacy/support claims match distribution entitlements."""

from __future__ import annotations

import html
import os
import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(
    os.environ.get(
        "PUBLIC_COPY_ENTITLEMENTS_ROOT",
        Path(__file__).resolve().parent.parent,
    )
).resolve()

DIRECT_ENTITLEMENTS = ROOT / "Packaging/DirectDistribution.entitlements"
SAFARI_ENTITLEMENTS = ROOT / "Packaging/SafariWebExtension.entitlements"

COPY_FILES = (
    (ROOT / "docs/privacy-support-copy.md", "en"),
    (ROOT / "docs/app-store/public-pages/privacy-zh-Hans.html", "zh"),
    (ROOT / "docs/app-store/public-pages/privacy-en.html", "en"),
    (ROOT / "docs/app-store/public-pages/support-zh-Hans.html", "zh"),
    (ROOT / "docs/app-store/public-pages/support-en.html", "en"),
)

DIRECT_ENABLED = {
    "en": "The main app in the Developer ID website edition enables App Sandbox.",
    "zh": "官网 Developer ID 版本的主应用启用 App Sandbox。",
}
DIRECT_DISABLED = {
    "en": "The main app in the Developer ID website edition does not enable App Sandbox.",
    "zh": "官网 Developer ID 版本的主应用未启用 App Sandbox。",
}
HARDENED_RUNTIME_BOUNDARY = {
    "en": "Hardened Runtime and Apple notarization protect code integrity and distribution trust but do not provide App Sandbox isolation.",
    "zh": "Hardened Runtime 和 Apple 公证用于代码完整性、运行时保护与分发信任，但不提供 App Sandbox 隔离。",
}
SAFARI_ENABLED = {
    "en": "The embedded Safari Web Extension is a separate extension process and enables App Sandbox.",
    "zh": "内置 Safari Web Extension 是独立扩展进程，启用 App Sandbox。",
}
SAFARI_DISABLED = {
    "en": "The embedded Safari Web Extension is a separate extension process and does not enable App Sandbox.",
    "zh": "内置 Safari Web Extension 是独立扩展进程，未启用 App Sandbox。",
}


def fail(message: str) -> None:
    raise SystemExit(f"public copy entitlement gate: {message}")


def load_entitlements(path: Path) -> dict[str, object]:
    if not path.is_file():
        fail(f"missing entitlement file: {path.relative_to(ROOT)}")
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"invalid entitlement plist {path.relative_to(ROOT)}: {error}")
    if not isinstance(value, dict):
        fail(f"entitlement plist is not a dictionary: {path.relative_to(ROOT)}")
    return value


def visible_text(path: Path) -> str:
    if not path.is_file():
        fail(f"missing public copy file: {path.relative_to(ROOT)}")
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".html":
        text = re.sub(r"<script\b[^>]*>.*?</script>", " ", text, flags=re.I | re.S)
        text = re.sub(r"<style\b[^>]*>.*?</style>", " ", text, flags=re.I | re.S)
        text = re.sub(r"<[^>]+>", " ", text)
        text = html.unescape(text)
    return " ".join(text.split())


def require_phrase(path: Path, text: str, phrase: str) -> None:
    if phrase.casefold() not in text.casefold():
        fail(f"{path.relative_to(ROOT)} does not disclose: {phrase}")


def forbid_phrase(path: Path, text: str, phrase: str) -> None:
    if phrase.casefold() in text.casefold():
        fail(f"{path.relative_to(ROOT)} contradicts its entitlement: {phrase}")


def has_generic_direct_sandbox_claim(text: str, language: str) -> bool:
    if language == "zh":
        return re.search(
            r"(?:官网[^。]{0,30})?(?:主应用|Mac 应用|应用)(?:使用|启用)(?:了)?(?: macOS)?(?: App)? 沙盒",
            text,
            flags=re.I,
        ) is not None
    return re.search(
        r"\b(?:the )?(?:main |mac )?app (?:uses|enables) (?:the )?(?:macos )?(?:app )?sandbox\b",
        text,
        flags=re.I,
    ) is not None


def main() -> None:
    direct = load_entitlements(DIRECT_ENTITLEMENTS)
    safari = load_entitlements(SAFARI_ENTITLEMENTS)
    direct_is_sandboxed = direct.get("com.apple.security.app-sandbox") is True
    safari_is_sandboxed = safari.get("com.apple.security.app-sandbox") is True

    for path, language in COPY_FILES:
        text = visible_text(path)

        if direct_is_sandboxed:
            require_phrase(path, text, DIRECT_ENABLED[language])
            forbid_phrase(path, text, DIRECT_DISABLED[language])
        else:
            require_phrase(path, text, DIRECT_DISABLED[language])
            forbid_phrase(path, text, DIRECT_ENABLED[language])
            if has_generic_direct_sandbox_claim(text, language):
                fail(
                    f"{path.relative_to(ROOT)} generically claims that the Developer ID main app uses App Sandbox"
                )

        require_phrase(path, text, HARDENED_RUNTIME_BOUNDARY[language])

        if safari_is_sandboxed:
            require_phrase(path, text, SAFARI_ENABLED[language])
            forbid_phrase(path, text, SAFARI_DISABLED[language])
        else:
            require_phrase(path, text, SAFARI_DISABLED[language])
            forbid_phrase(path, text, SAFARI_ENABLED[language])

    direct_state = "enabled" if direct_is_sandboxed else "disabled"
    safari_state = "enabled" if safari_is_sandboxed else "disabled"
    print(
        "public copy entitlement gate: "
        f"Developer ID main app App Sandbox={direct_state}; "
        f"Safari Web Extension App Sandbox={safari_state}; "
        f"{len(COPY_FILES)} copy files match"
    )


if __name__ == "__main__":
    try:
        main()
    except UnicodeError as error:
        fail(f"could not decode a public copy file as UTF-8: {error}")
