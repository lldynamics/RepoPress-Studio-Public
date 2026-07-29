# App Store Screenshot Manifest

Required Mac App Store screenshot set for the current product surface.

| ID | Target file | Screen | Purpose | Status |
| --- | --- | --- | --- | --- |
| `writing` | `writing.png` | Writing workspace | Markdown editing, preview, metadata, and contextual writing actions. | Captured 2880x1800 |
| `ai-chat` | `ai-chat.png` | Free BYOK AI writing assistant | Show the in-app AI assistant, safe demo conversation, article context, and user-supplied API-key boundary available without Pro. | Captured 2880x1800 |
| `knowledge-library` | `knowledge-library.png` | Local knowledge library | Show local import, search, cleaned reading content, source details, and annotations without browser-capture credentials. | Captured 2880x1800 |
| `sync-api-publish` | `sync-api-publish.png` | Sync workspace | GitHub/GitLab token check, remote conflict preview, direct API publish, and PR/MR flow. | Captured 2880x1800 |
| `seo-social-preview` | `seo-social-preview.png` | SEO/social preview | Search, Open Graph, Twitter card, cache state, and manual refresh. | Captured 2880x1800 |
| `deployment-status` | `deployment-status.png` | Deployment status | GitHub Pages/Actions, Netlify, Vercel, Cloudflare Pages, or custom endpoint validation. | Captured 2880x1800 |
| `maintenance` | `maintenance.png` | Site maintenance | Calendar, taxonomy governance, stale articles, links, and operation log. | Captured 2880x1800 |
| `general-drafts` | `general-drafts.png` | General drafts | Filter general drafts and manage article ownership from the writing list. | Captured 2880x1800 |
| `pro-settings` | `pro-settings.png` | Pro settings | Free quota, Pro unlock, purchase, and restore state. | Captured 2880x1800 |
| `privacy-lock` | `privacy-lock.png` | Quick hide | Manually hidden workbench and private-content masking. | Captured 2880x1800 |

The manifest is intentionally separate from generated images so the gate can track missing screenshots without hiding the remaining release work. Run `./script/check_app_store_screenshot_capture_readiness.sh` before capture to verify the screenshot surfaces, manifest, capture scripts, privacy gate, and next capture command are aligned. Use `./script/capture_app_screenshots.sh --auto-window --force-relaunch` for the guided demo capture set, then run `./script/check_release_gate.sh --profile app-store` before upload; the App Store profile requires each target file above to exist as a real App Store screenshot. Any captured image must be decodable, use an accepted 16:10 Mac App Store size (1280x800, 1440x900, 2560x1600, or 2880x1800), contain no alpha channel/transparency, and avoid the local paths or token-like secrets reported by `script/check_screenshot_privacy.sh`.
