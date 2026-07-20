# App Store Connect Metadata

`metadata.json` is the source-of-truth draft for Simplified Chinese and English product-page copy. `APP_REVIEW_NOTES.md` and `APP_PRIVACY_RESPONSES.md` are reviewer and privacy worksheets for the exact submitted build.

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

Do not replace these fields with guessed links or credentials. The primary App Store Connect category should match the bundle category: **Productivity** (`public.app-category.productivity`).
