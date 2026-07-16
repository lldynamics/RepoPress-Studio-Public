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

- [ ] Clean Release archive produced from a clean checkout.
  Evidence:
- [ ] Distribution signing and hardened runtime verified on the archive.
  Evidence:
- [ ] Archive validated with App Store Connect or Transporter before upload.
  Evidence:

## Recording Commands

Use these only after the external action has actually been performed:

```sh
script/record_app_store_archive_validation_evidence.sh --dry-run
script/record_app_store_archive_validation_bundle.sh --dry-run

# Optional private env-template flow:
script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target app-store-archive
# Fill the copied file outside git, then:
source /private/tmp/personal-site-publisher-release-envs/app-store-archive-validation.env

script/record_app_store_archive_validation_bundle.sh \
  --clean-release-archive "Clean Release archive produced from a fresh checkout and reproducible release command." \
  --distribution-signing-runtime "Distribution signature verified and hardened runtime flag confirmed on the archive." \
  --transporter-validation "Archive validated successfully in Transporter before upload; no private account identifiers recorded." \
  --execute
```

Use the single-item recorder only when one external validation item is being
completed separately:

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
