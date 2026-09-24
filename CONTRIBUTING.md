# Contributing to RepoPress

Thank you for helping improve RepoPress. Keep contributions focused, reviewable,
and safe for a public repository.

## Before opening a pull request

1. Create a focused branch and avoid unrelated formatting or generated files.
2. Run `./script/check_release_gate.sh --quick` on macOS 14 or later; it includes
   the Swift behavior tests and shared development checks.
3. Confirm that no credential, personal data, private repository name, local
   home path, release artifact, or real user screenshot is included.
4. Describe the user impact and the checks you ran.

## Test framework strategy

New tests should use Swift Testing (`import Testing`, `@Test`, `#expect`, and
`#require`) by default. Existing XCTest coverage remains valid and should not
be mechanically rewritten; migrate an existing test file only when it is
already being changed for a behavior update or when XCTest-specific APIs are
not needed.

Use XCTest when the test depends on XCTest-only integration or UI lifecycle
behavior. Keep those cases isolated and avoid adding new XCTest suites for
pure models, services, projections, or persistence rules. Every new test must
still run through the package's normal `swift test` gate.

## Module dependencies

Module and dependency changes follow the [module boundary guide](docs/module-dependencies.md).
Update the manifest, executable policy, and regression fixtures together, then run
the existing module boundary gate and its tests. Review audit candidates before
removing a dependency; do not relax compatibility-import ceilings to pass a check.

## Script maintenance

Use the existing entrypoints in [`script/README.md`](script/README.md).
Product behavior belongs in `Sources/` with behavior tests in `Tests/`;
scripts orchestrate tools, check a single contract, or collect evidence.
Prefer extending an existing module or mode over adding another executable.

A permanent script needs a documented responsibility, inputs, outputs, failure
semantics, caller, validation, and retirement condition. Update the responsibility
index in the same change. Register quality checks in `script/release_checks.json`
instead of maintaining another check list in CI or another wrapper script.
Run `./script/check_release_gate.sh --tooling` when changing tooling.

Keep one-off experiments in ignored `.build/tmp/` and remove them when the task
ends. Move a reusable capability into its owning module before retaining it.
Remove retired tracked scripts and their obsolete callers together; Git retains
their history. Translation increments used during parallel editing must be
merged into the reviewed master dictionary and archived before the change is
finished, using the existing localization synchronizer.

## Documentation sources

Follow the [source map and documentation rules](docs/README.md). Change the
owning configuration or implementation first, then update its operational
guide. Keep README files as summaries that link to that guide, and query the
manifest or CLI help for check lists, thresholds, and modes. Configuration and
implementation disagreements require a fix, not a prose-only workaround.

Mark documents as current guides, proposals, or historical implementation and
validation records. Preserve the source, date, failures, and unverified scope of
historical evidence. Verify links in the development checkout and an exported
temporary snapshot when shared documentation changes; update source documents
instead of maintaining exported copies independently.

Do not commit `.env` files, signing material, provisioning profiles, database
files, diagnostic archives, or generated release packages. Use `example.com`,
`example.invalid`, and `/Users/example/` in fixtures.

Security reports belong in the private channel described in `SECURITY.md`, not
in public issues or pull requests.

## Contribution license

RepoPress is licensed under the Mozilla Public License 2.0 (`MPL-2.0`). By
submitting a contribution, you agree to license it under MPL-2.0 and represent
that it is your original work or that you have sufficient rights to submit it.
No separate contributor license agreement is currently required.

The project name and visual identity are governed separately by
`TRADEMARKS.md`.
