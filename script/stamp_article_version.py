#!/usr/bin/env python3
"""Bind one built HTML page to the exact UTF-8 Markdown source used to build it.

The tool intentionally accepts an explicit source/output pair. It never guesses
routes, changes front matter, or traverses a site directory.
"""

from __future__ import annotations

import argparse
import hashlib
import html as html_entities
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


MARKER_NAME = "repopress:source-digest"
MARKER_NAME_NORMALIZED = MARKER_NAME.lower()
MARKER_TEMPLATE = '<meta name="repopress:source-digest" content="{digest}">'
HEX_DIGEST = re.compile(r"^[0-9a-fA-F]{64}$")
TAG_NAME = re.compile(r"<(/?)([A-Za-z][A-Za-z0-9:_-]*)\b", re.DOTALL)
ATTRIBUTE = re.compile(
    r"(?:^|\s)([A-Za-z_:][A-Za-z0-9:._-]*)"
    r"(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+)))?",
    re.DOTALL,
)


class InputError(ValueError):
    """The requested explicit source/output pair is ambiguous or unsafe."""


@dataclass(frozen=True)
class Tag:
    start: int
    end: int
    name: str
    closing: bool
    raw: str


def read_utf8_regular_file(path: Path, label: str) -> bytes:
    try:
        metadata = path.stat()
    except OSError as error:
        raise InputError(f"{label} cannot be read: {error}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise InputError(f"{label} must be a regular file")
    try:
        data = path.read_bytes()
        data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise InputError(f"{label} must be UTF-8") from error
    except OSError as error:
        raise InputError(f"{label} cannot be read: {error}") from error
    return data


def resolve_distinct_paths(source: Path, html: Path) -> tuple[Path, Path]:
    try:
        source_path = source.resolve(strict=True)
        html_path = html.resolve(strict=True)
    except OSError as error:
        raise InputError(f"source and html must resolve to existing files: {error}") from error
    if source_path == html_path or os.path.samefile(source_path, html_path):
        raise InputError("source and html must be different files")
    return source_path, html_path


def tag_end(html: str, start: int) -> int | None:
    quote: str | None = None
    position = start + 1
    while position < len(html):
        character = html[position]
        if quote:
            if character == quote:
                quote = None
        elif character in "\"'":
            quote = character
        elif character == ">":
            return position + 1
        position += 1
    return None


def iter_tags(html: str) -> Iterator[Tag]:
    """Yields real tags while skipping comments and non-document head-like text."""
    position = 0
    raw_text_name: str | None = None
    template_depth = 0
    while position < len(html):
        if raw_text_name:
            closing = re.search(
                rf"</{re.escape(raw_text_name)}(?=[\t\n\f\r />])",
                html[position:], re.IGNORECASE,
            )
            if closing is None:
                return
            position += closing.start()
            raw_text_name = None
        start = html.find("<", position)
        if start < 0:
            return
        if html.startswith("<!--", start):
            end = html.find("-->", start + 4)
            if end < 0:
                raise InputError("html has an unclosed comment")
            position = end + 3
            continue
        if html.startswith("<!", start) or html.startswith("<?", start):
            end = tag_end(html, start)
            if end is None:
                raise InputError("html has an unclosed declaration")
            position = end
            continue
        end = tag_end(html, start)
        if end is None:
            raise InputError("html has an unclosed tag")
        raw = html[start:end]
        matched = TAG_NAME.match(raw)
        if matched is None or raw[matched.end():matched.end() + 1] not in "\t\n\f\r />":
            position = end
            continue
        tag = Tag(
            start=start,
            end=end,
            name=matched.group(2).lower(),
            closing=bool(matched.group(1)),
            raw=raw,
        )
        position = end
        if tag.name == "template":
            template_depth = max(0, template_depth - 1) if tag.closing else template_depth + 1
            continue
        if not tag.closing and tag.name in {
            "script", "style", "title", "textarea", "noscript"
        }:
            raw_text_name = tag.name
        if template_depth == 0:
            yield tag


def attributes(tag: Tag) -> dict[str, list[str | None]]:
    match = TAG_NAME.match(tag.raw)
    assert match is not None
    body = tag.raw[match.end():-1].rstrip().rstrip("/").rstrip()
    parsed: dict[str, list[str | None]] = {}
    for attribute in ATTRIBUTE.finditer(body):
        value = next((group for group in attribute.groups()[1:] if group is not None), None)
        if value is not None:
            value = html_entities.unescape(value)
        parsed.setdefault(attribute.group(1).lower(), []).append(value)
    return parsed


def locate_head_and_marker(html: str) -> tuple[Tag, Tag, list[Tag]]:
    heads = [tag for tag in iter_tags(html) if tag.name == "head"]
    opening_heads = [tag for tag in heads if not tag.closing]
    closing_heads = [tag for tag in heads if tag.closing]
    if len(opening_heads) != 1 or len(closing_heads) != 1:
        raise InputError("html must contain exactly one opening and one closing <head>")
    opening, closing = opening_heads[0], closing_heads[0]
    if opening.end > closing.start:
        raise InputError("html has an invalid <head> range")

    markers: list[Tag] = []
    for tag in iter_tags(html):
        if tag.closing or tag.name != "meta" or not opening.end <= tag.start < closing.start:
            continue
        names = attributes(tag).get("name", [])
        normalized_names = [name.lower() if name is not None else None for name in names]
        if MARKER_NAME_NORMALIZED not in normalized_names:
            continue
        if normalized_names != [MARKER_NAME_NORMALIZED]:
            raise InputError("source-digest marker must have exactly one name attribute")
        markers.append(tag)
    if len(markers) > 1:
        raise InputError("html has duplicate repopress source-digest markers in <head>")
    return opening, closing, markers


def marker_digest(marker: Tag) -> str | None:
    values = attributes(marker).get("content")
    if values is None or len(values) != 1 or values[0] is None:
        raise InputError("source-digest marker must have exactly one content attribute")
    if not HEX_DIGEST.fullmatch(values[0]):
        raise InputError("source-digest marker must contain a 64-character SHA-256 digest")
    return values[0].lower()


def evaluate(source: Path, html: Path) -> tuple[str, str, Tag, Tag, list[Tag]]:
    source_path, html_path = resolve_distinct_paths(source, html)
    source_bytes = read_utf8_regular_file(source_path, "source")
    html_bytes = read_utf8_regular_file(html_path, "html")
    digest = hashlib.sha256(source_bytes).hexdigest()
    html_text = html_bytes.decode("utf-8")
    opening, closing, markers = locate_head_and_marker(html_text)
    return digest, html_text, opening, closing, markers


def check(source: Path, html: Path) -> int:
    digest, _, _, _, markers = evaluate(source, html)
    if not markers:
        print("unknown: source-digest marker is missing")
        return 1
    marker_value = marker_digest(markers[0])
    if marker_value != digest:
        print("failed: source-digest marker does not match source")
        return 1
    print("verified")
    return 0


def atomic_write(path: Path, data: bytes) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as temporary:
            temporary.write(data)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def stamp(source: Path, html: Path) -> int:
    digest, html_text, opening, _, markers = evaluate(source, html)
    marker = MARKER_TEMPLATE.format(digest=digest)
    if markers:
        existing_digest = marker_digest(markers[0])
        if existing_digest == digest:
            print("already-stamped")
            return 0
        updated = html_text[:markers[0].start] + marker + html_text[markers[0].end:]
    else:
        updated = html_text[:opening.end] + "\n" + marker + html_text[opening.end:]
    atomic_write(html.resolve(strict=True), updated.encode("utf-8"))
    print("stamped")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="explicit UTF-8 Markdown source")
    parser.add_argument("--html", required=True, type=Path, help="explicit UTF-8 built HTML output")
    parser.add_argument("--check", action="store_true", help="verify only; never modify HTML")
    arguments = parser.parse_args(argv)
    try:
        return check(arguments.source, arguments.html) if arguments.check else stamp(arguments.source, arguments.html)
    except InputError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except OSError as error:
        print(f"error: atomic update failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
