# RepoPress Studio

RepoPress Studio is a native macOS writing, knowledge, and repository workbench
for authors who publish Git-driven static sites.

This repository contains the macOS app. RepoPress also has a separately
maintained iOS app for iPhone and iPad that is available on the App Store. Each
app is designed for its platform and keeps its own UI, data model, entitlements,
and release lifecycle.

## Highlights

- A native three-column SwiftUI workspace with an AppKit-backed Markdown editor,
  live preview, image insertion, local drafts, and revision history.
- Repository-aware publishing for Zola, Hugo, Astro, Jekyll, and Hexo, including
  GitHub and GitLab imports, direct commits, and pull/merge request workflows.
- Preflight checks, front matter and path validation, publish diffs, SEO and
  social previews, deployment status, release history, and rollback tools.
- A local knowledge library, PDF and web imports, semantic search, RSS reading,
  image tools, and complete workspace backup and restore. Backups exclude
  Keychain credentials.
- Optional bring-your-own-key AI workflows for article-aware chat, editing,
  metadata suggestions, reviews, and release copy.

## Product and privacy boundary

RepoPress Studio is local-first, not fully offline. Files stay on the user's
device by default. Network access occurs only for actions the user initiates,
such as repository operations, deployment checks, AI requests, webpage imports,
or update checks.

RepoPress does not include service credentials. Repository, deployment, and AI
keys configured in the app are stored in macOS Keychain and must never be added
to this repository. The macOS codebase does not include in-app purchases or a
paid-entitlement system; that statement does not describe the separately
released iOS app.

## Requirements

- macOS 14 or later
- Full Xcode with a toolchain compatible with `Package.swift` for app-bundle workflows
- A Swift 6-compatible toolchain for SwiftPM-only builds and tests
- Python 3 and the macOS development tools for quality scripts
- Git, Hugo, Zola, Codex CLI, and Node.js/npm as required by the selected local
  publishing, preview, or ChatGPT workflow. RepoPress resolves these from the
  system, Homebrew, or `PATH` and does not embed them in the app bundle.

The authoritative deployment target, Swift tools version, language modes, and
dependencies are in [Package.swift](Package.swift). CI pins its Xcode environment
in the [installed workflow](.github/workflows). The
[documentation source map](docs/README.md) defines which configuration or
implementation owns each fact and how to resolve conflicting prose.

## Build and test

Build the SwiftPM products and run the test suite:

```bash
swift build
swift test
```

Package the complete macOS app without launching it, or build and launch it:

```bash
./script/build_and_run.sh --package-only
./script/build_and_run.sh
```

A plain `swift build` does not produce the complete distributable app bundle.

Run the fast development gate:

```bash
./script/check_release_gate.sh --quick
```

Use `./script/check_release_gate.sh --tooling` for tooling regressions and
`--list` / `--check ID` to discover or select individual checks. The
[script contracts and responsibility index](script/README.md) describe the
maintained entrypoints and when a temporary tool must be retired.
See the [module dependency guide](docs/module-dependencies.md) for module ownership,
the executable dependency policy, and cross-module audit reports.

The exported public snapshot uses its own [installed CI workflow](.github/workflows/quality.yml).
Full release profiles belong to the development checkout and require its
maintenance workflows, channel records, and release artifacts; a public source
snapshot is not a complete release environment.

Module build benchmarks, Release performance measurements, and manual trace
capture are documented in the [performance guide](docs/performance-profiling.md).
Developer ID prerequisites, modes, and artifact verification are maintained in
the [direct-release guide](docs/direct-release.md); version changes follow the
[versioning rules](docs/release-versioning.md). Check lists come from
[release_checks.json](script/release_checks.json); use the selected mode with
`--list` to inspect them without executing the checks.

Real UI launch, accessibility, signing, notarization, and online distribution
are separate release evidence; a successful unit-test run does not prove them.

## Project layout

- `Sources/PublishingMarkdownCore/`, `Sources/PublishingGitCore/`,
  `Sources/PublishingAICore/`, and `Sources/PublishingKnowledgeCore/`: focused
  Markdown, repository, AI, and knowledge library boundaries.
- `Sources/PublishingCoreSupport/` and `Sources/PublishingDomainContracts/`:
  shared infrastructure and small cross-domain value contracts.
- `Sources/PublishingWorkbenchCore/`: cross-domain orchestration, stores,
  compatibility adapters, and the temporary umbrella export surface.
- `Sources/PersonalSitePublisherMac/`: the macOS app, SwiftUI views, and narrow
  AppKit adapters.
- `Tests/` and `UITests/`: unit, integration, UI, and accessibility coverage.
- `Packaging/` and `script/`: versioning, entitlements, quality gates, and
  release tooling.

## Contributing and security

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request. Public
examples must use synthetic data. Do not attach logs or screenshots that contain
local paths, private repository names, email addresses, credentials, or article
content.

Report security issues through the private process in
[`SECURITY.md`](SECURITY.md), not in a public issue.

## License

RepoPress is open-source software under the Mozilla Public License 2.0 (`MPL-2.0`).
See [`LICENSE`](LICENSE) for the full terms. The RepoPress name, logo, and app
icon are governed by [`TRADEMARKS.md`](TRADEMARKS.md). Third-party dependencies
retain their own licenses; notices for bundled components are in
[`Packaging/ThirdPartyNotices`](Packaging/ThirdPartyNotices).
