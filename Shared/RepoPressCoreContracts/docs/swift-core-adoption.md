# Swift Core adoption (M2)

`swift/` is the shared, deterministic Core package. It is Foundation-only and
must remain independent of AppKit, UIKit, SwiftUI, Security, Combine, SQLite,
PDFKit, Vision, NaturalLanguage, CryptoKit, process launching, and shared
network sessions. Platform code belongs in adapters owned by the iOS or macOS
application.

## Adopt through adapters

The iOS and macOS applications should translate their existing models into the
small contract inputs and translate Core outputs back into app-owned models.
The adapter owns UI state, user prompts, credentials, persistence, and platform
error presentation. Keep the following types and stores in their existing app
layers; do not replace them with shared Core types:

- `ArticleDraft` and `SiteProfile`
- Keychain or other credential stores
- SQLite/database schemas and migrations
- AppKit/UIKit/SwiftUI views and scene state

The shared package may define value types and deterministic transformations, but
it must not acquire those platform lifecycles or persistence responsibilities.

## Dependency sequence

1. **Local path first.** In each consumer, add a temporary Swift package path
   dependency pointing at the checked-out `swift/` directory. Build the consumer,
   run its adapter tests, and replay the relevant M1 fixtures. Keep the path
   dependency local to development; do not treat it as a release dependency.
2. **Commit and tag the shared package.** Once the Core change and its fixtures
   are reviewed, create the normal repository commit and version tag. This is a
   release boundary, not something the local-path phase can prove.
3. **Switch consumers to the tag.** Replace the local path with the approved
   repository URL and exact version tag. The URL and tag are supplied by the
   release owner; this document intentionally does not invent either one.
4. **Verify the minimum consumers.** After the tag exists, build the iOS and
   macOS adapters, run their focused tests and the shared `swift test`, and
   confirm the contract and boundary gates. Only then is the tagged dependency
   ready for formal consumer adoption.

## Verification commands

From the shared repository root:

```sh
python3 -m unittest discover -s tests -v
python3 scripts/validate_contracts.py
python3 scripts/check_fixture_hygiene.py
python3 scripts/check_swift_core_boundaries.py
swift test --package-path swift
```

The iOS package build is a separate consumer check on a macOS runner. It uses a
fresh SwiftPM scratch directory and does not claim signing, App Store, or
deployment evidence:

```sh
sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --package-path swift \
  --triple arm64-apple-ios17.0-simulator \
  --sdk "$sdk_path" \
  --scratch-path "$RUNNER_TEMP/RepoPressCoreIOSBuild"
```

## Rollback

If an adapter or fixture regression appears after adoption:

1. Stop the consumer rollout and record the failing adapter/fixture case.
2. Point each consumer back to the last known-good local checkout or exact
   shared tag; do not edit the contract fixtures to hide the regression.
3. Re-run the shared gates and the affected iOS/macOS adapter tests.
4. Revert the adapter change (or the dependency pointer) in a normal reviewable
   commit, preserving app-owned `ArticleDraft`, `SiteProfile`, Keychain, and
   database behavior.
5. Investigate and fix the Core/adapter pair on a new branch, then repeat the
   local-path verification before proposing a new commit and tag.

Formal version dependency and minimum-consumer verification are release claims;
they require an actual reviewed commit and tag and cannot be inferred from an
uncommitted local path or a source-only check.
