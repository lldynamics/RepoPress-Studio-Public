# App Privacy Response Worksheet

Use this worksheet when answering App Store Connect privacy questions. Re-check it against the exact submitted binary and every configured third-party service before publishing the answers.

## Proposed App Store Connect Answer

For the App Store build, select **No, we do not collect data from this app** only if all of the following remain true at submission time:

- The developer does not receive repository content, drafts, imported documents, AI prompts, credentials, diagnostics, analytics, or account identifiers from the app.
- There is no developer-operated analytics, crash-reporting, telemetry, sync, proxy, or account backend in the submitted binary.
- Optional AI, GitHub, GitLab, deployment, and StoreKit requests are initiated by the user and sent directly to the selected service; the developer does not retain or access their payloads.
- No third-party SDK in the submitted binary collects data on behalf of the developer.

If any of these facts changes, do not reuse the proposed answer. Declare every collected data type, purpose, linkage, and tracking status in App Store Connect.

## User-Controlled External Transfers

| Feature | Destination | Data selected or configured by the user | Trigger |
| --- | --- | --- | --- |
| AI assistance | Selected AI provider | Prompt, relevant article or knowledge excerpts, optional image attachments, model settings | Explicit AI action |
| Repository API publishing | GitHub or GitLab | Repository identifiers, changed file content, commit/branch/PR or MR metadata, access token | Explicit publish action |
| Deployment status | Selected provider or custom HTTPS endpoint | Project/site identifier and configured credential where required | Explicit or configured status refresh |
| StoreKit | Apple | Product lookup, purchase, transaction, and restore information handled by StoreKit | Purchase or restore action |

These transfers must also be explained in the public privacy policy even when they do not constitute developer collection for the App Privacy label.

## Local Data

- Site profiles, draft metadata, privacy settings, and workbench state are stored in the app container.
- User-selected repositories are accessed through App Sandbox file selection and app-scoped security bookmarks.
- Provider credentials are stored in Keychain.
- Knowledge-library sources, chunks, and indexes are stored locally.
- Quick Hide covers the workspace on demand. Private-content masking redacts marked content in lists, search, overview, and release-facing surfaces.

## Submission Checks

- Confirm the public privacy policy URL is reachable without authentication and matches this worksheet.
- Confirm the privacy policy link is easily accessible inside the app before submission.
- Review the binary for newly added SDKs, telemetry, analytics, crash reporting, or developer-operated endpoints.
- Keep App Store Connect answers synchronized across every platform attached to the same app record.
