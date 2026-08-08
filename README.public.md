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
- Safari, Chrome, and Firefox companion extensions that communicate with the
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
- Full Xcode 16 or later for app-bundle and Safari extension workflows
- A Swift 6-compatible toolchain for SwiftPM-only builds and tests
- Python 3 and the macOS development tools for quality scripts
- Node.js and npm only for browser-extension tests and packaging

The package manifest uses Swift tools 6.0. The core target uses Swift 6 language
mode, while the macOS app and test targets currently retain Swift 5 language
mode under strict concurrency checks.

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

The app-bundle script also builds and embeds the Safari Web Extension; a plain
`swift build` does not produce that complete distributable bundle.

Run the fast development gate or all strict release profiles:

```bash
./script/check_release_gate.sh --quick
./script/check_release_gate.sh --profile all
```

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

- `Sources/PublishingWorkbenchCore/`: models, services, stores, and local data
  capabilities.
- `Sources/PersonalSitePublisherMac/`: the macOS app, SwiftUI views, and narrow
  AppKit adapters.
- `Sources/BrowserExtensionProtocolSupport/`: the generated app/extension
  protocol contract.
- `BrowserExtension/`: Safari, Chrome, and Firefox extension sources and channel
  configuration.
- `Tests/` and `UITests/`: unit, integration, UI, and accessibility coverage.
- `Packaging/` and `script/`: versioning, entitlements, quality gates, and
  release tooling.

See [`BrowserExtension/README.md`](BrowserExtension/README.md) for extension
installation and permission boundaries, and
[`docs/privacy-support-copy.md`](docs/privacy-support-copy.md) for the detailed
privacy and network model.

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
