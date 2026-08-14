# Privacy And Support Copy Review

This is the redacted privacy and support baseline for the free RepoPress Studio website edition. The app is downloaded from the official website as a Developer ID signed and notarized macOS app. It requires no RepoPress Studio account or paid feature tier. RepoPress Studio does not sell AI service access, provider keys, or usage bundles.

The main app in the Developer ID website edition does not enable App Sandbox. Hardened Runtime and Apple notarization protect code integrity and distribution trust but do not provide App Sandbox isolation. The app workflow accesses repositories, research sources, images, and output locations that the user selects through system panels or explicitly configures, and uses security-scoped bookmarks to remember those choices. The embedded Safari Web Extension is a separate extension process and enables App Sandbox.

## Privacy Policy Copy

RepoPress Studio works with repositories, drafts, images, publishing metadata, research material, browser captures, and deployment status that the user chooses to open or configure. The workspace is local-first and does not include advertising, behavioral tracking, or a third-party analytics SDK. Repository files and drafts stay on this Mac unless the user deliberately starts an external operation.

The app includes a manual Quick Hide action for local screen protection. It covers writing, research, repository, deployment, release, and settings content until the user returns to the workbench. Quick Hide only covers the interface; it does not provide Touch ID or password authentication, and it does not encrypt local data. Private-content masking hides private article titles, summaries, paths, and previews in lists, search, overview panels, and release-facing surfaces.

Public screenshots, support copy, release evidence, and shared diagnostics must not contain local paths, access tokens, authorization headers, private article body text, or personal account identifiers. Ask users to send only redacted screenshots and diagnostics they have reviewed.

### User-configured AI

AI assistance uses BYOK (Bring Your Own Key), a custom HTTPS endpoint, or a local loopback model. Users obtain and fund any remote provider account themselves. By default, API keys are stored in macOS Keychain. Users can explicitly select a local Application Support configuration file restricted to the current macOS user (directory mode 0700 and file mode 0600), or session-only memory. An existing local-file configuration is never automatically copied into another storage mode, and local credential storage is excluded from backups. API keys are not included in workspace backups or diagnostics exports.

Before the first request to each custom remote API destination, RepoPress Studio shows the destination URL and the possible data categories, then requires explicit consent. This destination consent can be revoked. After consent, every remote AI request is automatically redacted before sending and goes directly from this Mac to the selected provider without a per-request payload preview or confirmation. Depending on the action, a request can contain the user's prompt, current article or site context, selected research excerpts, conversation context, and images the user adds. The developer does not proxy or receive API keys, prompts, requests, or responses. The provider processes the data under its own terms and privacy policy.

Connections to `localhost`, `127.0.0.1`, and `::1` are local loopback connections on this Mac and are not transfers to a remote AI provider. A local service may still apply its own storage or logging behavior, which the user controls separately.

### Browser Capture

The Safari Web Extension is embedded in the Mac app. The Chrome extension is installed and updated separately through the Chrome Web Store, while the Firefox extension is loaded independently from the repository's manifest for local use. All three process a page only after a user-initiated capture action. Captures reach RepoPress Studio through the authenticated `127.0.0.1:17843` loopback connection on the same Mac and do not pass through the developer's servers.

The app-side browser connection token is stored only in macOS Keychain. The Chrome and Firefox extensions keep their pairing token, preferences, limited receipts, and a bounded offline queue in extension-local storage. RepoPress Studio does not install a Native Messaging helper for these Safari, Chrome, and Firefox channels.

### Other Network Requests And Updates

User-initiated GitHub, GitLab, repository-remote, deployment-status, support-page, and privacy-page actions contact the corresponding service. RepoPress Studio does not upload drafts or research automatically.

The website edition uses Sparkle for software updates. A request is made when the user manually checks for updates or allows Sparkle to perform automatic checks. Sparkle retrieves an HTTPS update feed and, after user confirmation where applicable, downloads the signed update archive from the configured update host. Update requests do not contain drafts, research, browser captures, credentials, AI prompts, or AI responses.

The update host or its CDN may keep necessary server access logs containing an IP address, request time, requested path, response status, and user agent or app version. These logs are used only for update delivery, reliability, abuse prevention, and security, not advertising or cross-service tracking, and are retained according to the hosting provider's operational policy.

### Developer Data And Deletion

The app does not automatically send diagnostics. The developer receives an email address, message, and attachments only when the user sends a support request or shares reviewed diagnostics. This information is used for support, security, and necessary legal obligations, not advertising or sale.

Users can delete local drafts, research, records, site profiles, backups, and credentials; clear the browser-extension queue and disconnect pairing; or uninstall an extension. Deleting the app may not remove Application Support data, macOS Keychain items, extension-local data, backups, or files in user-selected repositories. Data sent to a remote provider or committed to a repository must be managed with that provider or in that repository.

## Support Copy

For support requests, ask for the RepoPress Studio version, macOS version, selected site framework, steps to reproduce, and whether the issue involves a BYOK provider, custom remote API consent, local loopback model, local publishing, GitHub or GitLab sync, deployment status, Safari, Chrome, or Firefox capture, Sparkle updates, Quick Hide, or private-content masking.

Never ask the user to send an API key, access token, authorization header, account password, complete repository, local filesystem path, private article text, or unreviewed diagnostic archive. If evidence is needed, ask for a redacted screenshot or reviewed diagnostic output.

For update issues, ask whether the user started a manual check or enabled automatic checks, the app version and channel, the visible error, and whether the configured update host is reachable. Explain that the update host may receive the standard server access log fields listed above, but not workspace or AI content.
