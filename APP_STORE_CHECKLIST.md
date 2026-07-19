# App Store Release Checklist

## Build And Signing

- [x] Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.
  Evidence: App Store 元数据门禁已通过。
- [ ] Confirm distribution signing team and hardened runtime on the archived app.
- [ ] Produce a clean Release archive from a clean checkout.
- [ ] Validate the archive with App Store Connect or Transporter before upload.

## Product Page And Review

- [x] Prepare Simplified Chinese and English product-page copy, reviewer notes, and an App Privacy response worksheet.
  Evidence: Local listing metadata gate verifies both localizations, field limits, reviewer notes, and privacy worksheet structure.
- [x] Generate localized privacy-policy and support pages, and configure their intended App Store URLs.
  Evidence: Chinese and English pages are published at `apps.chengjinfang.com` and the configured public URLs return HTTP 200.
- [x] Publish the privacy-policy and support pages, verify successful public responses, and fill the App Review contact name and phone.
  Evidence: Public URL checks passed and the private contact fields were verified in App Store Connect without copying them into the repository.
- [x] Add an easily accessible in-app privacy-policy and support link.
  Evidence: Settings > Privacy contains localized links to the owner-controlled privacy and support pages.
- [ ] Confirm the published App Privacy answers against the exact submitted binary.
- [x] Complete age rating, availability, pricing, tax, banking, and agreement fields in the owner account.
  Evidence: Live App Store Connect review on 2026-07-19; content rights remains a separate unchecked legal declaration below.
- [ ] Complete the content-rights declaration in the owner account.
- [ ] Create and submit the `personal.site.publisher.pro` in-app purchase with the first app version if it is not already approved.

## Localization

- [x] Cover app-target SwiftUI literals, literal localization calls, workspace navigation keys, and semantic display names in the localization catalog.
  Evidence: UI-scope localization gate has complete Simplified Chinese and English values for the keys it extracts.
- [x] Migrate App Store-critical `PublishingWorkbenchCore` presentation strings for preflight, image operations, deployment/webhooks, AI availability/usage/transcripts, and credential errors into locale-aware resources.
  Evidence: Core localization tests cover Simplified Chinese and English output for the migrated release-critical paths.
- [ ] Complete remaining Simplified Chinese and English copy coverage across all Core-generated presentation output.
- [x] Run the UI-scoped localization gate and review missing or stale strings within its declared extraction boundary.
  Evidence: UI-scope localization gate passed; this does not claim coverage of Core-generated presentation strings.

## Runtime UI

- [x] Run the app from `script/build_and_run.sh` on a clean macOS account or simulator-equivalent test user.
  Evidence: 已记录 clean macOS account 或等价测试用户运行证据。
- [x] Add and pass a repeatable UI runtime/accessibility gate.
- [x] Verify keyboard navigation, focus rings, VoiceOver labels, quick hide, and private-content masking behavior.
  Evidence: UI runtime/accessibility 门禁已通过。

## Screenshots

- [x] Add a repeatable screenshot capture or verification script.
- [x] Capture the nine manifest screens: writing, AI chat, sync/API publish, SEO/social preview, deployment status, maintenance, general drafts, Pro settings, and quick hide.
  Evidence: 已记录 App Store 截图外部验收证据。
- [x] Verify screenshots contain no private content, local tokens, or personal paths.
  Evidence: 截图隐私门禁已通过。

## Privacy And Monetization

- [x] Review privacy policy/support copy against in-app quick hide and private-content behavior.
  Evidence: 隐私/支持文案门禁已通过，已覆盖快速隐藏、私密内容遮挡和敏感信息 redaction 规则。
- [ ] Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.
- [x] Confirm free users see clear upgrade copy before blocked AI, online publish, or batch publish actions.
  Evidence: `MonetizationTests` and `script/check_storekit.sh` verify AI requests, GitHub/GitLab online publishing, and batch publishing expose quota, upgrade reason, and purchase/restore next steps.

## Publishing Workflow

- [ ] Verify GitHub direct commit and PR publishing with a least-privilege token.
- [ ] Verify GitLab direct commit and MR publishing with a least-privilege token.
- [ ] Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance.
