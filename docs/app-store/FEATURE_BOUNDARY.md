# RepoPress Studio App Store Feature Boundary

This document is the release contract for the RepoPress Studio App Store edition, its visible UI, metadata, screenshots, privacy answers, review notes, and in-app purchase copy.

## Included in the App Store build

| Capability | Decision |
| --- | --- |
| User-configured remote or local AI providers, API-key input, AI chat, writing, metadata, image-text, and review actions | Included for free and Pro users |
| Explicit per-endpoint AI data-sharing consent before any remote request | Required |
| AI API keys stored in macOS Keychain and requests sent directly to the configured provider | Required |
| AI requests as an app-defined Pro quota or paid unlock | Excluded; RepoPress does not meter AI requests or sell provider access |
| Browser capture through the embedded Safari Web Extension | Included |
| Edge and Firefox browser extensions in this release | Deferred |
| Sandboxed listener bound only to `127.0.0.1:17843`, protected by a random expiring pairing token | Included |
| Native Messaging host, browser-directory manifests, helper installer, or unpacked extension assets in the app bundle | Excluded |
| Markdown editing, preview, metadata, content checks, local research, repository sync, and publishing | Included |
| User-selected files, repositories, and explicit HTTPS article import | Included |

Every distribution channel compiles `DistributionFeaturePolicy.allowsExternalAIProviders` as `true`. AI settings, provider and API-key controls, AI commands, AI inspectors, and AI-assisted actions are available without a RepoPress Pro entitlement. RepoPress Pro gates only online publishing and batch publishing.

The submitted app declares `com.apple.security.network.client` for user-initiated repository and deployment operations, `com.apple.security.network.server` only for the authenticated loopback browser-capture bridge, and user-selected file access. It embeds and signs the Safari Web Extension in `Contents/PlugIns`, but does not bundle or install a Native Messaging helper executable, Chrome package, or browser-directory manifest.

## AI data boundary

Before the first request to each remote provider endpoint, RepoPress Studio displays:

- the provider and destination host;
- the possible data categories: prompt, article/site context, selected knowledge excerpts, conversation context, and user-selected images;
- that the request travels directly from the Mac to the provider;
- that the developer does not buy, proxy, or receive the API key or AI content.

Changing the provider or endpoint requires separate consent. Loopback-hosted local models do not require third-party sharing consent. The user can revoke consent at any time. The app does not contain purchase links for AI providers.

## Browser data boundary

The browser extension has required access only to `http://127.0.0.1:17843/*` for app communication. Ordinary page access remains user initiated and optional or temporary where the browser supports it. The app validates the extension transport header, browser-extension origin where available, and pairing token. The listener is not exposed to LAN or Internet interfaces.

## 中文结论

RepoPress Studio 的 App Store 免费版和 Pro 版都可以配置用户自有的本地或远程 AI 服务和 API Key。应用不限制 AI 请求次数、不销售 AI 额度，也不把 API Key 当作许可证或 Pro 解锁机制；RepoPress Pro 只解锁线上发布和批量发布。远程 AI 请求首次发送前必须按地址明确同意，Key 保存在钥匙串，请求由 Mac 直连用户选择的服务商。当前送审版本的浏览器采集只声明随应用内置的 Safari Web Extension；它通过带随机令牌的 `127.0.0.1:17843` 本机回环接口连接沙盒应用。Chrome、Edge 和 Firefox 不属于本次 App Store 送审承诺。应用不安装 Native Messaging 宿主，不写浏览器目录。
