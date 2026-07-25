# RepoPress App Review Notes

RepoPress is a local-first developer tool for authors of Git-based static sites. It has one App Store edition, does not operate content, AI, or publishing services, and does not upload content automatically.

No RepoPress account is required. On first launch, the reviewer can create a general draft or select a local static-site repository through the standard file picker. No demo credentials are required for local features.

## Response to the July 25 Review

1. **Guideline 5.2.5**: The App Store name is now **RepoPress**. “for Mac” has been removed from every localization.
2. **Guideline 5**: China mainland is not selected as an available storefront for this version.
3. **Guideline 3.1.1 and 2.1(a)**: Remote AI is optional and is not a RepoPress Pro entitlement. RepoPress does not sell AI credits or provider access, include purchase links, or operate an AI proxy. An API key authenticates the user's independent provider account and is sent directly from the Mac to the configured endpoint. Local loopback endpoints can be used without a third-party API key. RepoPress Pro only unlocks online publishing and batch publishing.
4. **Guideline 2.4.5(i)**: `com.apple.security.network.server` is required only for user-initiated Safari and Chrome browser capture. The app creates an `NWListener` whose required local endpoint is `127.0.0.1:17843`; it does not listen on LAN or Internet interfaces. Every request requires the browser-extension protocol header and a random expiring pairing token.

Before content is first sent to each remote endpoint, explicit consent is required. Changing the endpoint requires separate consent. Credentials are stored in macOS Keychain. The submitted app does not bundle a Native Messaging executable, Chrome ZIP, unpacked extension, installer, or browser-directory manifest.

## Suggested Review Path

1. Open **Writing** and create or edit a Markdown draft.
2. Open **Library** and import a local Markdown, TXT, HTML, EPUB, or PDF file.
3. Open **Settings > AI Writing** to configure an optional local or remote compatible endpoint. The consent sheet blocks connection tests and AI requests until accepted.
4. Open **Library > Browser Capture**. The app displays the loopback endpoint and pairing token. Enable the embedded Safari Web Extension, pair it, then capture an HTTP or HTTPS article.
5. Open **Settings > Privacy** to test Quick Hide and private-content masking.
6. Open **Settings > Pro** to review purchase and restore controls.

## In-App Purchase

- Product name: **RepoPress Pro**
- Product identifier: `personal.site.publisher.pro`
- Type: non-consumable, one-time Pro unlock
- Pro gates online publishing and batch publishing. It does not gate AI requests or external keys.
- Purchase and restore use StoreKit 2.

## Data And Privacy

Repository files, drafts, imported sources, browser captures, and generated indexes stay on the Mac unless the reviewer explicitly initiates an external operation. Credentials are stored in Keychain. The developer does not receive AI keys, AI request content, browser captures, repository data, or diagnostics unless the user separately chooses to send support material.

The app version and `personal.site.publisher.pro` in-app purchase must be included in the same review submission when the product is not already approved.
