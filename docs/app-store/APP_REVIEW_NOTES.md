# App Review Notes

Personal Site Publisher does not require an account for its core local workflow. On first launch, the reviewer can create a general draft or select a local static-site repository through the standard macOS file picker. No demo credentials are required.

## Suggested Review Path

1. Open **Writing** and create or edit a Markdown draft. The center editor and preview work locally.
2. Open **Library** to import a local Markdown, TXT, HTML, EPUB, or PDF file. Import is user initiated and the resulting knowledge index is stored locally.
3. Open **Images**, **Content Health**, and the article Inspector to review local image, metadata, SEO, and social-preview checks.
4. Open **Settings > Privacy** to test Quick Hide and private-content masking.
5. Open **Settings > Pro** to review the free quota, purchase, and restore controls.

## Optional External Integrations

- AI features are optional and require the user to configure their own provider and credential. The app does not include a shared AI account. Core writing and local checks remain available without AI.
- GitHub and GitLab API publishing is optional and requires the user to provide their own least-privilege access token. Local repository editing does not require a provider account.
- Deployment status checks run only after the user configures a deployment provider or an HTTPS status endpoint.
- The App Store build does not bundle or advertise the separately distributed browser helper. Its local server entitlement, resources, connection UI, and runtime startup are excluded from this build.

## In-App Purchase

- Product identifier: `personal.site.publisher.pro`
- Type: non-consumable Pro unlock.
- The free version shows the reason and purchase/restore path before a Pro-gated AI, online publishing, or batch publishing action is blocked.
- Purchase and restore use StoreKit. The reviewer can use an App Store sandbox account; no developer-provided account is needed.

## Data And Privacy

Repository files, drafts, imported sources, and generated indexes stay on the Mac unless the reviewer explicitly initiates an external AI, repository API, deployment-status, StoreKit purchase, or StoreKit restore action. Credentials are stored in Keychain and are not included in screenshots or diagnostics.

The submission must include the app version and the `personal.site.publisher.pro` in-app purchase in the same review submission when the product is not already approved.
