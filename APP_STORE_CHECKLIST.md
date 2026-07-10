# App Store Release Checklist

## Build And Signing

- [x] Confirm bundle identifier, version, build number, minimum macOS, and sandbox entitlements.
  Evidence: App Store 元数据门禁已通过。
- [ ] Confirm distribution signing team and hardened runtime on the archived app.
- [ ] Produce a clean Release archive from a clean checkout.
- [ ] Validate the archive with App Store Connect or Transporter before upload.

## Localization

- [x] Move user-facing strings into a localization catalog or `Localizable.strings`.
  Evidence: 本地化资源门禁已通过。
- [x] Complete Simplified Chinese and English copy coverage.
  Evidence: 中英语言覆盖门禁已通过。
- [x] Run the localization gate and review missing or stale strings.
  Evidence: 本地化自动门禁已通过。

## Runtime UI

- [x] Run the app from `script/build_and_run.sh` on a clean macOS account or simulator-equivalent test user.
  Evidence: 已记录 clean macOS account 或等价测试用户运行证据。
- [x] Add and pass a repeatable UI runtime/accessibility gate.
- [x] Verify keyboard navigation, focus rings, VoiceOver labels, and privacy lock behavior.
  Evidence: UI runtime/accessibility 门禁已通过。

## Screenshots

- [x] Add a repeatable screenshot capture or verification script.
- [x] Capture writing, AI chat, sync/API publish, SEO/social preview, deployment status, maintenance, general drafts, Pro, privacy lock, and release gate screens.
  Evidence: 已记录 App Store 截图外部验收证据。
- [x] Verify screenshots contain no private content, local tokens, or personal paths.
  Evidence: 截图隐私门禁已通过。

## Privacy And Monetization

- [x] Review privacy policy/support copy against in-app privacy lock and private-content behavior.
  Evidence: 隐私/支持文案门禁已通过，已覆盖隐私锁、私密内容遮挡和敏感信息 redaction 规则。
- [ ] Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.
- [x] Confirm free users see clear upgrade copy before blocked AI, online publish, or batch publish actions.
  Evidence: `MonetizationTests`, `ReleaseQualityGateServiceTests`, and the `pro-boundary` release gate verify AI requests, GitHub/GitLab online publishing, and batch publishing all expose quota, upgrade reason, and purchase/restore next steps.

## Publishing Workflow

- [ ] Verify GitHub direct commit and PR publishing with a least-privilege token.
- [ ] Verify GitLab direct commit and MR publishing with a least-privilege token.
- [ ] Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance.
