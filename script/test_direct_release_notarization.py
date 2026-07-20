#!/usr/bin/env python3
"""Behavior tests for Developer ID signing and notarization orchestration."""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PACKAGER = ROOT / "script" / "package_direct_release.py"
IDENTITY = "A" * 40
SUBMISSION_ID = "11111111-2222-3333-4444-555555555555"


def executable(path: Path, source: str) -> None:
    path.write_text(source, encoding="utf-8")
    path.chmod(0o755)


def invoke(
    fixture: Path,
    environment: dict[str, str],
    *arguments: str,
    succeeds: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [
            sys.executable,
            str(PACKAGER),
            "--root",
            str(fixture),
            *arguments,
        ],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if succeeds and result.returncode != 0:
        raise AssertionError(result.stdout)
    if not succeeds and result.returncode == 0:
        raise AssertionError("Direct release packager unexpectedly accepted an invalid fixture")
    return result


with tempfile.TemporaryDirectory(prefix="direct-release-notarization-") as directory:
    fixture = Path(directory) / "project"
    scripts = fixture / "script"
    packaging = fixture / "Packaging"
    firefox = fixture / "BrowserExtension" / "Firefox"
    tools = fixture / "tools"
    scripts.mkdir(parents=True)
    packaging.mkdir()
    firefox.mkdir(parents=True)
    tools.mkdir()
    calls = fixture / "calls.log"
    build_calls = fixture / "build.log"

    with (packaging / "DirectDistribution.entitlements").open("wb") as handle:
        plistlib.dump({}, handle)
    (firefox / "manifest.json").write_text('{"version":"0.12.0"}\n', encoding="utf-8")
    signed_xpi = (
        fixture
        / "dist"
        / "browser-extension"
        / "knowledge-capture-firefox-0.12.0.xpi"
    )
    signed_xpi.parent.mkdir(parents=True)
    signed_xpi.write_text("signed fixture\n", encoding="utf-8")
    executable(
        scripts / "firefox_extension_release.py",
        """#!/usr/bin/env python3
raise SystemExit(0)
""",
    )

    executable(
        scripts / "build_and_run.sh",
        """#!/usr/bin/env bash
set -euo pipefail
printf 'identity=%s direct=%s args=%s\n' "$CODE_SIGN_IDENTITY" "$DIRECT_DISTRIBUTION_BUILD" "$*" >>"$STUB_BUILD_CALLS"
app="$STUB_ROOT/dist/PersonalSitePublisherMac.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/BrowserExtension/Release"
printf 'app\n' >"$app/Contents/MacOS/PersonalSitePublisherMac"
printf 'host\n' >"$app/Contents/MacOS/KnowledgeNativeMessagingHost"
cp "$STUB_INFO_PLIST" "$app/Contents/Info.plist"
printf 'signed xpi\n' >"$app/Contents/Resources/BrowserExtension/Release/knowledge-capture-firefox-0.12.0.xpi"
printf '{}\n' >"$app/Contents/Resources/BrowserExtension/Release/updates.json"
printf '%s\n' "$app"
""",
    )

    executable(
        tools / "security",
        """#!/usr/bin/env bash
set -euo pipefail
kind="${STUB_SECURITY_KIND:-Developer ID Application}"
printf '  1) %s "%s: Fixture Publisher (TEAM123456)"\n' "$STUB_IDENTITY" "$kind"
printf '     1 valid identities found\n'
""",
    )
    executable(
        tools / "codesign",
        """#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >>"$STUB_CALLS"
if [[ " $* " == *" -dv "* ]]; then
  printf '%s\n' \
    'Authority=Developer ID Application: Fixture Publisher (TEAM123456)' \
    'TeamIdentifier=TEAM123456' \
    'flags=0x10000(runtime)' \
    'Timestamp=Jul 19, 2026 at 12:00:00' >&2
fi
""",
    )
    executable(
        tools / "ditto",
        """#!/usr/bin/env bash
set -euo pipefail
printf 'ditto %s\n' "$*" >>"$STUB_CALLS"
destination="${@: -1}"
mkdir -p "$(dirname "$destination")"
printf 'zip\n' >"$destination"
""",
    )
    executable(
        tools / "xcrun",
        f"""#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >>"$STUB_CALLS"
if [[ "${{1:-}} ${{2:-}}" == "notarytool submit" ]]; then
  printf '{{"id":"{SUBMISSION_ID}","status":"%s"}}\n' "${{STUB_NOTARY_STATUS:-Accepted}}"
elif [[ "${{1:-}} ${{2:-}}" == "notarytool log" ]]; then
  destination="${{@: -1}}"
  printf '{{"issues":[]}}\n' >"$destination"
elif [[ "${{1:-}} ${{2:-}}" == "notarytool history" ]]; then
  printf '{{"history":[]}}\n'
fi
""",
    )
    executable(
        tools / "spctl",
        """#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >>"$STUB_CALLS"
printf '%s\n' 'PersonalSitePublisherMac.app: accepted' 'source=Notarized Developer ID'
""",
    )

    info_path = fixture / "fixture-info.plist"

    def write_info(*, hardened: bool = True) -> None:
        with info_path.open("wb") as handle:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.jinfang.PersonalSitePublisherMac",
                    "CFBundleShortVersionString": "1.0",
                    "PersonalSitePublisherBuildConfiguration": "Release",
                    "PersonalSitePublisherDistributionChannel": "Direct",
                    "PersonalSitePublisherBrowserExtensionAvailable": True,
                    "PersonalSitePublisherFirefoxSignedPackageAvailable": True,
                    "PersonalSitePublisherHardenedRuntimeEnabled": hardened,
                },
                handle,
            )

    write_info()
    environment = os.environ.copy()
    environment.update(
        {
            "SECURITY_TOOL": str(tools / "security"),
            "CODESIGN_TOOL": str(tools / "codesign"),
            "DITTO_TOOL": str(tools / "ditto"),
            "XCRUN_TOOL": str(tools / "xcrun"),
            "SPCTL_TOOL": str(tools / "spctl"),
            "STUB_CALLS": str(calls),
            "STUB_BUILD_CALLS": str(build_calls),
            "STUB_ROOT": str(fixture),
            "STUB_INFO_PLIST": str(info_path),
            "STUB_IDENTITY": IDENTITY,
        }
    )

    prepare_output = fixture / "prepared"
    prepared = invoke(
        fixture,
        environment,
        "--prepare-only",
        "--identity",
        IDENTITY,
        "--output-dir",
        str(prepare_output),
    )
    assert "Notarization was not submitted" in prepared.stdout
    assert (prepare_output / "PersonalSitePublisherMac-1.0-Direct-pre-notarization.zip").is_file()
    assert "identity=" + IDENTITY + " direct=1 args=--package-only --release" in build_calls.read_text()
    assert "xcrun" not in calls.read_text()

    readiness = invoke(
        fixture,
        environment,
        "--check-readiness",
        "--identity",
        IDENTITY,
        "--keychain-profile",
        "fixture-notary",
    )
    assert "signing and notarization credentials: ready" in readiness.stdout
    assert "notarytool history" in calls.read_text()

    missing_identity = invoke(fixture, environment, "--prepare-only", succeeds=False)
    assert "explicit Developer ID Application identity is required" in missing_identity.stdout

    wrong_environment = dict(environment, STUB_SECURITY_KIND="Apple Development")
    wrong_identity = invoke(
        fixture,
        wrong_environment,
        "--prepare-only",
        "--identity",
        IDENTITY,
        succeeds=False,
    )
    assert "not one unique valid Developer ID Application" in wrong_identity.stdout

    missing_profile = invoke(
        fixture,
        environment,
        "--notarize",
        "--identity",
        IDENTITY,
        succeeds=False,
    )
    assert "requires a notarytool keychain profile" in missing_profile.stdout

    notarized_output = fixture / "notarized"
    notarized = invoke(
        fixture,
        environment,
        "--notarize",
        "--identity",
        IDENTITY,
        "--keychain-profile",
        "fixture-notary",
        "--output-dir",
        str(notarized_output),
    )
    assert "Notarization accepted" in notarized.stdout
    receipt = json.loads((notarized_output / "notarytool-submission.json").read_text())
    assert receipt == {"id": SUBMISSION_ID, "status": "Accepted"}
    assert (notarized_output / "PersonalSitePublisherMac-1.0-Direct-notarized.zip").is_file()
    call_text = calls.read_text()
    assert "notarytool submit" in call_text
    assert "stapler staple" in call_text
    assert "stapler validate" in call_text
    assert "spctl -a -vv --type execute" in call_text

    rejected_output = fixture / "rejected"
    rejected_environment = dict(environment, STUB_NOTARY_STATUS="Invalid")
    rejected = invoke(
        fixture,
        rejected_environment,
        "--notarize",
        "--identity",
        IDENTITY,
        "--keychain-profile",
        "fixture-notary",
        "--output-dir",
        str(rejected_output),
        succeeds=False,
    )
    assert "status='Invalid'" in rejected.stdout
    assert (rejected_output / "notarytool-submission.json").is_file()
    assert (rejected_output / f"notarytool-{SUBMISSION_ID}.json").is_file()
    assert not (rejected_output / "PersonalSitePublisherMac-1.0-Direct-notarized.zip").exists()

    write_info(hardened=False)
    missing_runtime = invoke(
        fixture,
        environment,
        "--prepare-only",
        "--identity",
        IDENTITY,
        "--output-dir",
        str(fixture / "missing-runtime"),
        succeeds=False,
    )
    assert "PersonalSitePublisherHardenedRuntimeEnabled" in missing_runtime.stdout

    with (packaging / "DirectDistribution.entitlements").open("wb") as handle:
        plistlib.dump({"com.apple.security.get-task-allow": True}, handle)
    unsafe_entitlements = invoke(
        fixture,
        environment,
        "--prepare-only",
        "--identity",
        IDENTITY,
        succeeds=False,
    )
    assert "must not enable get-task-allow" in unsafe_entitlements.stdout

print("Direct release notarization behavior: passed")
