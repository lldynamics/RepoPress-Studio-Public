#!/usr/bin/env python3
"""Find SwiftUI TextField/TextEditor calls missing a direct accessibility label."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys


@dataclass(frozen=True)
class Token:
    value: str
    line: int


DELIMITER_PAIRS = {"(": ")", "[": "]", "{": "}"}


class LexingError(ValueError):
    """Swift source could not be scanned without guessing at its structure."""


def tokenize(source: str) -> list[Token]:
    """Return only syntax tokens, deliberately omitting comments and strings."""
    tokens: list[Token] = []
    index = 0
    line = 1
    length = len(source)

    def advance(count: int = 1) -> None:
        nonlocal index, line
        segment = source[index : index + count]
        line += segment.count("\n")
        index += count

    def skip_block_comment() -> None:
        start_line = line
        depth = 1
        advance(2)
        while index < length and depth:
            if source.startswith("/*", index):
                depth += 1
                advance(2)
            elif source.startswith("*/", index):
                depth -= 1
                advance(2)
            else:
                advance()
        if depth:
            raise LexingError(f"unterminated block comment beginning at line {start_line}")

    def raw_string_start() -> tuple[int, int] | None:
        raw_hashes = 0
        while index + raw_hashes < length and source[index + raw_hashes] == "#":
            raw_hashes += 1
        quote_index = index + raw_hashes
        if quote_index < length and source[quote_index] == '"':
            return raw_hashes, quote_index
        return None

    def skip_interpolation(start_line: int) -> None:
        """Skip a string interpolation expression without treating it as a view tree."""
        depth = 1
        while index < length:
            if source.startswith("//", index):
                newline = source.find("\n", index)
                advance(length - index if newline == -1 else newline - index)
                continue
            if source.startswith("/*", index):
                skip_block_comment()
                continue
            string_start = raw_string_start()
            if string_start is not None:
                skip_string(*string_start)
                continue
            if source[index] == "(":
                depth += 1
            elif source[index] == ")":
                depth -= 1
                if depth == 0:
                    advance()
                    return
            advance()
        raise LexingError(f"unterminated string interpolation beginning at line {start_line}")

    def skip_string(raw_hashes: int, quote_index: int) -> None:
        start_line = line
        multiline = source.startswith('"""', quote_index)
        quote_length = 3 if multiline else 1
        terminator = '"' * quote_length + '#' * raw_hashes
        interpolation = "\\" + "#" * raw_hashes + "("
        advance(raw_hashes + quote_length)
        while index < length:
            if source.startswith(terminator, index):
                advance(len(terminator))
                return
            if source.startswith(interpolation, index):
                advance(len(interpolation))
                skip_interpolation(start_line)
                continue
            if source[index] == "\\" and raw_hashes == 0:
                advance(2)
            else:
                advance()
        raise LexingError(f"unterminated string beginning at line {start_line}")

    while index < length:
        character = source[index]
        if character.isspace():
            advance()
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index)
            advance(length - index if newline == -1 else newline - index)
            continue
        if source.startswith("/*", index):
            skip_block_comment()
            continue

        string_start = raw_string_start()
        if string_start is not None:
            skip_string(*string_start)
            continue

        if character.isalpha() or character == "_":
            start = index
            start_line = line
            advance()
            while index < length and (source[index].isalnum() or source[index] == "_"):
                advance()
            tokens.append(Token(source[start:index], start_line))
            continue

        tokens.append(Token(character, line))
        advance()
    return tokens


def matching_delimiter(tokens: list[Token], opening_index: int) -> int:
    opening = tokens[opening_index].value
    if opening not in DELIMITER_PAIRS:
        raise LexingError(f"expected an opening delimiter at line {tokens[opening_index].line}")
    expected: list[str] = [DELIMITER_PAIRS[opening]]
    for index in range(opening_index + 1, len(tokens)):
        value = tokens[index].value
        if value in DELIMITER_PAIRS:
            expected.append(DELIMITER_PAIRS[value])
        elif expected and value == expected[-1]:
            expected.pop()
            if not expected:
                return index
    raise LexingError(f"unclosed {opening} beginning at line {tokens[opening_index].line}")


def trailing_closure_end(tokens: list[Token], index: int) -> int:
    """Consume trailing closures, including `label: { ... }` forms."""
    while index < len(tokens):
        if tokens[index].value == "{":
            closing = matching_delimiter(tokens, index)
            index = closing + 1
            continue
        if (
            index + 2 < len(tokens)
            and tokens[index].value.isidentifier()
            and tokens[index + 1].value == ":"
            and tokens[index + 2].value == "{"
        ):
            closing = matching_delimiter(tokens, index + 2)
            index = closing + 1
            continue
        break
    return index


def has_direct_accessibility_label(tokens: list[Token], after_constructor: int) -> bool:
    """Inspect only the modifier chain applied to one SwiftUI control."""
    index = after_constructor
    while index + 1 < len(tokens) and tokens[index].value == ".":
        member = tokens[index + 1].value
        index += 2
        if member == "accessibilityLabel":
            return index < len(tokens) and tokens[index].value == "("
        if index < len(tokens) and tokens[index].value == "(":
            closing = matching_delimiter(tokens, index)
            index = trailing_closure_end(tokens, closing + 1)
        else:
            closure_end = trailing_closure_end(tokens, index)
            if closure_end == index:
                # A member access that is not a method cannot be followed by
                # a view modifier chain for this expression.
                return False
            index = closure_end
    return False


def missing_accessibility_labels(source: str) -> list[tuple[str, int]]:
    tokens = tokenize(source)
    missing: list[tuple[str, int]] = []
    for index, token in enumerate(tokens):
        if token.value not in {"TextField", "TextEditor"}:
            continue
        if index + 1 >= len(tokens) or tokens[index + 1].value != "(":
            continue
        closing = matching_delimiter(tokens, index + 1)
        after_constructor = trailing_closure_end(tokens, closing + 1)
        if not has_direct_accessibility_label(tokens, after_constructor):
            missing.append((token.value, token.line))
    return missing


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    arguments = parser.parse_args()
    gaps: list[str] = []
    for path in arguments.paths:
        try:
            source = path.read_text(encoding="utf-8")
        except OSError as error:
            print(f"{path}: {error}", file=sys.stderr)
            return 2
        try:
            gaps.extend(f"{path}:{line}" for _, line in missing_accessibility_labels(source))
        except LexingError as error:
            print(f"{path}: {error}", file=sys.stderr)
            return 2
    print("\n".join(gaps))
    return 1 if gaps else 0


if __name__ == "__main__":
    raise SystemExit(main())
