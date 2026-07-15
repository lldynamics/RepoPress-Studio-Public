#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${SCREENSHOT_SURFACE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST_FILE="${SCREENSHOT_MANIFEST_FILE:-$ROOT_DIR/docs/app-store-screenshots/SCREENSHOT_MANIFEST.md}"
CAPTURE_SCRIPT="${SCREENSHOT_CAPTURE_SCRIPT:-$ROOT_DIR/script/capture_app_screenshots.sh}"
BUILD_SCRIPT="${SCREENSHOT_BUILD_SCRIPT:-$ROOT_DIR/script/build_and_run.sh}"
SOURCE_MANIFEST_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release_evidence_source_manifest.py"

python3 - "$ROOT_DIR" "$MANIFEST_FILE" "$CAPTURE_SCRIPT" "$BUILD_SCRIPT" "$SOURCE_MANIFEST_HELPER" <<'PY'
import importlib.util
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
capture_path = Path(sys.argv[3])
build_script_path = Path(sys.argv[4])
source_manifest_path = Path(sys.argv[5])

source_manifest_spec = importlib.util.spec_from_file_location("release_evidence_source_manifest", source_manifest_path)
source_manifest = importlib.util.module_from_spec(source_manifest_spec)
assert source_manifest_spec and source_manifest_spec.loader
source_manifest_spec.loader.exec_module(source_manifest)

required = {
    "writing": {
        "target": "writing.png",
        "capture": ["writing", "editor, preview, metadata", "contextual writing actions"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift": [
                "MacMarkdownComposerView",
                "markdownBlocks",
                "pasteAIPromptToClipboard",
            ],
            "Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift": [
                "EditorFrontMatterSection",
                "EditorSocialPreviewSection",
            ],
        },
    },
    "ai-chat": {
        "target": "ai-chat.png",
        "capture": ["AI assistant Inspector", "conversation", "context", "quick prompts"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift": [
                "ai-assistant-inspector",
                "ai-assistant-composer",
                ".keyboardShortcut(.return, modifiers: [.command])",
            ],
            "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorSections.swift": [
                "AIChatConversationInspectorSection",
                "AIChatContextOverviewInspectorSection",
            ],
            "Sources/PublishingWorkbenchCore/Stores/WorkbenchAIStore.swift": [
                "openAIChatWorkspace",
                "isAIPublishingAssistantPresented = true",
            ],
        },
    },
    "sync-api-publish": {
        "target": "sync-api-publish.png",
        "capture": ["sync-api-publish", "GitHub/GitLab token check", "remote conflict preview", "PR/MR controls"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift": [
                "onlinePublishCenterSection",
                "remoteConflictPreview",
                "PR/MR",
            ],
            "Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift": [
                "TokenRepositoryTokenSection",
                "仓库访问 Token",
            ],
        },
    },
    "seo-social-preview": {
        "target": "seo-social-preview.png",
        "capture": ["seo-social-preview", "Open Graph", "Twitter card", "manual refresh", "external debug"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/EditorInspectorSections.swift": [
                "EditorSocialPreviewSection",
                "Open Graph",
                "Twitter/X",
                "refreshSEOSocialPreview",
                "relatedArticleSuggestionSection",
            ],
            "Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift": [
                "testSnapshotBuildsSearchOpenGraphAndTwitterCards",
            ],
        },
    },
    "deployment-status": {
        "target": "deployment-status.png",
        "capture": ["deployment-status", "GitHub Pages/Actions", "Netlify", "Vercel", "Cloudflare Pages"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift": [
                "deploymentPollingSummary",
                "refreshDeploymentStatus",
                "GitHub Pages / Actions",
                "Netlify",
                "Vercel",
                "Cloudflare Pages",
            ],
            "Sources/PersonalSitePublisherMac/Views/TokenSettingsView.swift": [
                "deploymentProviderBinding",
            ],
        },
    },
    "maintenance": {
        "target": "maintenance.png",
        "capture": ["maintenance", "content calendar", "taxonomy governance", "operation log"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSectionGroups.swift": [
                "SiteMaintenanceCalendarSection",
                "SiteMaintenanceLinkAuditSection",
                "SiteMaintenanceOperationLogSection",
            ],
        },
    },
    "general-drafts": {
        "target": "general-drafts.png",
        "capture": ["general-drafts", "cross-site drafts", "backup repository", "reuse checklist"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift": [
                "GeneralDraftLibraryDetailView",
                "backupSection",
                "reusePlanSection",
                "crossSiteMaterialPackageMarkdown",
            ],
            "Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift": [
                "GeneralDraftBackupPlan",
                "reusePlan",
                "backupPlan",
                "general-drafts/MANIFEST.md",
            ],
        },
    },
    "pro-settings": {
        "target": "pro-settings.png",
        "capture": ["pro-settings", "free quota", "Pro unlock", "purchase", "restore"],
        "source": {
            "Sources/PersonalSitePublisherMac/Support/ScreenshotDemoSettingsPresenter.swift": [
                "ScreenshotDemoSettingsPresenter",
                "showSettingsWindow:",
                "requestedSurfaceFromEnvironment == .proSettings",
            ],
            "Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift": [
                "purchasePro(store:",
                "restorePro(store:",
                "Product.products(for: [productID])",
                "Transaction.currentEntitlements",
            ],
            "Sources/PersonalSitePublisherMac/Views/SettingsView.swift": [
                "selectedSettingsTab",
                "ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .proSettings ? .pro",
            ],
            "Sources/PersonalSitePublisherMac/Views/ProSandboxVerificationSection.swift": [
                "StoreKit 沙盒核验",
            ],
        },
    },
    "privacy-lock": {
        "target": "privacy-lock.png",
        "capture": ["privacy-lock", "manually hidden workbench", "private-content masking"],
        "source": {
            "Sources/PersonalSitePublisherMac/Views/SharedViews.swift": [
                "PrivacyLockOverlay",
                "privacy-lock-overlay",
            ],
            "Sources/PersonalSitePublisherMac/Views/ContentView.swift": [
                "isPrivacyLocked",
                "lockPrivacy(reason",
                "canUseProtectedWorkbench",
            ],
        },
    },
}


def fail(message: str) -> None:
    print(f"screenshot surface map: {message}", file=sys.stderr)
    sys.exit(1)


if not manifest_path.is_file():
    fail(f"missing manifest: {manifest_path}")
if not capture_path.is_file():
    fail(f"missing capture script: {capture_path}")
if not build_script_path.is_file():
    fail(f"missing build script: {build_script_path}")
if not source_manifest_path.is_file():
    fail(f"missing source manifest helper: {source_manifest_path}")

manifest_text = manifest_path.read_text(encoding="utf-8")
manifest_entries = {}
for line in manifest_text.splitlines():
    if not line.lstrip().startswith("|"):
        continue
    values = re.findall(r"`([^`]+)`", line)
    if len(values) >= 2:
        manifest_entries[values[0]] = values[1]

capture_text = capture_path.read_text(encoding="utf-8")
build_script_text = build_script_path.read_text(encoding="utf-8")
errors = []

for marker in [
    "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO",
    "PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE",
    "FORCE_RELAUNCH",
    "--force-relaunch",
    "--auto-window",
    "frontmost_app_window_id",
    "AXWindowNumber",
    "capture_current_app_window",
    "screencapture -x -l",
    "--auto-window with --real-data requires --only",
    "--auto-window with --skip-build requires --only",
    "pkill -TERM -x",
    "${ONLY_ID:-writing}",
]:
    if marker not in capture_text:
        errors.append(f"capture script missing demo launch marker {marker!r}")

for marker in [
    "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO",
    "PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE",
    "--screenshot-demo [id]",
    "--screenshot-surface <id>",
    "--list-screenshot-surfaces",
    "contains_screenshot_surface",
    "required_screenshot_surfaces",
]:
    if marker not in build_script_text:
        errors.append(f"build/run script missing screenshot surface marker {marker!r}")

for screenshot_id, spec in required.items():
    target = spec["target"]
    if manifest_entries.get(screenshot_id) != target:
        actual = manifest_entries.get(screenshot_id, "<missing>")
        errors.append(f"{screenshot_id}: manifest target is {actual}, expected {target}")

    for marker in spec["capture"]:
        if marker not in capture_text:
            errors.append(f"{screenshot_id}: capture script missing marker {marker!r}")

    if screenshot_id not in build_script_text:
        errors.append(f"{screenshot_id}: build/run script missing screenshot surface id")

    for relative_path, markers in spec["source"].items():
        for marker in markers:
            candidate_paths = source_manifest.expanded_source_paths(relative_path, marker)
            matched = False
            missing_paths = []
            for candidate_path in candidate_paths:
                source_path = root / candidate_path
                if not source_path.is_file():
                    missing_paths.append(candidate_path)
                    continue
                source_text = source_path.read_text(encoding="utf-8")
                if marker in source_text:
                    matched = True
                    break
            if not matched:
                if len(missing_paths) == len(candidate_paths):
                    errors.append(f"{screenshot_id}: missing source file(s) for {relative_path}: {', '.join(candidate_paths)}")
                else:
                    errors.append(f"{screenshot_id}: {relative_path} expanded source files missing marker {marker!r}")

extra_manifest_ids = sorted(set(manifest_entries) - set(required))
if extra_manifest_ids:
    errors.append("manifest has unexpected screenshot id(s): " + ", ".join(extra_manifest_ids))

if errors:
    for error in errors:
        print(f"screenshot surface map: {error}", file=sys.stderr)
    sys.exit(1)

print(f"screenshot surface map gate: {len(required)} screenshot surfaces mapped to manifest, capture guidance, and source entry points")
PY
