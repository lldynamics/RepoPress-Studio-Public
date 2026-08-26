#!/usr/bin/env python3
"""Regression tests for check_tooling_workflow_source_paths.py."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GATE = ROOT / "script" / "check_tooling_workflow_source_paths.py"


def run_gate(manifest: Path, workflow: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(GATE), "--manifest", str(manifest), "--workflow", str(workflow)],
        text=True,
        capture_output=True,
        check=False,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="tooling-workflow-paths.") as temporary:
        root = Path(temporary)
        manifest = root / "release_checks.json"
        workflow = root / "tooling.yml"
        manifest.write_text(
            json.dumps(
                {
                    "checks": [
                        {
                            "id": "browser-extension-release",
                            "source": [
                                "BrowserExtension",
                                "BrowserExtension/manifest.json",
                                "Sources/App/Coordinator.swift",
                                "Tests/AppTests/OriginPolicyTests.swift",
                            ],
                        },
                        {"id": "unrelated", "source": ["Unwatched/NotRelevant.swift"]},
                    ]
                }
            ),
            encoding="utf-8",
        )
        workflow.write_text(
            "on:\n"
            "  pull_request:\n"
            "    paths:\n"
            "      - 'BrowserExtension/**'\n"
            "      - 'Sources/App/Coordinator.swift'\n"
            "      - 'Tests/AppTests/OriginPolicyTests.swift'\n"
            "  workflow_dispatch:\n",
            encoding="utf-8",
        )
        accepted = run_gate(manifest, workflow)
        assert accepted.returncode == 0, accepted.stderr

        workflow.write_text(
            "on:\n"
            "  pull_request:\n"
            "    paths:\n"
            "      - 'BrowserExtension/**'\n"
            "      - 'Sources/App/Coordinator.swift'\n"
            "  workflow_dispatch:\n",
            encoding="utf-8",
        )
        rejected = run_gate(manifest, workflow)
        assert rejected.returncode != 0, rejected
        assert "Tests/AppTests/OriginPolicyTests.swift" in rejected.stderr, rejected.stderr

    print("tooling workflow source path test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
