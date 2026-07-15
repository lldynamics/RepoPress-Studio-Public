# Privacy And Support Copy Review

This copy is the redacted App Store privacy/support baseline for Personal Site Publishing Console. It must stay aligned with in-app quick hide, private-content masking, screenshot privacy gate, and the local repository workflow before release.

## Privacy Policy Copy

Personal Site Publishing Console works with repositories, drafts, images, publishing metadata, AI prompts, and deployment status that the user chooses to open or configure. Repository files and drafts stay on this Mac unless the user explicitly uses an online publishing, AI, deployment status, or StoreKit action.

The app includes a manual quick hide action for local screen protection. It immediately covers writing, AI, repository, deployment, release, and settings content until the user returns to the workbench. The app does not automatically hide content at launch or when it moves to the background.

Private-content masking hides private article titles, summaries, paths, and previews in lists, search, overview panels, and release-facing surfaces. Private articles are excluded from AI repair queues and public SEO/social preview image output.

The app must not include local paths, access tokens, authorization headers, private article body text, or personal account identifiers in App Store screenshots, support copy, release evidence, or public diagnostics. Screenshot and release-evidence gates are used before release to check for local paths, Token values, and authorization headers.

## Support Copy

For support requests, ask the user to describe the issue, app version, macOS version, selected site framework, and whether the issue involves local publishing, GitHub/GitLab API publishing, AI assistance, deployment status, StoreKit, quick hide, or private-content masking behavior.

Support replies should not request raw repository archives, local filesystem paths, access tokens, authorization headers, private article text, or personal account identifiers. If debugging evidence is needed, ask for redacted screenshots or release gate output with sensitive values removed.

If a user reports exposed private content, first ask them to enable private-content masking and use quick hide when leaving the screen. Then check whether the content is marked Private, whether the view is a list/search/overview/release surface, and whether any screenshot or copied diagnostic text contains local paths or tokens.

If a user reports publishing or AI issues, confirm whether they intentionally configured an external provider. Explain that online publishing, AI requests, deployment checks, and StoreKit may contact external services, while local editing and local repository checks are performed on this Mac.
