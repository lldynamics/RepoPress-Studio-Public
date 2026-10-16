#!/usr/bin/env python3
"""Fail-closed AT-SPI readiness probe for the packaged RepoPress desktop app.

The probe deliberately reads only accessible names and roles.  It never reads
text, values, descriptions, or DOM content from the application under test.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Protocol


MAX_NAME_LENGTH = 256
MAX_REQUIRED_NAMES = 32
MAX_WINDOW_DEPTH = 8
MAX_WINDOW_NODES = 512
MAX_CONTROL_DEPTH = 16
MAX_CONTROL_NODES = 2_048
POLL_INTERVAL_SECONDS = 0.05
MAX_TIMEOUT_MS = 120_000


class Adapter(Protocol):
    def desktop(self) -> Any: ...

    def child_count(self, node: Any) -> int: ...

    def child_at(self, node: Any, index: int) -> Any: ...

    def name(self, node: Any) -> str: ...

    def role(self, node: Any) -> str: ...

    def is_defunct(self, node: Any) -> bool: ...


@dataclass(frozen=True)
class ProbeConfig:
    window_name: str
    required_names: tuple[str, ...]
    timeout_ms: int


class AtspiAdapter:
    """Small compatibility layer around GI's AT-SPI bindings."""

    def __init__(self, atspi: Any) -> None:
        self._atspi = atspi

    def desktop(self) -> Any:
        return self._atspi.get_desktop(0)

    def child_count(self, node: Any) -> int:
        return int(node.get_child_count())

    def child_at(self, node: Any, index: int) -> Any:
        return node.get_child_at_index(index)

    def name(self, node: Any) -> str:
        return str(node.get_name() or "")

    def role(self, node: Any) -> str:
        try:
            role_name = node.get_role_name()
            if role_name:
                return str(role_name).lower()
        except Exception:
            pass
        role = node.get_role()
        try:
            return str(self._atspi.role_get_name(role) or "").lower()
        except Exception:
            return str(role).lower()

    def is_defunct(self, node: Any) -> bool:
        state = node.get_state_set()
        return bool(state.contains(self._atspi.StateType.DEFUNCT))


def load_atspi_adapter() -> Adapter:
    """Load GI only in production mode so unit tests need no desktop session."""
    # Some GLib builds abort, rather than raise, when Atspi is initialized
    # without a usable graphical session. Check first so a misconfiguration
    # still produces the bounded JSON diagnostic below.
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS") or not _display_is_usable():
        raise RuntimeError("atspi_session_unavailable")
    try:
        import gi  # type: ignore[import-not-found]

        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi  # type: ignore[import-not-found]
    except Exception as exc:
        raise RuntimeError("atspi_unavailable") from exc
    return AtspiAdapter(Atspi)


def _display_is_usable() -> bool:
    """Avoid triggering native AT-SPI initialization against a stale X display."""
    wayland = os.environ.get("WAYLAND_DISPLAY")
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if wayland and runtime_dir and Path(runtime_dir, wayland).is_socket():
        return True

    display = os.environ.get("DISPLAY")
    if not display:
        return False
    try:
        completed = subprocess.run(
            ["xdpyinfo", "-display", display],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return completed.returncode == 0


def _safe_bool(adapter: Adapter, node: Any, operation: str) -> bool:
    try:
        return bool(getattr(adapter, operation)(node))
    except Exception:
        return True if operation == "is_defunct" else False


def _safe_name(adapter: Adapter, node: Any) -> str | None:
    try:
        value = adapter.name(node)
    except Exception:
        return None
    return value if isinstance(value, str) else None


def _safe_role(adapter: Adapter, node: Any) -> str | None:
    try:
        value = adapter.role(node)
    except Exception:
        return None
    return value.lower() if isinstance(value, str) else None


def _children(adapter: Adapter, node: Any, limit: int) -> Iterable[Any]:
    try:
        count = adapter.child_count(node)
    except Exception:
        return ()
    if count < 0:
        return ()
    # A corrupt provider cannot turn a bounded node walk into a huge loop.
    return _children_by_index(adapter, node, min(count, max(0, limit)))


def _children_by_index(adapter: Adapter, node: Any, count: int) -> Iterable[Any]:
    for index in range(count):
        try:
            child = adapter.child_at(node, index)
        except Exception:
            continue
        if child is not None:
            yield child


def _walk(adapter: Adapter, root: Any, max_depth: int, max_nodes: int) -> Iterable[Any]:
    """Breadth-first walk resilient to defunct, cyclic, and broken nodes."""
    queue: deque[tuple[Any, int]] = deque([(root, 0)])
    seen_ids: set[int] = set()
    # GI creates short-lived proxy wrappers. Retain each processed wrapper for
    # this bounded walk so CPython cannot recycle its id() for a later node.
    # This list is bounded by max_nodes, just like the queue and seen_ids.
    seen_nodes: list[Any] = []
    visited = 0
    while queue and visited < max_nodes:
        node, depth = queue.popleft()
        identity = id(node)
        if identity in seen_ids:
            continue
        seen_ids.add(identity)
        seen_nodes.append(node)
        visited += 1
        if _safe_bool(adapter, node, "is_defunct"):
            continue
        yield node
        if depth >= max_depth:
            continue
        # Account for queued objects too, bounding both examined nodes and
        # outstanding accessibility calls/memory under an adversarial tree.
        capacity = max_nodes - visited - len(queue)
        for child in _children(adapter, node, capacity):
            queue.append((child, depth + 1))


def _is_top_level_window(adapter: Adapter, node: Any, expected_name: str) -> bool:
    name = _safe_name(adapter, node)
    if name != expected_name:
        return False
    role = _safe_role(adapter, node)
    return role is not None and any(kind in role for kind in ("window", "frame", "dialog"))


def find_window(adapter: Adapter, window_name: str) -> Any | None:
    try:
        desktop = adapter.desktop()
    except Exception:
        return None
    for node in _walk(adapter, desktop, MAX_WINDOW_DEPTH, MAX_WINDOW_NODES):
        if _is_top_level_window(adapter, node, window_name):
            return node
    return None


def matched_names(adapter: Adapter, window: Any, required_names: tuple[str, ...]) -> list[str]:
    remaining = set(required_names)
    found: list[str] = []
    for node in _walk(adapter, window, MAX_CONTROL_DEPTH, MAX_CONTROL_NODES):
        name = _safe_name(adapter, node)
        if name in remaining:
            found.append(name)
            remaining.remove(name)
            if not remaining:
                break
    return found


def report(result: str, config: ProbeConfig, startup_ms: int | None, matches: list[str]) -> dict[str, object]:
    # Keep fields fixed and values bounded: CI diagnostics must not serialize UI
    # values, text content, exception messages, or arbitrary accessibility data.
    return {
        "result": result,
        "startup_ms": startup_ms,
        "window_name": config.window_name,
        "matched_required_names": matches,
    }


def run_probe(
    adapter: Adapter,
    config: ProbeConfig,
    *,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> dict[str, object]:
    started = clock()
    deadline = started + (config.timeout_ms / 1000.0)
    observed_startup_ms: int | None = None
    last_matches: list[str] = []
    saw_window = False

    while True:
        window = find_window(adapter, config.window_name)
        if window is not None:
            saw_window = True
            if observed_startup_ms is None:
                observed_startup_ms = max(0, int((clock() - started) * 1000))
            last_matches = matched_names(adapter, window, config.required_names)
            if len(last_matches) == len(config.required_names):
                return report("passed", config, observed_startup_ms, last_matches)

        now = clock()
        if now >= deadline:
            result = "required_names_missing" if saw_window else "window_not_found"
            return report(result, config, observed_startup_ms, last_matches)
        sleeper(min(POLL_INTERVAL_SECONDS, deadline - now))


def write_report(output: str, payload: dict[str, object]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n"
    if output == "-":
        sys.stdout.write(encoded)
        return

    path = Path(output)
    parent = path.parent
    if not parent.is_dir():
        raise OSError("output_parent_unavailable")
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=parent, prefix=f".{path.name}.atspi-", delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def _bounded_name(value: str) -> str:
    if not value or len(value) > MAX_NAME_LENGTH or any(
        ord(char) < 32 or ord(char) == 127 for char in value
    ):
        raise argparse.ArgumentTypeError("names must be non-empty printable strings of at most 256 characters")
    return value


def _timeout(value: str) -> int:
    if not value.isdecimal():
        raise argparse.ArgumentTypeError("timeout must be a strict positive integer in milliseconds")
    timeout_ms = int(value)
    if not 0 < timeout_ms <= MAX_TIMEOUT_MS:
        raise argparse.ArgumentTypeError("timeout must be between 1 and 120000 milliseconds")
    return timeout_ms


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window-name", required=True, type=_bounded_name)
    parser.add_argument("--require-name", action="append", default=[], type=_bounded_name)
    parser.add_argument("--timeout-ms", required=True, type=_timeout)
    parser.add_argument("--output", default="-", help="JSON file path, or '-' for stdout")
    args = parser.parse_args(argv)
    unique = tuple(dict.fromkeys(args.require_name))
    if len(unique) > MAX_REQUIRED_NAMES:
        parser.error(f"at most {MAX_REQUIRED_NAMES} --require-name options are allowed")
    args.require_name = unique
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    config = ProbeConfig(args.window_name, args.require_name, args.timeout_ms)
    try:
        adapter = load_atspi_adapter()
        payload = run_probe(adapter, config)
    except RuntimeError:
        payload = report("atspi_unavailable", config, None, [])
    except Exception:
        payload = report("atspi_probe_failed", config, None, [])
    try:
        write_report(args.output, payload)
    except OSError:
        # This cannot be reported to the requested output safely; stderr stays
        # generic to avoid leaking exception strings from a CI environment.
        print("AT-SPI probe could not write its JSON diagnostic.", file=sys.stderr)
        return 1
    return 0 if payload["result"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
