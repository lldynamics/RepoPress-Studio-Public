# Contributing to RepoPress

Thank you for helping improve RepoPress. Keep contributions focused, reviewable,
and safe for a public repository.

## Before opening a pull request

1. Create a focused branch and avoid unrelated formatting or generated files.
2. Run `swift test` on macOS 14 or later.
3. For browser-extension changes, run `npm ci --ignore-scripts` followed by the
   relevant tests documented in `README.md`.
4. Confirm that no credential, personal data, private repository name, local
   home path, release artifact, or real user screenshot is included.
5. Describe the user impact and the checks you ran.

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
