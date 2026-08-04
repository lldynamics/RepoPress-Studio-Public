# RepoPress

RepoPress is a native macOS Markdown and repository workbench for authors who
publish Git-driven static sites.

## Highlights

- A three-column SwiftUI workspace for navigation, editing, and contextual
  knowledge suggestions.
- A native Markdown editor with live preview, image insertion, writing comfort
  controls, and local draft management.
- Repository-aware publishing for Zola, Hugo, Astro, Jekyll, and Hexo projects.
- Local knowledge library, RSS reading, SEO previews, image tools, and optional
  AI providers configured by the user.
- Safari, Chromium, and Firefox companion extensions that communicate with the
  app through a token-protected loopback interface.

RepoPress does not include service credentials. API keys configured in the app
are stored locally and must never be added to this repository.

## Requirements

- macOS 14 or later
- Xcode with the Swift 5.9 toolchain or later

## Build and test

```bash
swift build
swift test
```

To build and launch the macOS app bundle:

```bash
./script/build_and_run.sh
```

Browser-extension tests use the pinned Node dependencies:

```bash
npm ci --ignore-scripts
npm run install:browser-extension:e2e
npm run test:browser-extension:e2e
```

The real-browser test installs a local Playwright browser runtime and is not
part of the minimal Swift build.

## Privacy and security

Public examples must use synthetic data. Do not attach logs or screenshots that
contain local paths, private repository names, email addresses, credentials, or
article content. Report security issues through the process in `SECURITY.md`.

## License

RepoPress is open-source software under the Mozilla Public License 2.0 (`MPL-2.0`).
See `LICENSE` for the full terms. The RepoPress name, logo, and app icon are
governed by `TRADEMARKS.md`. Third-party dependencies retain their own
licenses; notices for bundled components are in `Packaging/ThirdPartyNotices`.
