# Browser Extension Store Assets

This directory contains reproducible Chrome Web Store and Microsoft Edge Add-ons listing assets for the browser knowledge-capture extension. The images are submission candidates, not evidence that either store listing has been submitted or approved.

## Deliverables

Each `zh-CN/` and `en-US/` directory contains:

| File | Size | Intended use |
| --- | ---: | --- |
| `store-icon-128.png` | 128 x 128 | Chrome Web Store icon |
| `edge-logo-300x300.png` | 300 x 300 | Edge Add-ons logo |
| `screenshot-01-capture.png` | 1280 x 800 | Capture-mode screenshot |
| `screenshot-02-preview.png` | 1280 x 800 | Preview, organization, and AI-access screenshot |
| `screenshot-03-library.png` | 1280 x 800 | Local-library receipt and retrieval screenshot |
| `promo-small-440x280.png` | 440 x 280 | Small promotional tile |
| `promo-marquee-1400x560.png` | 1400 x 560 | Marquee or large promotional tile |

`source/<locale>/` contains the real extension popup states used in the compositions. These source captures are not store uploads. `asset-manifest.json` records the exact dimensions, SHA-256 digest, locale, and provenance of every deliverable.

All depicted pages, authors, folders, and URLs are synthetic. The generator uses `example.com` and never reads the user's browser history or knowledge-library database.

## Regenerate

From the repository root:

```bash
node script/generate_browser_extension_store_assets.mjs
node script/check_browser_extension_store_assets.mjs
```

The generator loads the unpacked Chromium extension in a real browser, captures the localized popup, and composes the final PNG files at exact store dimensions. The checker then rejects missing files, wrong dimensions, extension-version drift, or SHA-256 mismatches. Generation requires the repository's pinned `playwright-core` runtime and a usable Chromium executable. Set `CHROMIUM_EXECUTABLE_PATH` only when the bundled executable is unavailable.

Review every regenerated image before upload. Store copy remains sourced from `BrowserExtension/chromium-store-listing.json`; do not edit rendered images to introduce claims that are absent from the product.

## Submission Mapping

- Chrome Web Store: upload `store-icon-128.png`, the three `screenshot-*.png` files, `promo-small-440x280.png`, and optionally `promo-marquee-1400x560.png` for each localized listing.
- Edge Add-ons: upload `edge-logo-300x300.png`, the three screenshots, the small promotional tile, and the marquee tile for each localized listing.
- Do not upload anything under `source/` or `asset-manifest.json` to a store.

The operational sequence, review notes, privacy declarations, and remaining blockers are documented in `SUBMISSION_GUIDE.md`.
