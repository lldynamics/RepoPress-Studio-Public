# App Store Connect Metadata

`metadata.json` is the source-of-truth draft for Simplified Chinese and English product-page copy. `APP_REVIEW_NOTES.md` and `APP_PRIVACY_RESPONSES.md` are reviewer and privacy worksheets for the exact submitted build.

`public-pages/` contains the exact RepoPress Studio support and privacy page sources that must be copied to the public `apps.chengjinfang.com/personal-site-publisher/` site before review. These pages disclose free user-configured AI, Keychain storage, endpoint-specific consent, and direct provider transfers.

`FEATURE_BOUNDARY.md` is the App Store edition contract. The App Store build makes user-configured AI available without Pro, does not meter AI requests or sell provider access, and requires endpoint-specific consent before remote transfers. It includes browser capture through an authenticated loopback bridge and excludes Native Messaging helpers, unpacked extension assets, and browser-directory installers. Any change to this boundary must update code, review notes, privacy responses, StoreKit copy, extension listings, and screenshots together.

Run the local structural check while editing:

```bash
python3 script/check_app_store_listing_metadata.py
```

Run the submission check after the URL fields and review-contact status are filled:

```bash
python3 script/check_app_store_listing_metadata.py --strict
```

The strict check verifies the repository fields and that the configured URLs return successful public responses. It does not prove that the live pages contain the exact sources in `public-pages/`, or that private contact details are still current. Before selecting a build in App Store Connect:

- Deploy the exact four files in `public-pages/` to the configured privacy-policy and localized support URLs, then compare the live responses with these sources.
- Keep `configuredInAppStoreConnect` set to `true` only after the App Review contact name, email, and phone have been verified in the owner account. The repository intentionally does not duplicate the private name or phone number.

Do not replace these fields with guessed links or credentials. The primary App Store Connect category should match the bundle category: **Developer Tools** (`public.app-category.developer-tools`).
