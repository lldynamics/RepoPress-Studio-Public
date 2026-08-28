#!/usr/bin/env python3
"""Regression test for timeout, incremental output, and release artifact binding."""

from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def load_runner(path: Path) -> object:
    specification = importlib.util.spec_from_file_location("release_gate_runner_fixture", path)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="release-runner-contract.") as temporary:
        fixture = Path(temporary)
        script = fixture / "script"
        app = fixture / "dist" / "RepoPress Studio.app"
        executable = app / "Contents" / "MacOS" / "PersonalSitePublisherMac"
        resource = app / "Contents" / "Resources" / "fixture.txt"
        script.mkdir(parents=True)
        executable.parent.mkdir(parents=True)
        resource.parent.mkdir(parents=True)
        (fixture / "Packaging").mkdir()
        shutil.copy2(ROOT / "script" / "release_gate_runner.py", script / "release_gate_runner.py")
        shutil.copy2(ROOT / "script" / "release_gate_result.schema.json", script / "release_gate_result.schema.json")
        (fixture / "Packaging" / "BuildVersion.xcconfig").write_text(
            "MARKETING_VERSION = 2.4\nCURRENT_PROJECT_VERSION = 91\n",
            encoding="utf-8",
        )
        executable.write_bytes(b"fixture executable")
        resource.write_text("artifact payload\n", encoding="utf-8")
        (app / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleName": "RepoPress Studio",
                    "CFBundleDisplayName": "RepoPress Studio",
                    "CFBundleExecutable": "PersonalSitePublisherMac",
                    "CFBundleIdentifier": "com.jinfang.PersonalSitePublisherMac",
                    "CFBundleShortVersionString": "2.4",
                    "CFBundleVersion": "91",
                }
            )
        )
        (script / "package-ok.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (script / "timeout.sh").write_text("#!/bin/sh\nsleep 4\n", encoding="utf-8")
        (script / "failure.sh").write_text(
            "#!/bin/sh\n"
            "printf 'token=ghp_abcdefghijklmnopqrstuvwxyz123456 %s /Users/fixture/private /private/tmp/fixture\\n' "
            "\"$RELEASE_RUNNER_SECRET\"\n"
            "printf 'warning artifact.json\\n'\n"
            "yes x | head -c 70000\n"
            "exit 7\n",
            encoding="utf-8",
        )
        (script / "release_checks.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "description": "fixture",
                    "defaultTimeoutSeconds": 1,
                    "profiles": {
                        "common": ["ui-runtime", "timeout", "failure", "standard", "strict"],
                        "direct": [],
                        "chrome": [],
                    },
                    "checks": [
                        {
                            "id": "ui-runtime",
                            "title": "Package fixture",
                            "groups": ["quick"],
                            "source": ["dist"],
                            "evidence": ["fixture app"],
                            "strictness": "always",
                            "command": ["bash", "script/package-ok.sh"],
                        },
                        {
                          "id": "timeout",
                            "title": "Timeout fixture",
                            "groups": ["quick"],
                            "source": ["script/timeout.sh"],
                            "evidence": ["timeout classification"],
                            "strictness": "always",
                          "command": ["bash", "script/timeout.sh"],
                        },
                        {
                            "id": "failure",
                            "title": "Redacted failure fixture",
                            "groups": ["quick"],
                            "source": ["script/failure.sh"],
                            "evidence": ["bounded redacted failure diagnostics"],
                            "strictness": "always",
                            "environment": {"RELEASE_RUNNER_SECRET": "fixture-environment-secret"},
                            "command": ["bash", "script/failure.sh"],
                        },
                        {
                            "id": "standard",
                            "title": "Standard fixture",
                            "source": ["script/package-ok.sh"],
                            "evidence": ["standard profile inclusion"],
                            "strictness": "standard",
                            "command": ["bash", "script/package-ok.sh"],
                        },
                        {
                            "id": "strict",
                            "title": "Strict fixture",
                            "source": ["script/package-ok.sh"],
                            "evidence": ["strict profile inclusion"],
                            "strictness": "strict",
                            "command": ["bash", "script/package-ok.sh"],
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        (fixture / ".gitignore").write_text(".build/\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=fixture, check=True)
        subprocess.run(["git", "add", "."], cwd=fixture, check=True)
        subprocess.run(
            [
                "git",
                "-c",
                "user.name=Release Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            cwd=fixture,
            check=True,
        )
        direct_list = subprocess.run(
            [
                "python3",
                str(script / "release_gate_runner.py"),
                "--profile",
                "direct",
                "--list",
            ],
            cwd=fixture,
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        assert "ui-runtime\talways\t" in direct_list, direct_list
        assert "standard\tstandard\t" in direct_list, direct_list
        assert "strict\tstrict\t" in direct_list, direct_list
        standard_list = subprocess.run(
            ["python3", str(script / "release_gate_runner.py"), "--list"],
            cwd=fixture,
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        assert "standard\tstandard\t" in standard_list, standard_list
        assert "strict\tstrict\t" not in standard_list, standard_list
        explicit_strict_list = subprocess.run(
            [
                "python3",
                str(script / "release_gate_runner.py"),
                "--check",
                "strict",
                "--list",
            ],
            cwd=fixture,
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        assert "strict\tstrict\t" in explicit_strict_list, explicit_strict_list
        result_path = fixture / ".build" / "result.json"
        process = subprocess.Popen(
            [
                "python3",
                str(script / "release_gate_runner.py"),
                "--quick",
                "--result-json",
                str(result_path),
            ],
            cwd=fixture,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        partial = None
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if result_path.is_file():
                candidate = json.loads(result_path.read_text(encoding="utf-8"))
                if (
                    candidate.get("runState") == "partial"
                    and (candidate.get("activeCheck") or {}).get("id") == "timeout"
                ):
                    partial = candidate
                    break
            time.sleep(0.05)
        assert partial is not None, "runner did not incrementally persist the active timeout check"
        assert partial["summary"]["completedCheckCount"] == 1, partial
        runner = load_runner(script / "release_gate_runner.py")
        runner.validate_result_payload(partial)
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 1, (stdout, stderr)

        payload = json.loads(result_path.read_text(encoding="utf-8"))
        assert payload["schemaVersion"] == 2, payload
        assert payload["runState"] == "complete", payload
        assert payload["startedAt"] <= payload["generatedAt"], payload
        assert payload["releaseIdentity"]["marketingVersion"] == "2.4", payload
        assert payload["releaseIdentity"]["buildNumber"] == "91", payload
        assert payload["releaseIdentity"]["sourceCommit"], payload
        assert payload["releaseIdentity"]["sourceDirty"] is False, payload
        timeout_result = next(item for item in payload["checks"] if item["id"] == "timeout")
        assert timeout_result["status"] == "timed_out", timeout_result
        assert timeout_result["returnCode"] == 124, timeout_result
        assert timeout_result["timeoutSeconds"] == 1, timeout_result
        assert timeout_result["diagnostics"]["logPath"].startswith(".build/"), timeout_result
        assert timeout_result["diagnostics"]["tail"], timeout_result
        failure_result = next(item for item in payload["checks"] if item["id"] == "failure")
        diagnostics = failure_result["diagnostics"]
        assert failure_result["status"] == "failed", failure_result
        assert failure_result["returnCode"] == 7, failure_result
        assert diagnostics["truncated"] is True, diagnostics
        assert diagnostics["capturedBytes"] <= 64 * 1024, diagnostics
        assert diagnostics["logPath"].startswith(".build/"), diagnostics
        log_path = fixture / diagnostics["logPath"]
        log_content = log_path.read_text(encoding="utf-8")
        assert len(log_content.encode("utf-8")) <= 64 * 1024 + 64, diagnostics
        assert hashlib.sha256(log_content.encode("utf-8")).hexdigest() == diagnostics["sha256"], diagnostics
        for forbidden in (
            "fixture-environment-secret",
            "ghp_abcdefghijklmnopqrstuvwxyz123456",
            "/Users/fixture",
            "/private/tmp/fixture",
        ):
            assert forbidden not in log_content, diagnostics
            assert forbidden not in diagnostics["tail"], diagnostics
        assert "<redacted" in log_content, diagnostics
        assert "warning artifact.json" in log_content, diagnostics
        assert next(item for item in payload["checks"] if item["id"] == "ui-runtime")["diagnostics"] is None
        runner.validate_result_payload(payload)

        malformed_payloads = []
        malformed_date = copy.deepcopy(payload)
        malformed_date["generatedAt"] = "not-a-date"
        malformed_payloads.append(malformed_date)
        malformed_timeout = copy.deepcopy(payload)
        malformed_timeout["checks"][0]["timeoutSeconds"] = -1
        malformed_payloads.append(malformed_timeout)
        malformed_return_code = copy.deepcopy(payload)
        malformed_return_code["checks"][0]["returnCode"] = "zero"
        malformed_payloads.append(malformed_return_code)
        malformed_status = copy.deepcopy(payload)
        malformed_status["checks"][0]["status"] = "unknown"
        malformed_payloads.append(malformed_status)
        missing_field = copy.deepcopy(payload)
        del missing_field["summary"]["passedCount"]
        malformed_payloads.append(missing_field)
        extra_field = copy.deepcopy(payload)
        extra_field["unexpected"] = True
        malformed_payloads.append(extra_field)
        incomplete_complete = copy.deepcopy(payload)
        incomplete_complete["summary"]["completedCheckCount"] -= 1
        malformed_payloads.append(incomplete_complete)
        for malformed in malformed_payloads:
            try:
                runner.validate_result_payload(malformed)
            except ValueError:
                pass
            else:
                raise AssertionError(f"malformed result was accepted: {malformed}")

        stable_complete = result_path.read_text(encoding="utf-8")
        invalid_result = copy.deepcopy(payload["checks"])
        invalid_result[0]["returnCode"] = "not-an-integer"
        try:
            runner.write_result_json(
                result_path,
                "quick",
                None,
                invalid_result,
                0,
                [],
                repository=payload["repository"],
                execution=payload["execution"],
                run_started_at=payload["startedAt"],
                run_state="complete",
                expected_check_count=len(invalid_result),
            )
        except ValueError:
            pass
        else:
            raise AssertionError("invalid complete result was written")
        assert result_path.read_text(encoding="utf-8") == stable_complete
        artifact = payload["artifacts"]["packagedApp"]
        assert artifact["status"] == "hashed", artifact
        assert artifact["identity"]["marketingVersion"] == "2.4", artifact
        assert artifact["identity"]["buildNumber"] == "91", artifact
        assert artifact["identity"]["sourceCommit"] == payload["repository"]["commit"], artifact
        assert artifact["identity"]["sourceDirty"] is False, artifact
        assert artifact["identity"]["versionMatchesConfiguration"] is True, artifact
        assert artifact["identity"]["buildMatchesConfiguration"] is True, artifact
        assert artifact["observedAt"], artifact
        assert artifact["codeSignature"]["status"] in {"inspected", "inspection_failed"}, artifact
        paths = {entry["path"] for entry in artifact["content"]["entries"]}
        assert "Contents/MacOS/PersonalSitePublisherMac" in paths, artifact
        assert "Contents/Info.plist" in paths, artifact
        assert "Contents/Resources/fixture.txt" in paths, artifact
        assert len(artifact["content"]["treeSha256"]) == 64, artifact

        # Regression: the historical executable-named bundle must not be
        # accepted as release evidence after build_and_run produces the
        # user-facing RepoPress Studio.app bundle.
        legacy_app = fixture / "dist" / "PersonalSitePublisherMac.app"
        app.rename(legacy_app)
        legacy_result_path = fixture / ".build" / "legacy-name-result.json"
        legacy_process = subprocess.run(
            [
                "python3",
                str(script / "release_gate_runner.py"),
                "--quick",
                "--result-json",
                str(legacy_result_path),
            ],
            cwd=fixture,
            text=True,
            capture_output=True,
            check=False,
        )
        assert legacy_process.returncode == 1, legacy_process.stderr
        legacy_payload = json.loads(legacy_result_path.read_text(encoding="utf-8"))
        assert legacy_payload["artifacts"]["packagedApp"]["status"] == "identity_mismatch", legacy_payload
        assert any("identity mismatch" in blocker for blocker in legacy_payload["blockers"]), legacy_payload
        legacy_app.rename(app)

        # Regression: a passing package check cannot hide a missing artifact.
        shutil.rmtree(app)
        missing_result_path = fixture / ".build" / "missing-artifact-result.json"
        missing_process = subprocess.run(
            [
                "python3",
                str(script / "release_gate_runner.py"),
                "--quick",
                "--result-json",
                str(missing_result_path),
            ],
            cwd=fixture,
            text=True,
            capture_output=True,
            check=False,
        )
        assert missing_process.returncode == 1, missing_process.stderr
        missing_payload = json.loads(missing_result_path.read_text(encoding="utf-8"))
        assert missing_payload["artifacts"]["packagedApp"]["status"] == "missing", missing_payload
        assert any("artifact is missing" in blocker for blocker in missing_payload["blockers"]), missing_payload

        # Regression: malformed bundle contents must be a blocker, never a
        # successful result with an absent content hash.
        app.mkdir(parents=True)
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "MacOS" / "PersonalSitePublisherMac").write_bytes(b"fixture executable")
        (app / "Contents" / "MacOS" / "PersonalSitePublisherMac").chmod(0o755)
        (app / "Contents" / "Info.plist").write_bytes(b"not-a-plist")
        unhashable_result_path = fixture / ".build" / "unhashable-artifact-result.json"
        unhashable_process = subprocess.run(
            [
                "python3",
                str(script / "release_gate_runner.py"),
                "--quick",
                "--result-json",
                str(unhashable_result_path),
            ],
            cwd=fixture,
            text=True,
            capture_output=True,
            check=False,
        )
        assert unhashable_process.returncode == 1, unhashable_process.stderr
        unhashable_payload = json.loads(unhashable_result_path.read_text(encoding="utf-8"))
        assert unhashable_payload["artifacts"]["packagedApp"]["status"] == "unhashable", unhashable_payload
        assert any("not hashable" in blocker for blocker in unhashable_payload["blockers"]), unhashable_payload

    print("release gate runner contract test: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
