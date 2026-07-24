# Privacy And Support Copy Review

This copy is the redacted App Store privacy/support baseline for the single full-featured RepoPress edition. It must stay aligned with explicit AI consent, authenticated browser capture, in-app quick hide, private-content masking, screenshot privacy gate, and the local repository workflow before release.

## Privacy Policy Copy

RepoPress works with repositories, drafts, images, publishing metadata, and deployment status that the user chooses to open or configure. It does not provide a public article catalog, user-submission platform, or hosted content service. Repository files and drafts stay on this Mac unless the user explicitly starts a repository API, deployment-status, or StoreKit action.

The app includes a manual quick hide action for local screen protection. It immediately covers writing, research, repository, deployment, release, and settings content until the user returns to the workbench. The app does not automatically hide content at launch or when it moves to the background.

Private-content masking hides private article titles, summaries, paths, and previews in lists, search, overview panels, and release-facing surfaces. Private articles are excluded from repair queues and public SEO/social preview image output.

The app must not include local paths, access tokens, authorization headers, private article body text, or personal account identifiers in App Store screenshots, support copy, release evidence, or public diagnostics. Screenshot and release-evidence gates are used before release to check for local paths, Token values, and authorization headers.

External AI assistance is optional and uses an API key purchased and managed by the user. Before the first request to each remote AI provider or custom endpoint, RepoPress identifies the destination and possible data categories and requires explicit consent. Requests go directly to the selected provider; the developer does not proxy or receive the API key, request, or response. AI requests are not sold as an app-defined usage quota.

This release supports browser extensions for Safari and Chrome only. The Safari Web Extension is embedded in the App Store app, while Chrome is installed independently from the Chrome Web Store. Captures reach RepoPress only through an authenticated `127.0.0.1:17843` loopback connection on the same Mac. Edge and Firefox are deferred. The app does not install a Native Messaging helper or write a manifest into browser directories.

## Support Copy

For support requests, ask the user to describe the issue, app version, macOS version, selected site framework, and whether the issue involves local publishing, GitHub/GitLab API publishing, deployment status, user-configured AI, browser extension pairing, StoreKit, quick hide, or private-content masking behavior.

Support replies should not request raw repository archives, local filesystem paths, access tokens, authorization headers, private article text, or personal account identifiers. If debugging evidence is needed, ask for redacted screenshots or release gate output with sensitive values removed.

If a user reports exposed private content, first ask them to enable private-content masking and use quick hide when leaving the screen. Then check whether the content is marked Private, whether the view is a list/search/overview/release surface, and whether any screenshot or copied diagnostic text contains local paths or tokens.

If a user reports an online operation issue, confirm whether they intentionally configured the repository or deployment provider. Explain that online publishing, repository API requests, deployment checks, and StoreKit may contact external services, while local editing, research, and local repository checks are performed on this Mac.
