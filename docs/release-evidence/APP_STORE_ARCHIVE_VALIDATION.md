# App Store Archive Validation Evidence

This file records external App Store archive/upload validation. Keep account
names, local paths, tokens, Apple IDs, team IDs, and receipt IDs out of this
file. Use screenshots or private notes outside the repository for sensitive
proof, then summarize only the non-sensitive result here.
Prefer `script/record_app_store_archive_validation_evidence.sh` over manual
edits. It rejects local paths, token-like strings, Apple IDs, team identifiers,
emails, and receipt-like identifiers.
Create the signed app and installer from a clean committed checkout with
`script/package_app_store.sh`. Run `script/package_app_store.sh --dry-run` to
see the three required signing variables without exposing their values.
Use `script/prepare_external_verification_envs.sh` to copy
`docs/release-evidence/app-store-archive-validation.env.example` outside the
repository before filling real archive validation notes.

## Current Resubmission Target: 1.0 (9)

- [ ] Clean Release archive produced from a clean checkout.
  Evidence: Build 1.0 (9) has not yet been archived from a clean release-candidate checkout.
- [ ] Distribution signing and hardened runtime verified on the archive.
  Evidence: Build 1.0 (9) has not yet completed the local package gate or formal App Store distribution signing.
- [ ] Archive validated with App Store Connect or Transporter before upload.
  Evidence: Build 1.0 (9) has not yet been validated or uploaded.

## Historical Evidence: 1.0 (7) and 1.0 (8)

Build 1.0 (7) was produced from a disposable clean committed checkout. Its app,
embedded Safari Web Extension, installer signature, hardened runtime, and
artifact hashes passed the recorded distribution checks. Transporter delivered
it to App Store Connect on 2026-07-28 at 17:02, and it became available for
internal testing. Build 1.0 (8) passed the local App Store bundle gate with AI
excluded, but it was not formally archived or uploaded. Neither is the current
resubmission candidate because free user-configured AI now targets build 1.0 (9).

## Recording Commands

Use these only after the external action has actually been performed:

```sh
script/record_app_store_archive_validation_evidence.sh --dry-run

# Optional private env-template flow:
script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target app-store-archive
# Fill the copied file outside git, then:
source /private/tmp/personal-site-publisher-release-envs/app-store-archive-validation.env
script/run_external_verification_from_envs.sh \
  --env-dir /private/tmp/personal-site-publisher-release-envs \
  --target app-store-archive \
  --execute
```

The same recorder handles each archive validation item:

```sh
script/record_app_store_archive_validation_evidence.sh --dry-run

script/record_app_store_archive_validation_evidence.sh \
  --item clean-release-archive \
  --summary "Clean Release archive produced from a fresh checkout and reproducible release command." \
  --execute

script/record_app_store_archive_validation_evidence.sh \
  --item distribution-signing-runtime \
  --summary "Distribution signature verified and hardened runtime flag confirmed on the archive." \
  --execute

script/record_app_store_archive_validation_evidence.sh \
  --item transporter-validation \
  --summary "Archive validated successfully in Transporter before upload; no private account identifiers recorded." \
  --execute
```
