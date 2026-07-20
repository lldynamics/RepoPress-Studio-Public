# Chrome and Edge Submission Guide

This worksheet is for the exact browser-extension release being submitted. Re-check every answer when code, permissions, companion-app distribution, or data flow changes.

## Current Boundary

- Candidate packages: `dist/browser-extension/knowledge-capture-chrome-0.22.0.zip` and `dist/browser-extension/knowledge-capture-edge-0.22.0.zip`.
- Listing source of truth: `BrowserExtension/chromium-store-listing.json`.
- Chrome production ID `ginjcibepmeobaaadmfiagigcpcebmcc` is recorded in `BrowserExtension/browser-extension-protocol.json`; the Edge production ID is still pending.
- The browser helper is available only in the notarized direct-distribution macOS app. The Mac App Store build intentionally excludes the Native Messaging host and browser-connection UI.
- The public privacy-policy and support URLs are drafted in the listing JSON, but their live content and availability must be verified immediately before submission.

Do not press the final publish/review button until the production ID, matching Native Messaging allowlist, notarized companion build, public download URL, and reviewer instructions all refer to the same release.

## Safe First-Upload Sequence

1. Chrome draft creation is complete. Its store-assigned ID is `ginjcibepmeobaaadmfiagigcpcebmcc`; upload `knowledge-capture-chrome-0.22.0.zip` to that existing draft, but do not submit it for review yet.
2. Create a private draft item in Microsoft Partner Center and upload `knowledge-capture-edge-0.22.0.zip`. Do not submit it for review yet.
3. Copy the assigned Edge item ID into `edgeProductionID` in `BrowserExtension/browser-extension-protocol.json`.
4. Increment both extension manifests before regenerating source or packages. The immutable release ledger correctly rejects different source bytes under an already recorded version.
5. Run `python3 script/generate_browser_extension_protocol.py --write`, rebuild both packages, and run the browser-extension release gates.
6. Build and notarize the direct-distribution app with both production extension origins in its Native Messaging manifests. Verify install, repair, protocol handshake, capture, receipt, and “open in library” using each store-origin extension.
7. Publish the direct-distribution download and reviewer instructions at stable HTTPS URLs.
8. Complete store copy, privacy answers, assets, markets, and reviewer notes. Only then submit the final updated package for review.

Chrome and Edge use independent IDs. Never add the Chrome store origin to the Edge entry or reuse one store ID for both.

## Localized Listing Copy

### Simplified Chinese

- Name: `个人网站发布控制台 · 资料采集`
- Short description: `将网页正文、完整页面、选中文字或链接保存到 Mac 本机资料库。`
- Single purpose: `在用户确认后，将当前网页内容归档到个人网站发布控制台的本机资料库。`
- Description: `将当前网页的净化正文、完整页面、选中文字或链接保存到“个人网站发布控制台”的本机资料库。保存前可以预览并编辑标题、作者、标签、分类和 AI 检索权限；重复网页会要求明确选择处理方式。批量保存只临时授权用户所选标签页的网站，完成后撤销。扩展只通过 Native Messaging 与同一台 Mac 上的应用通信，不向开发者服务器上传网页内容。`

### English

- Name: `Personal Site Publisher · Knowledge Capture`
- Short description: `Save articles, full pages, selections, or links to your local Mac knowledge library.`
- Single purpose: `Archive the current page into Personal Site Publisher's local knowledge library after user confirmation.`
- Description: `Save a cleaned article, a complete page, selected text, or a link to the local knowledge library in Personal Site Publisher. Preview and edit the title, author, tags, category, and AI access before saving. Duplicate pages always require an explicit choice. Batch capture temporarily grants only the sites of the selected tabs and removes that access afterward. The extension communicates only with the companion Mac app through Native Messaging and does not upload page content to the developer's servers.`

URLs:

- Privacy policy: `https://apps.chengjinfang.com/personal-site-publisher/privacy/`
- Chinese support: `https://apps.chengjinfang.com/personal-site-publisher/`
- English support: `https://apps.chengjinfang.com/personal-site-publisher/en/`
- Companion-app download for reviewers: `[REQUIRED: notarized direct-distribution download URL]`

## Chrome Privacy Practices

Use the portal's exact wording at submission time. The conservative disclosure for this implementation is:

- Single purpose: use the text above.
- Remote code: **No**. All executable JavaScript is packaged with the extension.
- Website content: disclose that the extension reads user-selected page text, metadata, selections, and optional complete-page resources only after a user action, then sends them to the companion app on the same Mac.
- Browsing activity or web history: disclose URLs and titles if the form treats user-selected source URLs as this category. They are used for source identity, duplicate detection, receipts, and the local offline queue.
- Authentication information: the extension stores a short-lived local pairing token. It is not an online account credential and is sent only to the Native Messaging companion on the same Mac. Select this category if the portal asks about any credential handled by the extension, rather than only developer collection.
- Developer collection: the developer does not receive page content, URLs, the local pairing token, folders, or queue items. There is no developer analytics, advertising, sale, profiling, or remote content server in this extension.
- Data use: extension functionality only. No advertising, credit decisions, personalized ads, resale, or unrelated secondary purpose.
- Limited use certification: certify only after confirming the submitted package and public policy match these statements.

Do not answer “no data” merely because data stays on the user's Mac. The extension handles potentially private website content and an offline queue, and the disclosure should make that local-only boundary explicit.

## Permission Justifications

| Permission | Reviewer-facing explanation |
| --- | --- |
| `activeTab` | Reads the active page only after the user invokes the extension or a capture shortcut. |
| `alarms` | Schedules retries for user-confirmed items that could not yet reach the local companion app. |
| `contextMenus` | Adds explicit commands for saving an article, selected text, or a link. |
| `nativeMessaging` | Communicates with Personal Site Publisher on the same Mac; it is the only app transport. |
| `pageCapture` | Creates an MHTML archive only when the user selects Complete Page mode. |
| `scripting` | Extracts readable text, metadata, and the user's selection from an authorized page. |
| `storage` | Stores organization preferences, connection state, receipts, and the bounded offline queue locally. |
| `unlimitedStorage` | Supports user-requested complete-page archives; the extension still enforces a 10-item or 96 MB internal queue limit. |
| Optional `tabs` | Temporarily inspects selected tabs to construct a batch-capture confirmation list, then removes the permission. |
| Optional `http://*/*`, `https://*/*` | Declares runtime scope, while the extension requests only the exact origins selected for the current batch and removes them afterward. |

## Reviewer Notes

Paste and complete this block for each store:

> This extension requires the notarized direct-distribution build of Personal Site Publisher for macOS. It does not require an online account and does not connect to a developer backend. Download the companion build from: [REQUIRED URL]. Open the app, go to Library > Browser Capture, and choose Install/Repair for [Chrome or Edge]. Copy the displayed pairing token. In the browser, open an ordinary HTTP or HTTPS article, open the extension, paste the token, and select Connect. Choose Cleaned Article, Complete Page, Selected Text, or Link Only; select a local folder; generate the preview; review title, author, tags, and AI access; then confirm Save. The receipt shows the document ID-backed result, folder, size, archive type, and indexing state. Choose Open in Knowledge Library to reveal the saved item in the app. All test content remains on the review Mac. No credentials are supplied or required.

Also provide:

- Direct-distribution app version/build: `[REQUIRED]`
- macOS minimum version: `[REQUIRED: confirm from the notarized build]`
- Reviewer contact: `support@chengjinfang.com`
- If Native Messaging installation is blocked by managed-device policy, ask the reviewer to contact the address above; do not suggest disabling browser security.

## Asset Upload Map

For each locale, use files from the matching `docs/browser-extension-store-assets/<locale>/` directory.

- Chrome: `store-icon-128.png`, all three `screenshot-*.png`, `promo-small-440x280.png`, and optionally `promo-marquee-1400x560.png`.
- Edge: `edge-logo-300x300.png`, all three screenshots, the small promotional tile, and the marquee tile.
- The screenshots use only synthetic `example.com` content. Do not replace them with captures of a personal knowledge library.

## Final Local Verification

```bash
node script/generate_browser_extension_store_assets.mjs
node script/check_browser_extension_store_assets.mjs
python3 script/chromium_extension_release.py readiness
./script/check_browser_extension_release.sh
git diff --check
```

After publication, record each store's immutable publication time with `script/browser_extension_release_ledger.py publish`. A dashboard upload, saved draft, or review submission is not a publication result.

## Firefox Boundary

The existing self-distributed Firefox channel remains `unlisted`. For a public AMO listing, generate the separate immutable upload candidate with:

```bash
python3 script/firefox_extension_release.py lint-amo
python3 script/firefox_extension_release.py package-amo
```

Upload `dist/browser-extension/knowledge-capture-firefox-0.22.0-amo.xpi`. The AMO package intentionally omits the self-hosted `update_url` and declares `authenticationInfo`, `browsingActivity`, and `websiteContent` because the extension transfers the local pairing token, selected source URL/title, and selected page content to the companion app through Native Messaging. Mozilla must sign the uploaded package; the local AMO candidate is not installable as a permanent release build before that signature is applied.

The public listing still must not be submitted until the notarized companion-app download URL, exact app version/build, reviewer steps, support page, and privacy policy are live and mutually consistent.
