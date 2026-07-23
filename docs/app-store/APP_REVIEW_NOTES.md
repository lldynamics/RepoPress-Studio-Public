# RepoPress App Review Notes

RepoPress is a local-first developer tool for authors of Git-based static sites. It has one Mac App Store edition, does not operate content, AI, or publishing services, and does not upload content automatically.

No RepoPress account is required. On first launch, the reviewer can create a general draft or select a local static-site repository through the standard macOS file picker. No demo credentials are required for local features.

## Suggested Review Path

1. Open **Writing** and create or edit a Markdown draft.
2. Open **Library** and import a local Markdown, TXT, HTML, EPUB, or PDF file.
3. Open **Settings > AI Writing**. A local model can be configured without third-party consent. For a remote provider, the app identifies the provider, destination, and possible data categories and blocks connection tests and AI requests until the reviewer explicitly selects **Agree and Enable This AI Service**.
4. Open **Library > Browser Capture**. The app starts a sandboxed listener bound only to `127.0.0.1:17843` and displays a random expiring pairing token.
5. Choose **Open Extension Settings**, enable **RepoPress · Knowledge Capture** in Safari Settings, open an ordinary HTTP or HTTPS article, pair with the displayed token, and save the page. Safari saves a self-contained HTML archive rather than MHTML.
6. Open **Settings > Privacy** to test Quick Hide and private-content masking.
7. Open **Settings > Pro** to review purchase and restore controls.

## Optional External Integrations

- AI is optional. Users obtain and pay for their own provider account and API key. Keys are stored in macOS Keychain. Requests travel directly from the Mac to the configured provider and do not pass through a developer-operated proxy. AI request count is not an app-defined paid entitlement.
- Before each remote endpoint is used, explicit consent is required. Changing the provider or endpoint requires separate consent. Local loopback endpoints are identified as local.
- This release supports Safari and Chrome only. The Safari Web Extension is embedded and signed inside this App Store app; Chrome is installed through the Chrome Web Store. Both send user-confirmed captures to the app only through `http://127.0.0.1:17843`, using an extension protocol header and random pairing token.
- The app declares `com.apple.security.network.server` only for that loopback listener. It does not listen on LAN or Internet addresses.
- The submitted app bundles only its signed Safari Web Extension `.appex`. It does not bundle a Native Messaging executable, Chrome ZIP, unpacked extension, installer, or browser-directory manifest, and it does not download executable code.
- GitHub and GitLab operations are optional and require the user's own least-privilege token. Deployment status checks run only after configuration.
- The Library may import one HTTPS article URL explicitly entered by the user. This is not general browsing and does not access history, cookies, tabs, or accounts.

## In-App Purchase

- Product name: **RepoPress Pro**
- Product identifier: `personal.site.publisher.pro`
- Type: non-consumable, one-time Pro unlock
- Pro gates online publishing and batch publishing. It does not gate provider-funded AI requests.
- Purchase and restore use StoreKit. The reviewer can use an App Store sandbox account.

## Data And Privacy

Repository files, drafts, imported sources, browser captures, and generated indexes stay on the Mac unless the reviewer explicitly initiates an external operation. Credentials are stored in Keychain. The developer does not receive AI keys, AI request content, browser captures, repository data, or diagnostics unless the user separately chooses to send support material.

The app version and `personal.site.publisher.pro` in-app purchase must be included in the same review submission when the product is not already approved.
