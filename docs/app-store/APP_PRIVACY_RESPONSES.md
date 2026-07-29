# App Privacy Response Worksheet

Use this worksheet when answering App Store Connect privacy questions. Re-check it against the exact submitted binary and every configured third-party service before publishing the answers.

## Proposed App Store Connect Answer

For the App Store build, select **No, we do not collect data from this app** only if all of the following remain true at submission time:

- The developer does not receive repository content, drafts, imported documents, credentials, diagnostics, analytics, or account identifiers from the app.
- There is no developer-operated analytics, crash-reporting, telemetry, sync, proxy, or account backend in the submitted binary.
- Optional GitHub, GitLab, deployment, and StoreKit requests are initiated by the user and sent directly to the selected service; the developer does not retain or access their payloads.
- Optional AI requests are sent directly from the Mac to the provider endpoint selected by the user, only after endpoint-specific explicit consent; the developer does not proxy or receive API keys, prompts, requests, or responses.
- Browser captures travel only between the embedded Safari Web Extension and the app through the authenticated `127.0.0.1:17843` loopback endpoint; the developer does not receive them.
- No third-party SDK in the submitted binary collects data on behalf of the developer.

If any of these facts changes, do not reuse the proposed answer. Declare every collected data type, purpose, linkage, and tracking status in App Store Connect.

## User-Controlled External Transfers

| Feature | Destination | Data selected or configured by the user | Trigger |
| --- | --- | --- | --- |
| Repository API publishing | GitHub or GitLab | Repository identifiers, changed file content, commit/branch/PR or MR metadata, access token | Explicit publish action |
| Deployment status | Selected provider or custom HTTPS endpoint | Project/site identifier and configured credential where required | Explicit or configured status refresh |
| StoreKit | Apple | Product lookup, purchase, transaction, and restore information handled by StoreKit | Purchase or restore action |
| User-configured AI | Local loopback model or OpenAI-compatible HTTPS endpoint selected by the user | Prompt; selected article/site context; selected knowledge excerpts; conversation context; user-selected images; user-owned API key where required | Explicit consent for that endpoint, followed by a user-initiated AI action |
| Browser capture | RepoPress Studio on the same device through `127.0.0.1:17843` | User-confirmed page URL, metadata, selected or extracted content, optional archive, and folder choice | Extension action, context menu, shortcut, or confirmed batch task |

These transfers must also be explained in the public privacy policy even when they do not constitute developer collection for the App Privacy label.

## Local Data

- Site profiles, draft metadata, privacy settings, and workbench state are stored in the app container.
- User-selected repositories are accessed through App Sandbox file selection and app-scoped security bookmarks.
- Repository, deployment, and user-configured AI credentials are stored in Keychain.
- Per-endpoint AI consent choices are stored locally. AI requests are not metered as an app-defined free quota or Pro benefit.
- Knowledge-library sources, chunks, and indexes are stored locally.
- Each browser extension stores preferences, limited receipts, an expiring pairing token, and a bounded offline queue in browser-local extension storage.
- Quick Hide covers the workspace on demand. Private-content masking redacts marked content in lists, search, overview, and release-facing surfaces.

## Submission Checks

- Confirm the public privacy policy URL is reachable without authentication and matches this worksheet.
- Confirm the privacy policy link is easily accessible inside the app before submission.
- Review the binary for newly added SDKs, telemetry, analytics, crash reporting, or developer-operated endpoints.
- Verify provider configuration, API-key entry, AI chat, and AI writing actions are available before purchasing Pro.
- Verify remote AI remains blocked until explicit consent is granted and that changing the endpoint requires separate consent.
- Verify the browser listener is bound only to `127.0.0.1`, requires the protocol header and pairing token, and is absent from LAN interfaces.
- Verify the embedded Safari `.appex` has the exact child bundle identifier, App Sandbox entitlement, distribution signature, and its own matching provisioning profile.
- Keep App Store Connect answers synchronized across every platform attached to the same app record.
