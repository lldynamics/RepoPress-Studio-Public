# RepoPress App Review Notes

RepoPress is a local-first developer tool for authors of Git-based static sites. It has one App Store edition, does not operate content, AI, or publishing services, and does not upload content automatically.

No RepoPress account is required. On first launch, the reviewer can create a general draft or select a local static-site repository through the standard file picker. No demo credentials are required for local features.

## Resubmission Notice & Review Guidance

This update addresses all feedback raised under Guidelines 5.2.5, 5, 3.1.1, 2.1(a), and 2.4.5(i):

1. **Brand & Trademark Compliance (Guideline 5.2.5)**:
   - App name is standardized as **RepoPress**. All metadata references to Apple trademarks (such as "Mac") have been removed or updated to compliant usage.

2. **Regional Deep Synthesis Regulation & AI Disclosure (Guideline 5)**:
   - All references to "OpenAI" or "ChatGPT" have been removed from app metadata, promotional copy, and UI strings.
   - RepoPress does not operate a hosted AI proxy, AI subscription service, or deep synthesis platform. Custom endpoints are user-configured and optional.

3. **In-App Purchase & Custom Endpoint Independence (Guideline 3.1.1 & Guideline 2.1(a))**:
   - Custom API keys are not required to unlock any app features.
   - **Built-in Demo / Preview Mode**: For testing AI-assisted writing tools (such as draft refinement, title generation, summary extraction, and SEO auditing), the app provides a built-in Offline Demo Engine when no custom API key is entered. The reviewer can test 100% of these tools immediately without entering any third-party credentials.

4. **Entitlements Optimization (Guideline 2.4.5(i))**:
   - The entitlement `com.apple.security.network.server` has been removed from `AppStore.entitlements`. The app strictly declares only `com.apple.security.network.client` for outbound connections and user-selected file sandbox access.

## Suggested Review Path

1. Open **Writing** and create or edit a Markdown draft.
2. Open **Library** and import a local Markdown, TXT, HTML, EPUB, or PDF file.
3. Test **AI Writing / Formatting Tools** directly (e.g., Quick Prompts, Polish Selection). Notice that with no API key configured, the app uses its **Built-in Demo Mode** to return structured demonstration results immediately.
4. Open **Settings > Custom Endpoints** (optional). A custom endpoint can be configured by the user. Explicit consent is required before any outbound network request is initiated.
5. Open **Settings > Privacy** to test Quick Hide and private-content masking.
6. Open **Settings > Pro** to review purchase and restore controls for **RepoPress Pro**.

## In-App Purchase

- Product name: **RepoPress Pro**
- Product identifier: `personal.site.publisher.pro`
- Type: non-consumable, one-time Pro unlock
- Pro gates online publishing and batch publishing operations. It does not gate provider-funded AI requests or external keys.
- Purchase and restore use StoreKit 2. The reviewer can test using an App Store Sandbox Account.

## Data And Privacy

Repository files, drafts, imported sources, browser captures, and generated indexes stay on the Mac unless the reviewer explicitly initiates an external operation. Credentials are stored in Keychain. The developer does not receive AI keys, AI request content, browser captures, repository data, or diagnostics unless the user separately chooses to send support material.

The app version and `personal.site.publisher.pro` in-app purchase must be included in the same review submission when the product is not already approved.
