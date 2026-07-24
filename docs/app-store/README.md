# App Store Connect Metadata

`metadata.json` is the source-of-truth draft for Simplified Chinese and English product-page copy. `APP_REVIEW_NOTES.md` and `APP_PRIVACY_RESPONSES.md` are reviewer and privacy worksheets for the exact submitted build.

`FEATURE_BOUNDARY.md` is the single-edition contract. The App Store build includes user-configured AI after explicit per-endpoint consent and browser capture through an authenticated loopback bridge. It excludes Native Messaging helpers, unpacked extension assets, browser-directory installers, and app-defined AI request quotas. Any change to this boundary must update code, review notes, privacy responses, StoreKit copy, extension listings, and screenshots together.

Run the local structural check while editing:

```bash
python3 script/check_app_store_listing_metadata.py
```

Run the submission check after public URLs and review contact details are filled:

```bash
python3 script/check_app_store_listing_metadata.py --strict
```

The strict check remains blocked until public URLs are real and the private review contact has been confirmed in App Store Connect:

- The configured privacy-policy and localized support URLs are published and return successful public responses.
- `configuredInAppStoreConnect` is `true` after the App Review contact name and phone have been verified in the owner account. The repository intentionally does not duplicate those private values.

Do not replace these fields with guessed links or credentials. The primary App Store Connect category should match the bundle category: **Developer Tools** (`public.app-category.developer-tools`).
