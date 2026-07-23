#!/usr/bin/env python3
"""Validate the local App Store Connect listing draft and submission blockers."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_METADATA = ROOT / "docs" / "app-store" / "metadata.json"
REQUIRED_LOCALES = {"zh-Hans", "en-US"}
EXPECTED_NAME = "RepoPress"
EXPECTED_SUBTITLES = {
    "zh-Hans": "Markdown 写作与仓库同步",
    "en-US": "Markdown Repository Workspace",
}
PENDING_PREFIX = "PENDING_"
REQUIRED_FULL_FEATURE_DISCLOSURES = {
    "zh-Hans": ("明确同意", "127.0.0.1", "用户自行购买和管理"),
    "en-US": ("Explicit consent", "127.0.0.1", "purchase and manage"),
}


class ValidationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def require_string(container: dict[str, object], key: str, context: str) -> str:
    value = container.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{context}.{key} must be a non-empty string")
    return value.strip()


def is_pending(value: str) -> bool:
    return value.startswith(PENDING_PREFIX)


def validate_public_url(value: str, context: str, strict: bool) -> None:
    if is_pending(value):
        if strict:
            fail(f"{context} is still pending")
        return
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        fail(f"{context} must be a credential-free public HTTPS URL")
    if parsed.hostname in {"localhost", "127.0.0.1", "::1"}:
        fail(f"{context} must not use a local host")


def validate_listing_text(localization: dict[str, object], locale: str, strict: bool) -> None:
    name = require_string(localization, "name", locale)
    subtitle = require_string(localization, "subtitle", locale)
    promotional_text = require_string(localization, "promotionalText", locale)
    description = require_string(localization, "description", locale)
    keywords = require_string(localization, "keywords", locale)
    support_url = require_string(localization, "supportURL", locale)
    marketing_url = require_string(localization, "marketingURL", locale)

    if not 2 <= len(name) <= 30:
        fail(f"{locale}.name must contain 2 to 30 characters, got {len(name)}")
    if name != EXPECTED_NAME:
        fail(f"{locale}.name must use the shared RepoPress brand")
    if len(subtitle) > 30:
        fail(f"{locale}.subtitle exceeds 30 characters: {len(subtitle)}")
    if subtitle != EXPECTED_SUBTITLES[locale]:
        fail(f"{locale}.subtitle does not match the approved positioning")
    if len(promotional_text) > 170:
        fail(f"{locale}.promotionalText exceeds 170 characters: {len(promotional_text)}")
    if len(description) > 4000:
        fail(f"{locale}.description exceeds 4000 characters: {len(description)}")
    keyword_bytes = len(keywords.encode("utf-8"))
    if keyword_bytes > 100:
        fail(f"{locale}.keywords exceeds 100 UTF-8 bytes: {keyword_bytes}")
    keyword_items = [item.strip() for item in keywords.split(",")]
    if not keyword_items or any(len(item) <= 2 for item in keyword_items):
        fail(f"{locale}.keywords must be comma-separated and each keyword must exceed two characters")

    visible_listing = "\n".join((subtitle, promotional_text, description, keywords))
    for disclosure in REQUIRED_FULL_FEATURE_DISCLOSURES[locale]:
        if disclosure.casefold() not in visible_listing.casefold():
            fail(f"{locale} listing is missing full-feature disclosure: {disclosure}")

    validate_public_url(support_url, f"{locale}.supportURL", strict)
    validate_public_url(marketing_url, f"{locale}.marketingURL", strict=False)


def resolve_document(path_text: str, context: str, byte_limit: int | None = None) -> Path:
    relative = Path(path_text)
    if relative.is_absolute() or ".." in relative.parts:
        fail(f"{context} must be a repository-relative path")
    path = ROOT / relative
    if not path.is_file():
        fail(f"{context} is missing: {relative}")
    if byte_limit is not None:
        byte_count = len(path.read_text(encoding="utf-8").encode("utf-8"))
        if byte_count > byte_limit:
            fail(f"{context} exceeds {byte_limit} UTF-8 bytes: {byte_count}")
    return path


def validate(metadata_path: Path, strict: bool) -> list[str]:
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except OSError as error:
        fail(f"cannot read metadata: {error}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON: {error}")
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        fail("metadata must be a schemaVersion 1 object")
    if payload.get("bundleIdentifier") != "com.jinfang.PersonalSitePublisherMac":
        fail("bundleIdentifier does not match the packaged app")
    if payload.get("primaryCategory") != "public.app-category.developer-tools":
        fail("primaryCategory must match the packaged Developer Tools category")

    privacy_url = require_string(payload, "privacyPolicyURL", "metadata")
    validate_public_url(privacy_url, "metadata.privacyPolicyURL", strict)

    localizations = payload.get("localizations")
    if not isinstance(localizations, dict):
        fail("metadata.localizations must be an object")
    missing_locales = sorted(REQUIRED_LOCALES - set(localizations))
    if missing_locales:
        fail(f"missing required localization(s): {', '.join(missing_locales)}")
    for locale in sorted(REQUIRED_LOCALES):
        localization = localizations.get(locale)
        if not isinstance(localization, dict):
            fail(f"{locale} localization must be an object")
        validate_listing_text(localization, locale, strict)

    review = payload.get("appReview")
    if not isinstance(review, dict):
        fail("metadata.appReview must be an object")
    if review.get("signInRequired") is not False:
        fail("appReview.signInRequired must stay false for the local-first review path")
    contact = review.get("contact")
    if not isinstance(contact, dict):
        fail("appReview.contact must be an object")
    email = require_string(contact, "email", "appReview.contact")
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
        fail("appReview.contact.email is invalid")
    configured_in_connect = contact.get("configuredInAppStoreConnect", False)
    if not isinstance(configured_in_connect, bool):
        fail("appReview.contact.configuredInAppStoreConnect must be a boolean")
    name_value = contact.get("name")
    phone_value = contact.get("phone")
    if (name_value is None) != (phone_value is None):
        fail("appReview.contact.name and phone must either both be present or both be omitted")
    embedded_contact_complete = False
    if name_value is not None and phone_value is not None:
        name = require_string(contact, "name", "appReview.contact")
        phone = require_string(contact, "phone", "appReview.contact")
        embedded_contact_complete = not is_pending(name) and not is_pending(phone)
    contact_complete = configured_in_connect or embedded_contact_complete
    if strict and not contact_complete:
        fail("App Review contact must be completed in App Store Connect")

    notes_file = require_string(review, "notesFile", "appReview")
    notes_path = resolve_document(notes_file, "appReview.notesFile", byte_limit=4000)
    notes_text = notes_path.read_text(encoding="utf-8")
    for required_boundary in (
        "explicit consent is required",
        "127.0.0.1:17843",
        "does not bundle a Native Messaging executable",
    ):
        if required_boundary not in notes_text:
            fail(f"appReview.notesFile is missing distribution boundary: {required_boundary}")
    privacy_file = require_string(payload, "privacyResponsesFile", "metadata")
    privacy_path = resolve_document(privacy_file, "metadata.privacyResponsesFile")
    privacy_text = privacy_path.read_text(encoding="utf-8")
    for required_privacy_boundary in (
        "| User-configured AI |",
        "| Browser capture |",
        "developer does not proxy or receive API keys",
    ):
        if required_privacy_boundary not in privacy_text:
            fail(
                "metadata.privacyResponsesFile is missing full-feature boundary: "
                + required_privacy_boundary
            )

    blockers: list[str] = []
    if not strict:
        if is_pending(privacy_url):
            blockers.append("public privacy policy URL")
        for locale in sorted(REQUIRED_LOCALES):
            localization = localizations[locale]
            if isinstance(localization, dict) and is_pending(str(localization.get("supportURL", ""))):
                blockers.append(f"{locale} support URL")
        if not contact_complete:
            blockers.append("App Review contact name and phone")
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--strict", action="store_true", help="require public URLs and complete review contact")
    args = parser.parse_args()
    metadata_path = args.metadata.expanduser().resolve()
    try:
        blockers = validate(metadata_path, args.strict)
    except ValidationError as error:
        print(f"app store listing metadata gate: {error}", file=sys.stderr)
        return 1
    if blockers:
        print("app store listing metadata gate: local copy and limits verified")
        print("app store listing metadata gate: external submission blockers: " + "; ".join(blockers))
    else:
        print("app store listing metadata gate: submission metadata verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
