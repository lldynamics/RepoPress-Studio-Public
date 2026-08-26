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
- Chrome and Firefox companion extensions that communicate with the
  app through a token-protected `127.0.0.1` loopback interface.

## Product and privacy boundary

RepoPress Studio is local-first, not fully offline. Files stay on the user's
device by default. Network access occurs only for actions the user initiates,
such as repository operations, deployment checks, AI requests, browser capture,
or update checks.

RepoPress does not include service credentials. Repository, deployment, and AI
keys configured in the app are stored in macOS Keychain and must never be added
to this repository. The macOS codebase does not include in-app purchases or a
paid-entitlement system; that statement does not describe the separately
released iOS app.

## Requirements

- macOS 14 or later
- Full Xcode 16 or later for macOS app-bundle workflows
- A Swift 6-compatible toolchain for SwiftPM-only builds and tests
- Python 3 and the macOS development tools for quality scripts
- Git, Hugo, Zola, Codex CLI, and Node.js/npm as required by the selected local
  publishing, preview, or ChatGPT workflow. RepoPress resolves these from the
  system, Homebrew, or `PATH` and does not embed them in the app bundle.
- Browser-extension tests and packaging also require Node.js and npm

The package manifest uses Swift tools 6.0. Every declared SwiftPM target must
use Swift 6 language mode, and the module-boundary gate inventories the manifest
dynamically instead of relying on a stale target count. The strict build gate
inherits those manifest-declared modes while enforcing complete concurrency
checking and warnings-as-errors; a separate migration diagnostic explicitly
exercises Swift 6 mode as a regression check.

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

The macOS app contains no embedded browser extension; install and update the
Chrome and Firefox extensions separately. A plain `swift build` does not
produce the complete distributable app bundle.

Run the fast development gate or all strict release profiles:

```bash
./script/check_release_gate.sh --quick
./script/check_release_gate.sh --profile all
```

Inspect the per-module build plan, or collect opt-in cold, warm, and isolated
incremental build evidence:

```bash
python3 script/benchmark_swift_module_builds.py --plan
python3 script/benchmark_swift_module_builds.py \
  --configuration release \
  --repetitions 3 \
  --scenario cold \
  --scenario warm \
  --scenario incremental
```

Dependency resolution runs outside the measured samples and shares one isolated
download cache for the run. Each cold sample gets fresh compiler caches, while
its warm sample reuses only the matching cold state. The incremental probe edits
only a temporary source snapshot, never the working tree. Host wall-clock values
are trend evidence rather than a release threshold.

Browser-extension tests use pinned npm dependencies and install a local
Chromium runtime. The complete Firefox path also requires Firefox on the Mac.

```bash
npm ci --ignore-scripts
npm run install:browser-extension:e2e
npm run test:browser-extension:e2e
```

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
- `Sources/BrowserExtensionProtocolSupport/`: the generated app/extension
  protocol contract.
- `BrowserExtension/`: Chrome and Firefox extension sources and channel
  configuration.
- `Tests/` and `UITests/`: unit, integration, UI, and accessibility coverage.
- `Packaging/` and `script/`: versioning, entitlements, quality gates, and
  release tooling.

See [`BrowserExtension/README.md`](BrowserExtension/README.md) for extension
installation and permission boundaries.

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
