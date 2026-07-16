# App Store Screenshot Manifest

Required Mac App Store screenshot set for the current product surface.

| ID | Target file | Screen | Purpose | Status |
| --- | --- | --- | --- | --- |
| `writing` | `writing.png` | Writing workspace | Markdown editing, preview, metadata, and contextual writing actions. | Captured 1440x900 |
| `ai-chat` | `ai-chat.png` | AI assistant Inspector | Keep the article editor visible while showing conversation, context, quick prompts, and apply actions. | Captured 1440x900 |
| `sync-api-publish` | `sync-api-publish.png` | Sync workspace | GitHub/GitLab token check, remote conflict preview, direct API publish, and PR/MR flow. | Captured 1440x900 |
| `seo-social-preview` | `seo-social-preview.png` | SEO/social preview | Search, Open Graph, Twitter card, cache state, and manual refresh. | Captured 1440x900 |
| `deployment-status` | `deployment-status.png` | Deployment status | GitHub Pages/Actions, Netlify, Vercel, Cloudflare Pages, or custom endpoint validation. | Captured 1440x900 |
| `maintenance` | `maintenance.png` | Site maintenance | Calendar, taxonomy governance, stale articles, links, and operation log. | Captured 1440x900 |
| `general-drafts` | `general-drafts.png` | Cross-site copy | Copy an article from one publishing site to another. | Captured 1440x900 |
| `pro-settings` | `pro-settings.png` | Pro settings | Free quota, Pro unlock, purchase, and restore state. | Captured 1440x900 |
| `privacy-lock` | `privacy-lock.png` | Quick hide | Manually hidden workbench and private-content masking. | Captured 1440x900 |

The manifest is intentionally separate from generated images so the gate can track missing screenshots without hiding the remaining release work. Run `./script/check_app_store_screenshot_capture_readiness.sh` before capture to verify the screenshot surfaces, manifest, capture scripts, privacy gate, and next capture command are aligned. Use `./script/capture_app_screenshots.sh --auto-window --force-relaunch` for the guided demo capture set, then run `./script/check_release_gate.sh --strict` before upload; strict mode requires each target file above to exist as a real App Store screenshot. Any captured image must be decodable, use an accepted 16:10 Mac App Store size (1280x800, 1440x900, 2560x1600, or 2880x1800), contain no alpha channel/transparency, and avoid the local paths or token-like secrets reported by `script/check_screenshot_privacy.sh`.
