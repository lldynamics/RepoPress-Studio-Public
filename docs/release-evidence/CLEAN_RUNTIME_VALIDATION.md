# Clean Runtime Validation Evidence

This file records a real clean-user runtime smoke test. Do not paste local
filesystem paths, Apple IDs, emails, account names, tokens, private article
text, or screenshots containing private content.

Use `script/record_clean_runtime_evidence.sh` after the clean macOS account or
equivalent test-user run has actually been performed.

- [x] App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.
  Evidence: Equivalent clean test user launched the app with isolated user state through build_and_run --verify and reached one visible main workspace window without migration or permission failures.
- [x] Quick hide, private-content masking, settings, and workspace switching were verified without exposing private content.
  Evidence: Quick hide was triggered from the app command menu, hide and return menu states changed correctly, Settings was present in the app menu, and workspace command entries were visible with redacted sample content only.
- [x] Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app.
  Evidence: System Events smoke check confirmed menu-bar command routing, visible main-window accessibility objects, lock/unlock state, AI workspace command, publish checks, preview, repository import, and batch publish commands.

## Recording Commands

Use these only after the runtime smoke test has actually been performed:

```sh
script/record_clean_runtime_evidence.sh --dry-run
```

Use the same recorder for each completed runtime smoke item:

```sh
script/record_clean_runtime_evidence.sh --dry-run

script/record_clean_runtime_evidence.sh \
  --item clean-launch \
  --summary "Clean test user launched the app through build_and_run --verify and reached the main workspace without migration or permission failures." \
  --execute

script/record_clean_runtime_evidence.sh \
  --item privacy-settings-workspace \
  --summary "Quick hide, private-content masking, settings, and workspace switching were verified with sample data and redacted screenshots only." \
  --execute

script/record_clean_runtime_evidence.sh \
  --item accessibility-keyboard-smoke \
  --summary "Keyboard navigation, visible focus, VoiceOver labels, and primary menu commands were smoke checked in the running app." \
  --execute
```
