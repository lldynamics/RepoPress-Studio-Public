#!/usr/bin/env python3
"""Offline tests for check-linux-atspi.py; no GI or desktop session required."""

from __future__ import annotations

import importlib.util
import gc
import io
import json
import os
import sys
import tempfile
import unittest
import weakref
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("check-linux-atspi.py")
SPEC = importlib.util.spec_from_file_location("check_linux_atspi", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
probe = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = probe
SPEC.loader.exec_module(probe)


class Node:
    def __init__(self, name: str = "", role: str = "panel", children: list["Node"] | None = None) -> None:
        self.name = name
        self.role = role
        self.children = children or []
        self.defunct = False
        self.broken_name = False
        self.broken_children = False


class FakeAdapter:
    def __init__(self, desktop: Node) -> None:
        self._desktop = desktop

    def desktop(self) -> Node:
        return self._desktop

    def child_count(self, node: Node) -> int:
        if node.broken_children:
            raise RuntimeError("fixture failure")
        return len(node.children)

    def child_at(self, node: Node, index: int) -> Node:
        return node.children[index]

    def name(self, node: Node) -> str:
        if node.broken_name:
            raise RuntimeError("fixture failure")
        return node.name

    def role(self, node: Node) -> str:
        return node.role

    def is_defunct(self, node: Node) -> bool:
        return node.defunct


class EphemeralNode:
    """A proxy wrapper that is not retained by its fake accessibility tree."""

    def __init__(self, token: str) -> None:
        self.token = token


class EphemeralAdapter:
    def __init__(self) -> None:
        self._children = {"desktop": ("application", "RepoPress Studio")}

    def desktop(self) -> EphemeralNode:
        return EphemeralNode("desktop")

    def child_count(self, node: EphemeralNode) -> int:
        return len(self._children.get(node.token, ()))

    def child_at(self, node: EphemeralNode, index: int) -> EphemeralNode:
        return EphemeralNode(self._children[node.token][index])

    def name(self, node: EphemeralNode) -> str:
        return node.token

    def role(self, node: EphemeralNode) -> str:
        return "frame" if node.token == "RepoPress Studio" else "application"

    def is_defunct(self, node: EphemeralNode) -> bool:
        return False


class Clock:
    def __init__(self) -> None:
        self.value = 0.0

    def now(self) -> float:
        return self.value

    def sleep(self, seconds: float) -> None:
        self.value += seconds


def config(*required: str, timeout_ms: int = 5) -> object:
    return probe.ProbeConfig("RepoPress Studio", required, timeout_ms)


def run(adapter: FakeAdapter, cfg: object) -> dict[str, object]:
    clock = Clock()
    return probe.run_probe(adapter, cfg, clock=clock.now, sleeper=clock.sleep)


class AtspiProbeTests(unittest.TestCase):
    def test_success_matches_named_controls(self) -> None:
        save = Node("Save", "push button")
        editor = Node("Editor", "text")
        window = Node("RepoPress Studio", "frame", [save, editor])
        result = run(FakeAdapter(Node(children=[window])), config("Editor", "Save"))
        self.assertEqual("passed", result["result"])
        self.assertEqual(0, result["startup_ms"])
        self.assertEqual(["Save", "Editor"], result["matched_required_names"])

    def test_window_missing_fails_closed(self) -> None:
        result = run(FakeAdapter(Node(children=[Node("Other", "frame")])), config("Save"))
        self.assertEqual("window_not_found", result["result"])
        self.assertIsNone(result["startup_ms"])
        self.assertEqual([], result["matched_required_names"])

    def test_control_missing_is_distinct_and_only_reports_matched_names(self) -> None:
        window = Node("RepoPress Studio", "frame", [Node("Save", "push button")])
        result = run(FakeAdapter(Node(children=[window])), config("Save", "Secret document body"))
        self.assertEqual("required_names_missing", result["result"])
        self.assertEqual(["Save"], result["matched_required_names"])
        self.assertNotIn("Secret document body", json.dumps(result))

    def test_timeout_and_invalid_parameters(self) -> None:
        self.assertEqual("window_not_found", run(FakeAdapter(Node()), config(timeout_ms=1))["result"])
        for value in ("0", "-1", "1.5", "120001"):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                probe.parse_args(["--window-name", "RepoPress Studio", "--timeout-ms", value])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            probe.parse_args(["--window-name", "RepoPress Studio", "--timeout-ms", "1", "--require-name", "\n"])
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            probe.parse_args(["--window-name", "RepoPress Studio\x7f", "--timeout-ms", "1"])

    def test_walk_retains_processed_ephemeral_proxies_to_prevent_id_reuse(self) -> None:
        adapter = EphemeralAdapter()
        walked = probe._walk(adapter, adapter.desktop(), max_depth=1, max_nodes=3)
        desktop = next(walked)
        application = next(walked)
        application_ref = weakref.ref(application)
        frame = next(walked)
        del desktop, application
        gc.collect()
        self.assertIsNotNone(application_ref())
        self.assertEqual("RepoPress Studio", frame.token)
        self.assertEqual(
            "RepoPress Studio",
            probe.find_window(EphemeralAdapter(), "RepoPress Studio").token,
        )

    def test_role_name_is_preferred_when_the_binding_exposes_it(self) -> None:
        class RoleNode:
            def get_role_name(self) -> str:
                return "frame"

            def get_role(self) -> object:
                raise AssertionError("numeric role fallback should not run")

        self.assertEqual("frame", probe.AtspiAdapter(object()).role(RoleNode()))

    def test_cyclic_defunct_and_exception_nodes_do_not_break_or_bypass_probe(self) -> None:
        bad = Node("Save", "push button")
        bad.broken_name = True
        defunct = Node("Editor", "text")
        defunct.defunct = True
        save = Node("Save", "push button")
        window = Node("RepoPress Studio", "frame", [bad, defunct, save])
        window.children.append(window)  # cyclic provider fixture
        result = run(FakeAdapter(Node(children=[window])), config("Save", "Editor"))
        self.assertEqual("required_names_missing", result["result"])
        self.assertEqual(["Save"], result["matched_required_names"])

    def test_atomic_output_replaces_complete_file_and_cleans_failed_temporary(self) -> None:
        payload = {"result": "passed", "startup_ms": 0, "window_name": "RepoPress Studio", "matched_required_names": []}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "diagnostic.json"
            path.write_text("old-complete-json\n", encoding="utf-8")
            probe.write_report(str(path), payload)
            self.assertEqual(payload, json.loads(path.read_text(encoding="utf-8")))
            path.write_text("old-complete-json\n", encoding="utf-8")
            with mock.patch.object(probe.os, "replace", side_effect=OSError("fixture")):
                with self.assertRaises(OSError):
                    probe.write_report(str(path), payload)
            self.assertEqual("old-complete-json\n", path.read_text(encoding="utf-8"))
            self.assertEqual([], [name for name in os.listdir(directory) if ".atspi-" in name])

    def test_production_cli_without_gi_emits_bounded_failure_json(self) -> None:
        # Force the load failure at the production boundary. This keeps the
        # offline suite independent of a desktop bus and GI installation.
        with mock.patch.object(probe, "load_atspi_adapter", side_effect=RuntimeError("no gi")):
            with mock.patch.object(sys, "stdout") as stdout:
                self.assertEqual(1, probe.main(["--window-name", "RepoPress Studio", "--timeout-ms", "1"]))
                written = stdout.write.call_args[0][0]
        data = json.loads(written)
        self.assertEqual("atspi_unavailable", data["result"])
        self.assertEqual([], data["matched_required_names"])

    def test_missing_display_or_wayland_is_rejected_before_gi_initialization(self) -> None:
        with mock.patch.dict(probe.os.environ, {"DBUS_SESSION_BUS_ADDRESS": "fixture"}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "atspi_session_unavailable"):
                probe.load_atspi_adapter()


if __name__ == "__main__":
    unittest.main(verbosity=2)
