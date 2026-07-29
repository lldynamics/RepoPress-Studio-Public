# Privacy And Support Copy Review

This copy is the redacted privacy/support baseline for the RepoPress Studio App Store edition. It must stay aligned with the App Store feature boundary, authenticated browser capture, in-app quick hide, private-content masking, screenshot privacy gate, and the local repository workflow before release.

## Privacy Policy Copy

RepoPress Studio works with repositories, drafts, images, publishing metadata, and deployment status that the user chooses to open or configure. It does not provide a public article catalog, user-submission platform, or hosted content service. Repository files and drafts stay on this Mac unless the user explicitly starts a repository API, deployment-status, or StoreKit action.

The app includes a manual quick hide action for local screen protection. It immediately covers writing, research, repository, deployment, release, and settings content until the user returns to the workbench. The app does not automatically hide content at launch or when it moves to the background.

Private-content masking hides private article titles, summaries, paths, and previews in lists, search, overview panels, and release-facing surfaces. Private articles are excluded from repair queues and public SEO/social preview image output.

The app must not include local paths, access tokens, authorization headers, private article body text, or personal account identifiers in App Store screenshots, support copy, release evidence, or public diagnostics. Screenshot and release-evidence gates are used before release to check for local paths, Token values, and authorization headers.

External AI assistance is optional and available to every user without RepoPress Pro. Users configure and fund their own local or remote provider account; RepoPress Studio does not meter AI requests, sell AI credits, sell provider access, or use an API key as an app license. Before the first request to each remote provider or custom endpoint, RepoPress Studio identifies the destination and possible data categories and requires explicit consent. Requests go directly to the selected provider; the developer does not proxy or receive the API key, prompts, requests, or responses. API keys are stored in macOS Keychain. RepoPress Pro unlocks online publishing and batch publishing only.

This App Store review build supports browser capture through the embedded Safari Web Extension. Captures reach RepoPress Studio only through an authenticated `127.0.0.1:17843` loopback connection on the same Mac. Chrome, Edge, and Firefox are not claimed as public features of this submission. The app does not install a Native Messaging helper or write a manifest into browser directories.

## Support Copy

For support requests, ask the user to describe the issue, app version, macOS version, selected site framework, and whether the issue involves AI provider configuration, endpoint consent, local publishing, GitHub/GitLab API publishing, deployment status, browser extension pairing, StoreKit, quick hide, or private-content masking behavior.

Support replies should not request raw repository archives, local filesystem paths, access tokens, authorization headers, private article text, or personal account identifiers. If debugging evidence is needed, ask for redacted screenshots or release gate output with sensitive values removed.

If a user reports exposed private content, first ask them to enable private-content masking and use quick hide when leaving the screen. Then check whether the content is marked Private, whether the view is a list/search/overview/release surface, and whether any screenshot or copied diagnostic text contains local paths or tokens.

If a user reports an online operation issue, confirm whether they intentionally configured the repository or deployment provider. Explain that online publishing, repository API requests, deployment checks, and StoreKit may contact external services, while local editing, research, and local repository checks are performed on this Mac.

If a user reports an AI issue, confirm the selected provider host, whether the endpoint requires an API key, whether Keychain reports a saved credential, and whether consent was granted for that exact endpoint. Never ask the user to send the API key. Explain that AI requests are processed under the selected provider's terms and privacy policy.
