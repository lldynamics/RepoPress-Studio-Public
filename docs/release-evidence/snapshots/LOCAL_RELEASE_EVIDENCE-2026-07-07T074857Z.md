# Local Release Evidence Bundle

> Archived snapshot. This file records the local gate state captured at the generated time below. It is historical evidence only, not proof that the current tree still passes.

- Generated at: 2026-07-07T07:48:57Z
- Scope: local automated evidence only
- Privacy: command output is redacted for local paths and token-like strings

## Current Strict-Release Gaps

- Screenshot images: 10/9 captured
- External verification evidence: 1/7 completed
- App Store archive validation: 3 unchecked item(s)
- Clean runtime validation: 0 unchecked item(s)
- App Store checklist: 7 unchecked item(s)
- Final strict command: `./script/check_release_gate.sh --strict`

This bundle does not replace the required live GitHub/GitLab, StoreKit sandbox, screenshot, or App Store upload validation evidence.

## Local Gate Outputs

### Localization Gate

- Command: `bash script/check_localization_gate.sh`
- Exit code: 0

```text
localization gate: zh-Hans and en resources are present with 17 matching Localizable keys and localized InfoPlist display names
```

### App Store Metadata Gate

- Command: `bash script/check_app_store_metadata.sh`
- Exit code: 0

```text
warning: <redacted-local-path> is not accessible or not writable, disabling user-level cache features.
warning: <redacted-local-path> is not accessible or not writable, disabling user-level cache features.
warning: <redacted-local-path> is not accessible or not writable, disabling user-level cache features.
warning: 'mac版编辑器': failed storing manifest for 'mac版编辑器' in cache: attempt to write a readonly database
app store metadata gate: bundle id, version 1.0 (1), icon, localized display names, minimum macOS, and sandbox entitlements verified
```

### App Store Archive Readiness Gate

- Command: `bash script/check_app_store_archive_readiness.sh`
- Exit code: 0

```text
app store archive readiness warning: app bundle is not verified with a distribution code signature
app store archive readiness warning: hardened runtime flag is not proven on the current app bundle
app store archive readiness warning: archive validation evidence still has 3 unchecked item(s)
app store archive readiness: local package, Info.plist, bundle id com.jinfang.PersonalSitePublisherMac, version 1.0 (1), and App Store entitlements verified
```

### UI Runtime Gate

- Command: `bash script/check_ui_runtime.sh`
- Exit code: 0

```text
warning: <redacted-local-path> is not accessible or not writable, disabling user-level cache features.
warning: <redacted-local-path> is not accessible or not writable, disabling user-level cache features.
warning: <redacted-local-path> is not accessible or not writable, disabling user-level cache features.
warning: 'mac版编辑器': failed storing manifest for 'mac版编辑器' in cache: attempt to write a readonly database
accessibility gate: keyboard shortcuts, focused command routing, privacy lock labels, status labels, and AI chat identifiers verified
ui runtime gate: bundle, plist, executable, core UI files, accessibility contract, and window verification contract verified
```

### Clean Runtime Evidence Gate

- Command: `bash script/check_clean_runtime_evidence.sh`
- Exit code: 0

```text
clean runtime evidence: template valid; completed 3/3 item(s)
```

### Privacy Support Copy Gate

- Command: `bash script/check_privacy_support_copy.sh`
- Exit code: 0

```text
privacy support copy gate: privacy/support copy, source behavior, and redaction rules verified
```

### StoreKit Static Gate

- Command: `bash script/check_storekit.sh`
- Exit code: 0

```text
storekit gate: product personal.site.publisher.pro is covered by 1 StoreKit config
```

### Screenshot Surface Map Gate

- Command: `bash script/check_screenshot_surface_map.sh`
- Exit code: 0

```text
screenshot surface map gate: 10 screenshot surfaces mapped to manifest, capture guidance, and source entry points
```

### Screenshot Manifest Gate

- Command: `bash script/check_screenshots.sh`
- Exit code: 0

```text
screenshot gate: manifest covers 10 required screens; images found: 10; validated minimum: 800x500
```

### External Verification Template Gate

- Command: `bash script/check_external_verification_evidence.sh`
- Exit code: 0

```text
external verification gate: evidence template covers 7 required items; completed: 1; missing completion: github-direct-publish github-review-publish gitlab-direct-publish gitlab-review-publish remote-conflict-deployment-rollback storekit-sandbox
```

### Screenshot Privacy Gate

- Command: `bash script/check_screenshot_privacy.sh`
- Exit code: 0

```text
screenshot privacy gate: audited 10 screenshot image(s)
```

## Evidence Files To Complete

- `docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md`
- `docs/release-evidence/APP_STORE_BUILD_METADATA.md`
- `script/record_app_store_build_metadata_evidence.sh`
- `script/prepare_external_verification_envs.sh`
- `script/check_external_verification_envs.sh`
- `script/run_external_verification_from_envs.sh`
- `script/verify_remote_publish_live.sh`
- `script/verify_remote_publish_live_matrix.sh`
- `docs/release-evidence/remote-publish-live.env.example`
- `script/record_external_verification_evidence.sh`
- `docs/release-evidence/remote-recovery.env.example`
- `docs/release-evidence/storekit-sandbox.env.example`
- `docs/release-evidence/app-store-screenshots.env.example`
- `script/sync_app_store_checklist.sh`
- `docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md`
- `docs/release-evidence/app-store-archive-validation.env.example`
- `docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md`
- `docs/app-store-screenshots/SCREENSHOT_MANIFEST.md`
- `APP_STORE_CHECKLIST.md`
