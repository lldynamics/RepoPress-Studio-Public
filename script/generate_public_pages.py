#!/usr/bin/env python3
"""Generate and verify public privacy and support HTML pages from canonical source definitions."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


DEFAULT_ROOT = Path(__file__).resolve().parent.parent


def generate_privacy_en() -> str:
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="RepoPress Studio Privacy Policy — website distribution, local data, custom AI, browser capture, software updates, and necessary server logs.">
  <meta name="robots" content="index,follow">
  <meta property="og:title" content="RepoPress Studio Privacy Policy">
  <meta property="og:description" content="Free and local-first; remote AI requests go directly to the provider selected by the user.">
  <meta property="og:type" content="website">
  <meta property="og:url" content="https://apps.chengjinfang.com/personal-site-publisher/privacy/en/">
  <meta property="og:site_name" content="Cheng Jinfang's Apps">
  <link rel="stylesheet" href="../../../css/style.css">
  <link rel="icon" href="../../../favicon.svg" type="image/svg+xml">
  <title>RepoPress Studio Privacy Policy</title>
</head>
<body>
  <main>
    <article>
      <p>
        <a href="../../index.html">Back to Support</a> |
        <a href="../../../index.html">All Apps</a> |
        <a href="../index.html">中文</a> |
        <a href="mailto:support@chengjinfang.com">Contact Support</a>
      </p>

      <h1>RepoPress Studio Privacy Policy</h1>
      <p>Effective and last updated: August 13, 2026</p>
      <p>This policy covers the free macOS edition downloaded from the official RepoPress Studio website and its embedded Safari Web Extension. The Mac app is Developer ID signed and notarized by Apple.</p>

      <section>
        <h2>1. Core Principles</h2>
        <p>RepoPress Studio is local-first. It has no advertising, behavioral tracking, or third-party analytics SDK, requires no RepoPress Studio account, and does not automatically send drafts, repository files, browser captures, or usage analytics to the developer's servers.</p>
        <p>The current website edition has no paid feature tier. RepoPress Studio does not sell AI service access, provider API keys, or usage bundles. Users select and fund any remote AI provider themselves.</p>
      </section>

      <section>
        <h2>2. Data Stored On The Device</h2>
        <ul>
          <li>Drafts, Markdown content, metadata, tags, categories, authors, summaries, private flags, and publishing status.</li>
          <li>EPUB, PDF, Markdown, TXT, HTML, or web content selected by the user, plus locally generated full-text and semantic indexes, annotations, citations, and revisions.</li>
          <li>Site and repository configuration, sync settings, publishing and maintenance records, deployment status, and limited history.</li>
          <li>AI provider configuration, remote-endpoint consent state, model preferences, and limited conversation state. By default, API keys are stored in macOS Keychain. Users can explicitly select a local Application Support configuration file restricted to the current macOS user (directory mode 0700 and file mode 0600), or session-only memory. An existing local-file configuration is never automatically copied into another storage mode, and local credential storage is excluded from backups. API keys are not included in workspace backups or diagnostics exports.</li>
          <li>Quick Hide, private-content masking, language preferences, backups, and browser-extension local settings.</li>
        </ul>
        <p>Ordinary app and extension data is not equivalent to end-to-end encrypted storage. Quick Hide and private-content masking reduce on-screen exposure; they are not password or Touch ID authentication, disk encryption, or end-to-end encryption.</p>
      </section>

      <section>
        <h2>3. BYOK, Custom Remote APIs, And Local Models</h2>
        <p>AI features support BYOK (Bring Your Own Key), a custom HTTPS endpoint, or a local model. Before the first request to each custom remote API destination, RepoPress Studio shows the full destination and possible data categories and requires explicit consent. The user can revoke consent for that destination.</p>
        <p>Depending on the action, a request can include the user's prompt, current article or site context, selected research excerpts, conversation context, and images added by the user. Requests go directly from this Mac to the selected provider; the developer does not proxy or receive API keys, prompts, requests, or responses. The provider processes data under its own terms and privacy policy.</p>
        <p><code>localhost</code>, <code>127.0.0.1</code>, and <code>::1</code> are local loopback destinations on this Mac and do not transfer AI content to a remote provider. The user separately controls any storage or logging performed by the local service.</p>
      </section>

      <section>
        <h2>4. Files, Repositories, And Browser Capture</h2>
        <p>The main app in the Developer ID website edition does not enable App Sandbox. Hardened Runtime and Apple notarization protect code integrity and distribution trust but do not provide App Sandbox isolation. The app workflow accesses repositories, research sources, images, and output locations that the user selects through system panels or explicitly configures, and uses security-scoped bookmarks to remember those choices. The embedded Safari Web Extension is a separate extension process and enables App Sandbox.</p>
        <p>The Safari Web Extension is embedded in the Mac app. The Chrome extension is installed and updated separately through the Chrome Web Store, while the Firefox extension is loaded independently from the repository manifest for local use. Each processes a page only after a user-initiated extension, menu, or shortcut action. Captures enter RepoPress Studio on the same Mac through the authenticated <code>127.0.0.1:17843</code> loopback connection and do not pass through the developer's servers.</p>
        <p>The app-side browser connection token is stored only in macOS Keychain. The Chrome and Firefox extensions store their pairing token, preferences, limited receipts, and a bounded offline queue in extension-local storage. The current Safari, Chrome, and Firefox channels do not install a Native Messaging helper.</p>
      </section>

      <section>
        <h2>5. Other Network Requests And Sparkle Updates</h2>
        <p>Local writing, research indexing, content checks, and image processing happen primarily on the device. User-initiated GitHub, GitLab, repository-remote, deployment-status, support-page, and privacy-page actions contact their corresponding services.</p>
        <p>The website edition uses Sparkle for software updates. When the user manually checks for updates, or allows Sparkle to check automatically, the app retrieves an HTTPS update feed and, after user confirmation where applicable, downloads a signed update archive from the configured update host. Update requests do not contain drafts, research, browser captures, credentials, AI prompts, or AI responses.</p>
        <p>The update host or its CDN may retain necessary server access logs containing an IP address, request time, requested path, response status, and user agent or app version. These logs are used only for update delivery, reliability, abuse prevention, and security, not advertising or cross-service tracking, and are retained according to the hosting provider's operational policy.</p>
      </section>

      <section>
        <h2>6. Data Received By The Developer</h2>
        <p>The app does not automatically send diagnostics. The developer receives an email address, message, and attachments only when the user sends a support request or shares reviewed diagnostics. This information is used for support, security, and necessary legal obligations, not advertising or sale.</p>
        <p>Do not send a complete repository, full token, authorization header, account password, local absolute path, private article body, or unreviewed diagnostic archive.</p>
      </section>

      <section>
        <h2>7. User Controls And Deletion</h2>
        <p>Users can delete local drafts, research, records, site profiles, backups, and credentials; revoke consent for a remote AI destination; clear the extension queue and disconnect pairing; or uninstall an extension. Deleting the app may not remove Application Support data, macOS Keychain items, extension-local data, backups, or files in user-selected repositories.</p>
        <p>Data sent to an external service or committed to a repository must be managed with that service or in that repository. The developer does not operate an account server that stores workspace content and cannot delete it from a device, repository, or third-party service on the user's behalf.</p>
      </section>

      <section>
        <h2>8. Contact And Changes</h2>
        <p>If the app, extension, or data handling changes materially, this page will be updated. Privacy and support contact: <a href="mailto:support@chengjinfang.com">support@chengjinfang.com</a>.</p>
      </section>
    </article>
  </main>
</body>
</html>
"""


def generate_privacy_zh() -> str:
    return """<!doctype html>
<html lang="zh-Hans">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="RepoPress Studio 隐私政策 — 说明官网直接分发、本地数据、自定义 AI、浏览器采集、软件更新和必要服务器日志。">
  <meta name="robots" content="index,follow">
  <meta property="og:title" content="RepoPress Studio 隐私政策">
  <meta property="og:description" content="免费、本地优先；远程 AI 请求由设备直连用户选择的服务商。">
  <meta property="og:type" content="website">
  <meta property="og:url" content="https://apps.chengjinfang.com/personal-site-publisher/privacy/">
  <meta property="og:site_name" content="程锦方的软件">
  <link rel="stylesheet" href="../../css/style.css">
  <link rel="icon" href="../../favicon.svg" type="image/svg+xml">
  <title>RepoPress Studio 隐私政策</title>
</head>
<body>
  <main>
    <article>
      <p>
        <a href="../index.html">返回技术支持</a> |
        <a href="../../index.html">返回软件列表</a> |
        <a href="en/index.html">English</a> |
        <a href="mailto:support@chengjinfang.com">联系支持</a>
      </p>

      <h1>RepoPress Studio 隐私政策</h1>
      <p>生效及最后更新：2026-08-13</p>
      <p>本政策适用于从 RepoPress Studio 官方网站下载的免费 macOS 版本及其内置 Safari Web Extension。Mac 应用使用 Developer ID 签名并经过 Apple 公证。</p>

      <section>
        <h2>1. 基本原则</h2>
        <p>RepoPress Studio 采用本地优先设计，不包含广告、行为跟踪或第三方分析 SDK，不要求注册 RepoPress Studio 账号，也不会自动把草稿、仓库文件、浏览器采集或使用分析发送到开发者服务器。</p>
        <p>当前官网版本不设置付费功能层级。应用不销售 AI 服务、服务商 API Key 或调用包；使用远程 AI 时，用户自行选择并承担服务商费用。</p>
      </section>

      <section>
        <h2>2. 保存在设备上的数据</h2>
        <ul>
          <li>草稿、Markdown 正文、元数据、标签、分类、作者、摘要、私密标记和发布状态。</li>
          <li>用户导入的 EPUB、PDF、Markdown、TXT、HTML 或网页内容，以及本机生成的全文和语义索引、标注、引用和版本记录。</li>
          <li>站点配置、仓库配置、同步设置、发布与维护记录、部署状态和有限历史。</li>
          <li>AI 服务商配置、远程端点授权状态、模型偏好和有限对话状态。API Key 默认保存在 macOS Keychain；用户也可以主动选择仅当前 macOS 用户可读写的本地 Application Support 配置文件（目录权限 0700、文件权限 0600）或仅本次会话。已有本地文件配置不会自动复制到其他存储模式，本地凭据存储不包含在备份中，API Key 不写入工作区备份或诊断导出。</li>
          <li>快速隐藏、私密内容遮挡、语言偏好、备份，以及浏览器扩展的本地设置。</li>
        </ul>
        <p>普通工作台与扩展本地数据不等同于端到端加密存储。快速隐藏和私密内容遮挡只减少屏幕暴露，不提供密码、Touch ID、磁盘加密或端到端加密。</p>
      </section>

      <section>
        <h2>3. BYOK、自定义远程 API 与本地模型</h2>
        <p>AI 功能支持 BYOK（用户自备 Key）、自定义 HTTPS 地址和本机模型。首次向每个自定义远程 API 地址发送请求前，应用会显示完整目标地址和可能发送的数据类别，并要求用户明确同意；用户可以撤销该地址的授权。</p>
        <p>根据用户选择的操作，请求可能包含提示词、当前文章或站点上下文、用户选择的资料片段、对话上下文和用户添加的图片。请求从本机直接发送到所选服务商，开发者不转发也不接收 API Key、提示词、请求或回复。服务商依照其条款与隐私政策处理数据。</p>
        <p><code>localhost</code>、<code>127.0.0.1</code> 和 <code>::1</code> 属于本机回环地址，不会把 AI 内容发送给远程服务商。本地服务本身是否记录数据，由用户单独管理。</p>
      </section>

      <section>
        <h2>4. 文件、仓库与浏览器采集</h2>
        <p>官网 Developer ID 版本的主应用未启用 App Sandbox。Hardened Runtime 和 Apple 公证用于代码完整性、运行时保护与分发信任，但不提供 App Sandbox 隔离。应用的工作流程访问用户通过系统面板选择或明确配置的仓库、资料、图片和输出位置，并通过安全范围书签记住这些选择。内置 Safari Web Extension 是独立扩展进程，启用 App Sandbox。</p>
        <p>Safari Web Extension 随 Mac 应用内置；Chrome 扩展由 Chrome 网上应用店单独安装和更新，Firefox 扩展从仓库清单独立加载供本机使用。三者只在用户主动点击扩展、菜单或快捷键后处理网页。采集通过带随机配对令牌的 <code>127.0.0.1:17843</code> 回环连接进入同一台 Mac，不经过开发者服务器。</p>
        <p>应用侧浏览器连接令牌只保存在 macOS Keychain。Chrome 和 Firefox 扩展的配对令牌、偏好、有限回执和受容量限制的离线队列保存在扩展本地存储中。当前 Safari、Chrome 和 Firefox 渠道不安装 Native Messaging 辅助程序。</p>
      </section>

      <section>
        <h2>5. 其他网络请求与 Sparkle 更新</h2>
        <p>本地写作、资料索引、内容检查和图片处理主要在设备上执行。用户主动触发的 GitHub、GitLab、仓库远端、部署状态、支持页面和隐私页面操作会访问对应服务。</p>
        <p>官网版本使用 Sparkle 提供软件更新。用户手动检查更新，或同意 Sparkle 自动检查后，应用会通过 HTTPS 读取更新源，并在适用时由用户确认后从配置的更新主机下载已签名更新包。更新请求不包含草稿、资料、浏览器采集、凭据、AI 提示词或 AI 回复。</p>
        <p>更新主机或其 CDN 可能保存必要的服务器访问日志，包括 IP 地址、请求时间、请求路径、响应状态、User-Agent 或应用版本。这些日志只用于更新交付、稳定性、防滥用和安全，不用于广告或跨服务跟踪，并按托管服务商的运维政策保留。</p>
      </section>

      <section>
        <h2>6. 开发者收到的数据</h2>
        <p>应用不会自动发送诊断。只有用户主动发送支持邮件或分享已经检查的诊断时，开发者才会收到邮件地址、消息和用户选择的附件。这些信息只用于支持、安全和必要法律义务，不用于广告或出售。</p>
        <p>请不要发送完整仓库、完整 Token、授权头、账号密码、本机绝对路径、私密文章正文或未经检查的诊断归档。</p>
      </section>

      <section>
        <h2>7. 用户控制与删除</h2>
        <p>用户可以删除本地草稿、资料、记录、站点配置、备份和凭据，撤销远程 AI 地址授权，清空扩展离线队列并断开配对，或卸载扩展。仅删除应用本体不一定同时删除 Application Support、macOS Keychain、扩展本地数据、备份或用户选择的仓库文件。</p>
        <p>已发送给外部服务或提交到仓库的数据，需要在对应服务或仓库中管理。开发者没有保存工作区内容的账号服务器，无法代替用户删除设备、仓库或第三方服务中的数据。</p>
      </section>

      <section>
        <h2>8. 联系与更新</h2>
        <p>如果应用、扩展或数据处理方式发生重要变化，本页面会同步更新。隐私与支持邮箱：<a href="mailto:support@chengjinfang.com">support@chengjinfang.com</a>。</p>
      </section>
    </article>
  </main>
</body>
</html>
"""


def generate_support_en() -> str:
    return """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="RepoPress Studio support — website installation, custom AI, browser capture, Git repository sync, privacy, and Sparkle updates.">
  <meta name="robots" content="index,follow">
  <meta property="og:title" content="RepoPress Studio · Support">
  <meta property="og:description" content="A free, local-first writing, research, and repository-sync workspace for authors of Git-based static sites.">
  <meta property="og:type" content="website">
  <meta property="og:url" content="https://apps.chengjinfang.com/personal-site-publisher/en/">
  <meta property="og:site_name" content="Cheng Jinfang's Apps">
  <link rel="stylesheet" href="../../css/style.css">
  <link rel="icon" href="../../favicon.svg" type="image/svg+xml">
  <title>RepoPress Studio · Support</title>
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "name": "RepoPress Studio",
    "operatingSystem": "macOS 14 or later",
    "applicationCategory": "DeveloperApplication",
    "description": "A free, local-first Markdown writing, research, and repository-sync workspace for authors of Git-based static sites.",
    "supportingData": "https://apps.chengjinfang.com/personal-site-publisher/privacy/en/"
  }
  </script>
</head>
<body>
  <main>
    <header>
      <h1>RepoPress Studio · Support</h1>
      <p>RepoPress Studio is a local-first workspace for authors of Git-based static sites. It combines Markdown writing, local research, content checks, browser capture, repository sync, and deployment status.</p>
      <p>
        <a href="../../index.html">All Apps</a> |
        <a href="../index.html">中文支持</a> |
        <a href="../privacy/index.html">隐私政策</a> |
        <a href="../privacy/en/index.html">Privacy Policy</a> |
        <a href="mailto:support@chengjinfang.com">Contact Support</a>
      </p>
    </header>

    <section>
      <h2>App Information</h2>
      <ul>
        <li>Platform: macOS 14 or later.</li>
        <li>Distribution: free from the official website; the Mac app is Developer ID signed and notarized by Apple.</li>
        <li>Account: no RepoPress Studio account and no paid feature tier.</li>
        <li>Privacy: no advertising, behavioral tracking, or third-party analytics SDK.</li>
        <li>Site generators: Zola, Hugo, Astro, Jekyll, and Hexo.</li>
      </ul>
    </section>

    <section>
      <h2>AI And Data Consent</h2>
      <p>AI features support BYOK (Bring Your Own Key), a custom HTTPS endpoint, or a local model. By default, API keys are stored in macOS Keychain. Users can explicitly select a local Application Support configuration file restricted to the current macOS user (directory mode 0700 and file mode 0600), or session-only memory. Users select and fund any remote provider account themselves; RepoPress Studio does not sell provider keys, access, or usage bundles.</p>
      <p>Before the first request to each custom remote API destination, the app shows the full destination and possible data categories and requires explicit consent. Requests go directly from this Mac to the selected provider; the developer does not proxy or receive keys, prompts, requests, or responses.</p>
      <p><code>localhost</code>, <code>127.0.0.1</code>, and <code>::1</code> are local loopback destinations and do not transfer AI content to a remote provider.</p>
    </section>

    <section>
      <h2>Main Features</h2>
      <ul>
        <li>Markdown editing, live preview, structured metadata, images, and general drafts.</li>
        <li>A local library for EPUB, PDF, Markdown, TXT, HTML, and web content selected by the user.</li>
        <li>Custom AI, AI chat, writing assistance, content review, and local-model connections.</li>
        <li>Content-health, SEO, social-preview, link, image, taxonomy, and maintenance checks.</li>
        <li>Local change and remote-difference review, followed by user-confirmed GitHub or GitLab sync and publishing.</li>
        <li>User-initiated browser capture through the Safari Web Extension, the Chrome Web Store extension, or an independently loaded Firefox extension.</li>
      </ul>
    </section>

    <section>
      <h2>Frequently Asked Questions</h2>
      <h3>Where do browser captures go?</h3>
      <p>The Safari extension is embedded in the Mac app, the Chrome extension is installed separately, and the Firefox extension is loaded temporarily from the repository manifest. Each captures only after a user action and writes to the local library through the authenticated <code>127.0.0.1:17843</code> loopback connection on the same Mac. Captures do not pass through the developer's servers. The app-side connection token stays only in macOS Keychain.</p>

      <h3>Why does the app request folder access?</h3>
      <p>The main app in the Developer ID website edition does not enable App Sandbox. Hardened Runtime and Apple notarization protect code integrity and distribution trust but do not provide App Sandbox isolation. The app workflow accesses repositories, research sources, and output locations that the user selects through system panels or explicitly configures, and uses security-scoped bookmarks to remember those choices. The embedded Safari Web Extension is a separate extension process and enables App Sandbox.</p>

      <h3>How do software updates work?</h3>
      <p>The website edition uses Sparkle. You can check manually or decide whether to allow automatic checks when Sparkle asks. The app reads an HTTPS update feed and downloads a signed update archive. Update requests do not contain drafts, research, browser captures, credentials, or AI content.</p>
      <p>The update host or CDN may retain necessary server access logs containing an IP address, request time, requested path, response status, and user agent or app version. These logs are used only for update delivery, reliability, abuse prevention, and security.</p>

      <h3>When does the app use the network?</h3>
      <p>User-initiated remote AI, GitHub, GitLab, repository-remote, deployment-status, browser-extension installation, software-update, and opened-page actions contact their corresponding services. The app does not automatically upload drafts or library content.</p>

      <h3>Does Quick Hide encrypt files?</h3>
      <p>No. Quick Hide and private-content masking reduce on-screen exposure. They are not password or Touch ID authentication, disk encryption, or end-to-end encryption.</p>
    </section>

    <section>
      <h2>Contact Support</h2>
      <p><a href="mailto:support@chengjinfang.com">support@chengjinfang.com</a></p>
      <p>Please include the macOS version, RepoPress Studio version, site generator, steps to reproduce, and a short problem description. Do not send a complete repository, API key, token, authorization header, local absolute path, private article body, or unreviewed diagnostic archive.</p>
    </section>

    <footer>
      <p>Last updated: August 13, 2026</p>
    </footer>
  </main>
</body>
</html>
"""


def generate_support_zh() -> str:
    return """<!doctype html>
<html lang="zh-Hans">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="RepoPress Studio 技术支持 — 官网安装、自定义 AI、浏览器采集、Git 仓库同步、隐私和 Sparkle 更新帮助。">
  <meta name="robots" content="index,follow">
  <meta property="og:title" content="RepoPress Studio · 技术支持">
  <meta property="og:description" content="面向 Git 静态站点作者的免费、本地优先写作、资料整理和仓库同步工作台。">
  <meta property="og:type" content="website">
  <meta property="og:url" content="https://apps.chengjinfang.com/personal-site-publisher/">
  <meta property="og:site_name" content="程锦方的软件">
  <link rel="stylesheet" href="../css/style.css">
  <link rel="icon" href="../favicon.svg" type="image/svg+xml">
  <title>RepoPress Studio · 技术支持</title>
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "name": "RepoPress Studio",
    "operatingSystem": "macOS 14 or later",
    "applicationCategory": "DeveloperApplication",
    "description": "面向 Git 驱动静态站点作者的免费、本地优先 Markdown 写作、资料整理与仓库同步工作台。",
    "supportingData": "https://apps.chengjinfang.com/personal-site-publisher/privacy/"
  }
  </script>
</head>
<body>
  <main>
    <header>
      <h1>RepoPress Studio · 技术支持</h1>
      <p>RepoPress Studio 是面向 Git 驱动静态站点作者的本地优先工作台，集中处理 Markdown 写作、本地资料整理、内容检查、浏览器网页采集、仓库同步和部署状态。</p>
      <p>
        <a href="../index.html">返回软件列表</a> |
        <a href="en/index.html">English Support</a> |
        <a href="privacy/index.html">隐私政策</a> |
        <a href="privacy/en/index.html">Privacy Policy</a> |
        <a href="mailto:support@chengjinfang.com">联系支持</a>
      </p>
    </header>

    <section>
      <h2>应用信息</h2>
      <ul>
        <li>平台：macOS 14 或更高版本。</li>
        <li>分发：从官方网站免费下载；Mac 应用使用 Developer ID 签名并经过 Apple 公证。</li>
        <li>账号：不要求注册 RepoPress Studio 账号，也没有付费功能层级。</li>
        <li>隐私：不包含广告、行为跟踪或第三方分析 SDK。</li>
        <li>站点框架：Zola、Hugo、Astro、Jekyll 和 Hexo。</li>
      </ul>
    </section>

    <section>
      <h2>AI 与数据授权</h2>
      <p>AI 功能支持 BYOK（用户自备 Key）、自定义 HTTPS 地址和本机模型。API Key 默认保存在 macOS Keychain；用户也可以主动选择仅当前 macOS 用户可读写的本地 Application Support 配置文件（目录权限 0700、文件权限 0600）或仅本次会话。使用远程服务时，用户自行选择并承担服务商费用；RepoPress Studio 不销售服务商 Key、访问权限或调用包。</p>
      <p>首次向每个自定义远程 API 地址发送请求前，应用会显示完整目标地址和可能发送的数据类别，并要求用户明确同意。请求由这台 Mac 直接发送给所选服务商，开发者不转发也不接收 Key、提示词、请求或回复。</p>
      <p><code>localhost</code>、<code>127.0.0.1</code> 和 <code>::1</code> 是本机回环地址，不会把 AI 内容发送给远程服务商。</p>
    </section>

    <section>
      <h2>主要功能</h2>
      <ul>
        <li>Markdown 编辑、实时预览、元数据、图片和通用草稿管理。</li>
        <li>导入 EPUB、PDF、Markdown、TXT、HTML 和网页内容并建立本地资料库。</li>
        <li>自定义 AI、AI 对话、写作辅助、内容检查和本机模型连接。</li>
        <li>内容健康、SEO、社交预览、链接、图片、分类和维护检查。</li>
        <li>查看本地变更和远端差异，并在用户确认后执行 GitHub 或 GitLab 同步与发布。</li>
        <li>通过 Safari Web Extension、Chrome 网上应用店扩展或独立加载的 Firefox 扩展采集用户主动选择的网页。</li>
      </ul>
    </section>

    <section>
      <h2>常见问题</h2>
      <h3>浏览器采集的数据去哪里？</h3>
      <p>Safari 扩展随 Mac 应用内置，Chrome 扩展单独安装，Firefox 扩展从仓库清单独立临时加载。三者只在用户主动触发后采集，并通过带随机配对令牌的 <code>127.0.0.1:17843</code> 回环连接写入同一台 Mac 上的资料库，不经过开发者服务器。应用侧连接令牌只保存在 macOS Keychain。</p>

      <h3>为什么需要文件夹权限？</h3>
      <p>官网 Developer ID 版本的主应用未启用 App Sandbox。Hardened Runtime 和 Apple 公证用于代码完整性、运行时保护与分发信任，但不提供 App Sandbox 隔离。应用的工作流程访问你通过系统面板选择或明确配置的仓库、资料和输出位置，并通过安全范围书签记住这些选择。内置 Safari Web Extension 是独立扩展进程，启用 App Sandbox。</p>

      <h3>如何更新软件？</h3>
      <p>官网版本使用 Sparkle。你可以手动检查更新，也可以在 Sparkle 提示时选择是否允许自动检查。应用通过 HTTPS 读取更新源并下载已签名更新包。更新请求不包含草稿、资料、浏览器采集、凭据或 AI 内容。</p>
      <p>更新主机或 CDN 可能保存必要的服务器访问日志，包括 IP 地址、请求时间、请求路径、响应状态、User-Agent 或应用版本，仅用于更新交付、稳定性、防滥用和安全。</p>

      <h3>什么时候会访问网络？</h3>
      <p>用户主动触发的远程 AI、GitHub、GitLab、仓库远端、部署状态、浏览器扩展安装、软件更新，以及主动打开的网页会访问对应服务。应用不会自动上传草稿或资料库内容。</p>

      <h3>快速隐藏是否等于文件加密？</h3>
      <p>不是。快速隐藏和私密内容遮挡只减少屏幕暴露，不提供密码、Touch ID、磁盘加密或端到端加密。</p>
    </section>

    <section>
      <h2>联系支持</h2>
      <p><a href="mailto:support@chengjinfang.com">support@chengjinfang.com</a></p>
      <p>请提供 macOS 版本、RepoPress Studio 版本、站点框架、操作步骤和简短问题描述。不要发送完整仓库、API Key、Token、授权头、本机绝对路径、私密文章正文或未经检查的诊断归档。</p>
    </section>

    <footer>
      <p>最后更新：2026-08-13</p>
    </footer>
  </main>
</body>
</html>
"""


PAGES_MAP = {
    "docs/public-pages/privacy-en.html": generate_privacy_en,
    "docs/public-pages/privacy-zh-Hans.html": generate_privacy_zh,
    "docs/public-pages/support-en.html": generate_support_en,
    "docs/public-pages/support-zh-Hans.html": generate_support_zh,
}


def sync_pages(root: Path, check_only: bool = False) -> bool:
    mismatches: list[str] = []
    for relative_path, generator in PAGES_MAP.items():
        target_file = root / relative_path
        expected_content = generator()
        if not target_file.is_file():
            mismatches.append(f"{relative_path} (file missing)")
            if not check_only:
                target_file.parent.mkdir(parents=True, exist_ok=True)
                target_file.write_text(expected_content, encoding="utf-8")
            continue

        current_content = target_file.read_text(encoding="utf-8")
        if current_content != expected_content:
            mismatches.append(relative_path)
            if not check_only:
                target_file.parent.mkdir(parents=True, exist_ok=True)
                target_file.write_text(expected_content, encoding="utf-8")

    if check_only and mismatches:
        print(
            f"generate_public_pages: out-of-sync public pages: {', '.join(mismatches)}",
            file=sys.stderr,
        )
        print(
            "Run 'python3 script/generate_public_pages.py --write' to synchronize public pages.",
            file=sys.stderr,
        )
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=DEFAULT_ROOT,
        help="Root directory of the project",
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--check",
        action="store_true",
        help="Check whether public pages are up-to-date without writing",
    )
    group.add_argument(
        "--write",
        action="store_true",
        default=True,
        help="Write generated public pages to disk (default)",
    )
    args = parser.parse_args()

    check_mode = args.check
    root = args.root.resolve()
    success = sync_pages(root, check_only=check_mode)
    if not success:
        return 1

    if check_mode:
        print(f"generate_public_pages: all {len(PAGES_MAP)} public pages are up to date.")
    else:
        print(f"generate_public_pages: successfully generated {len(PAGES_MAP)} public pages.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
