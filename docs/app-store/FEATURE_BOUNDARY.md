# RepoPress App Store Feature Boundary

This document is the release contract for the single RepoPress for macOS App Store edition, its visible UI, metadata, screenshots, privacy answers, review notes, and in-app purchase copy.

## Included in the App Store build

| Capability | Decision |
| --- | --- |
| User-configured remote or local AI providers, API-key input, chat, writing, metadata, image-text, and review actions | Included |
| Explicit per-endpoint AI data-sharing consent before any remote request | Required |
| AI API keys stored in macOS Keychain and requests sent directly to the configured provider | Required |
| AI requests as an app-defined Pro quota or paid unlock | Excluded; users buy and fund their own provider access |
| Browser capture through the embedded Safari Web Extension and Chrome Web Store extension | Included |
| Edge and Firefox browser extensions in this release | Deferred |
| Sandboxed listener bound only to `127.0.0.1:17843`, protected by a random expiring pairing token | Included |
| Native Messaging host, browser-directory manifests, helper installer, or unpacked extension assets in the app bundle | Excluded |
| Markdown editing, preview, metadata, content checks, local research, repository sync, and publishing | Included |
| User-selected files, repositories, and explicit HTTPS article import | Included |

The submitted app must start the loopback bridge in App Store builds and declare `com.apple.security.network.server`. It embeds and signs the Safari Web Extension in `Contents/PlugIns`, but must not bundle or install a Native Messaging helper. Chrome is independently installed and updated through the Chrome Web Store.

## AI data boundary

Before the first request to each remote provider endpoint, RepoPress displays:

- the provider and destination host;
- the possible data categories: prompt, article/site context, selected knowledge excerpts, conversation context, and user-selected images;
- that the request travels directly from the Mac to the provider;
- that the developer does not buy, proxy, or receive the API key or AI content.

Changing provider or endpoint requires separate consent. Loopback-hosted local models do not require third-party sharing consent. The user can revoke consent at any time.

## Browser data boundary

The browser extension has required access only to `http://127.0.0.1:17843/*` for app communication. Ordinary page access remains user initiated and optional or temporary where the browser supports it. The app validates the extension transport header, browser-extension origin where available, and pairing token. The listener is not exposed to LAN or Internet interfaces.

## 中文结论

RepoPress 只维护一个 Mac App Store 全功能版本。用户自备 AI 服务和 API Key，首次向每个远程地址发送内容前必须明确同意；AI 请求次数不作为 Pro 收费权益。当前浏览器采集只支持 Safari 和 Chrome：Safari Web Extension 随 App Store 应用内置，Chrome 扩展由 Chrome 网上应用店安装，两者都通过带随机令牌的 `127.0.0.1:17843` 本机回环接口连接沙盒应用。Edge 和 Firefox 暂缓。App Store 应用不安装 Native Messaging 宿主，不写浏览器目录，也不需要另做官网版。
