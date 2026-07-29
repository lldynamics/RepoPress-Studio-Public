# RepoPress Studio App Review Notes

Submission: build 9, prepared in response to the July 28, 2026 review.

RepoPress Studio is a local-first workspace for Git-based static sites. No RepoPress account is required.

## Changes for This Resubmission

1. **Guideline 2.3.8 — consistent name**
   The App Store name, installed name, bundle display name, app menu, and main-window title are all **RepoPress Studio**.

2. **Guideline 5.2.5 — Apple product terms**
   The product name contains no Apple product term. App Store Connect should remain **RepoPress Studio** in both localizations.

3. **Guidelines 2.1(a) and 3.1.1 — API key and external AI**
   AI and custom APIs are available to every user without RepoPress Pro. RepoPress does not meter AI requests, sell AI credits or provider access, or use an API key as a license or entitlement. Pro unlocks online publishing and batch publishing only.
   Users configure a local model or OpenAI-compatible HTTPS endpoint. Keys stay in macOS Keychain; requests travel directly to the selected provider. The developer does not proxy requests or receive keys, prompts, or responses. The app contains no provider-purchase link.
   Before the first request to each remote endpoint, the app shows the destination and possible data categories and requires explicit consent. Changing the endpoint requires separate consent.
   A private review-only provider credential must be supplied in App Store Connect so the reviewer can test remote AI without purchasing provider access.

4. **Guideline 2.1(a) — English localization**
   Packaged English resources were refreshed. Navigation, settings, dialogs, and release actions are presented in English.

5. **Guideline 4 — reopen the main window**
   After closing the main window, use **Window > Show RepoPress Studio** (⌘0).

## Suggested Review Path

1. Open **Writing** and create or edit a Markdown draft.
2. Open **Library** and import a local Markdown, TXT, HTML, EPUB, or PDF file.
3. Open **Settings > AI Writing**, enter the private review credential, accept the endpoint disclosure, and run **Test Connection**.
4. Return to **Writing**, open **AI Chat**, and send a prompt. This works without purchasing RepoPress Pro.
5. Open **Library > Browser Capture**. The embedded Safari Web Extension connects only to the authenticated loopback endpoint `127.0.0.1:17843`.
6. Open **Settings > Privacy** to test Quick Hide and private-content masking.
7. Open **Settings > Pro**; its benefits are online publishing and batch publishing only.
8. Close the main window, then use **Window > Show RepoPress Studio** to reopen it.

The app does not bundle a Native Messaging executable, Chrome ZIP, unpacked extension, installer, or browser-directory manifest.

## In-App Purchase

- Product: **RepoPress Pro**
- Identifier: `personal.site.publisher.pro`
- Type: non-consumable
- Benefits: online publishing and batch publishing
- AI, provider configuration, custom endpoints, and API-key entry require no purchase
- Purchase and restore: StoreKit 2

Please review build 9 and `personal.site.publisher.pro` in the same submission.

Local content stays on the device unless the reviewer starts an external action. AI requests go directly to the selected endpoint after consent. The developer receives no repository data, browser captures, AI credentials, AI content, or diagnostics.
