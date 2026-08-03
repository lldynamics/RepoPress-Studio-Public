# Safari、Chrome 与 Firefox 扩展提交说明

本说明对应 RepoPress Studio 唯一的 Mac App Store 应用版本。当前版本支持 Safari、Chrome 和 Firefox。
Chrome 扩展由 Chrome Web Store 独立安装；Safari Web Extension 作为签名 `.appex`
随 Mac App Store 应用安装；Firefox 扩展从仓库清单独立临时加载。Mac 应用不安装 Native Messaging 宿主、不写浏览器目录，
也不下载或执行扩展代码。

## 当前边界

- 当前扩展版本以 `BrowserExtension/manifest.json` 为准。
- Chrome 正式 ID：`ginjcibepmeobaaadmfiagigcpcebmcc`。
- Safari 子扩展 Bundle ID：`com.jinfang.PersonalSitePublisherMac.SafariExtension`。
- Firefox 支持本机临时加载和真实浏览器验收，但不随 App Store 应用嵌入，也不宣称已提交 AMO。
- Edge 暂缓，不生成新包、不提交商店，也不在本版本审核文案中声明支持。
- 扩展仅向 `http://127.0.0.1:17843/` 发送用户确认的采集内容。
- 每个请求都必须包含应用生成的随机连接令牌和 `X-RepoPress-Protocol` 协议头。
- 扩展不连接开发者后端；开发者不接收网页、URL、连接令牌、目录或离线队列。
- App Store 应用需要保持运行，才能接收浏览器采集。

## Safari App Store 打包

Safari 不使用单独的浏览器商店条目。源码同步、兼容检查和 `.appex` 构建：

```bash
./script/sync_safari_browser_extension.sh --check
./script/build_safari_web_extension.sh
```

App Store Connect 上传包必须同时满足：

1. 为 Safari 子扩展 Bundle ID 创建独立 App ID 和 Mac App Store provisioning profile。
2. 将该 profile 通过 `APP_STORE_SAFARI_EXTENSION_PROVISIONING_PROFILE` 提供给
   `script/package_app_store.sh`。
3. 先使用 Mac App Distribution 身份签名 `Contents/PlugIns/RepoPressSafariExtension.appex`，
   再签名外层应用；两者 Team ID 必须一致。
4. Safari 清单不使用 `pageCapture`。选择“完整网页”时保存自包含 HTML，
   Chrome 保存 MHTML。
5. 在 Safari 设置中启用扩展，并用普通 HTTP/HTTPS 页面完成配对、采集和回执验证。

公开支持页与隐私政策：

- 隐私政策：`https://apps.chengjinfang.com/personal-site-publisher/privacy/`
- 中文支持：`https://apps.chengjinfang.com/personal-site-publisher/`
- English support：`https://apps.chengjinfang.com/personal-site-publisher/en/`
- Mac 配套应用：Apple Mac App Store 中的 RepoPress Studio

最终提交前必须确认以上页面已部署，并且页面、扩展商店文案、应用审核说明与实际版本一致。

## Chrome 上架顺序

1. 向现有 Chrome 草稿上传本版本的
   `dist/browser-extension/knowledge-capture-chrome-<version>.zip`，暂不提交审核。
2. 如源文件发生变化，先递增扩展版本，再重新生成协议和 Chrome 商店包；
   不可变发布台账会拒绝同版本不同源码。
3. 运行浏览器扩展发布门禁，在 Chrome 中验证连接、采集、回执与
   “在资料库中打开”。
4. 填写商店文案、权限说明、隐私披露、截图和审核步骤，确认无误后才提交审核。

## 商店文案

### 简体中文

- 名称：`RepoPress Studio · 资料采集`
- 简短说明：`将网页正文、完整页面、选中文字或链接保存到 Mac 本机资料库。`
- 单一用途：`在用户确认后，将当前网页内容归档到 RepoPress Studio 的本机资料库。`
- 详细说明：`将当前网页的净化正文、完整页面、选中文字或链接直接保存到 RepoPress Studio 的本机资料库。你可以展开保存选项，选择采集模式、分类和本地语义检索设置；标题、作者和标签由网页自动提取。重复网页会要求明确选择处理方式。批量保存只临时授权用户所选标签页的网站，完成后撤销。扩展只通过 127.0.0.1 本机回环接口与同一台 Mac 上的应用通信，不向开发者服务器上传网页内容。`

### English

- Name: `RepoPress Studio · Knowledge Capture`
- Short description: `Save articles, full pages, selections, or links to your local Mac knowledge library.`
- Single purpose: `Archive the current page into RepoPress Studio's local knowledge library after user confirmation.`
- Description: `Save a cleaned article, complete page, text selection, or link directly to the local knowledge library in RepoPress Studio. Expand Save Options to choose the capture mode, folder, and local semantic-search setting; the title, author, and tags are extracted from the page. Duplicate pages always require an explicit choice. Batch capture temporarily grants only the sites of the selected tabs and removes that access afterward. The extension communicates only with the companion app through the 127.0.0.1 loopback interface and does not upload page content to the developer's servers.`

## 隐私披露

- 远程代码：否。所有可执行 JavaScript 都随扩展包提交。
- 网站内容：用户主动采集后，扩展会读取所选网页正文、元数据、选中文字及可选的完整页面资源，
  并只发送到同一台 Mac 的 RepoPress Studio。
- 浏览活动：若商店将用户所选来源 URL 和标题归入此类，应如实申报；用途是来源识别、重复检测、
  回执和本地离线队列。
- 身份验证信息：扩展保存一个本地随机连接令牌。它不是在线账户凭据，只发送到
  `127.0.0.1:17843`。
- 开发者收集：开发者不接收网页内容、URL、连接令牌、目录或队列，不做分析、广告、画像或出售。
- 数据用途：仅用于用户主动选择的本机资料库采集。

不要因为数据留在用户 Mac 上就简单选择“无数据处理”；扩展确实会处理可能包含私密信息的网页
内容，应明确说明“本机处理、开发者不接收”。

## 权限说明

| 权限 | 审核说明 |
| --- | --- |
| `activeTab` | 只在用户点击扩展、右键命令或快捷键后读取当前页面。 |
| `alarms` | 重试用户已确认但暂时无法写入本机应用的队列项目。 |
| `contextMenus` | 提供保存正文、选中文字或链接的右键命令。 |
| `pageCapture` | 只在用户选择“完整网页”时创建 MHTML。 |
| `scripting` | 从用户授权页面提取正文、元数据和选中文字。 |
| `storage` | 在浏览器本地保存偏好、连接状态、回执和有限离线队列。 |
| `unlimitedStorage` | 容纳用户明确保存的完整网页；内部仍限制为 10 项或 96 MB。 |
| `http://127.0.0.1:17843/*` | 只连接同一台 Mac 上的 RepoPress Studio；仍必须提供随机令牌，不访问局域网或互联网主机。 |
| 可选 `tabs` | 临时读取用户所选标签页以生成批量确认列表，完成后撤销。 |
| 可选 `http://*/*`、`https://*/*` | 仅向用户本次选定网站申请精确来源权限，批量任务结束后撤销。 |

扩展不申请 `nativeMessaging` 权限。

## 审核备注模板

> This extension works with the single Mac App Store edition of RepoPress Studio. It
> does not require an online account and does not connect to a developer
> backend. Install RepoPress Studio from the Mac App Store and keep it running. In
> RepoPress Studio, open Library > Browser Capture and copy the displayed connection
> token. Open an ordinary HTTP or HTTPS article in the browser, open the
> extension, paste the token, and select Connect. Expand Save Options when
> needed; choose Cleaned Article, Complete Page, Selected Text, or Link Only;
> select a local folder and the local semantic-search setting; then choose Save
> Current Page. The extension sends the confirmed content only to
> `127.0.0.1:17843` on the review Mac. Choose Open in
> Knowledge Library to reveal the saved item. No developer account or supplied
> credential is required.

同时填写：

- Mac App Store 应用版本与 build：`[提交前填写]`
- macOS 最低版本：`[按正式构建填写]`
- 审核联系人：`support@chengjinfang.com`
- 若本机端口被企业设备策略阻止，请联系上述地址；不要建议关闭浏览器或系统安全功能。

## 最终本机验证

```bash
node script/generate_browser_extension_store_assets.mjs
node script/check_browser_extension_store_assets.mjs
python3 script/chromium_extension_release.py check
./script/check_browser_extension_release.sh
git diff --check
```

正式发布后，用 `script/browser_extension_release_ledger.py publish` 记录 Chrome 的发布时间。
仅上传草稿或进入审核不等于已经发布。

## 暂缓渠道

Edge 适配源码和旧版发布记录暂时保留，但不属于当前发布范围。除非以后明确恢复，
不要创建 Edge 草稿或对应宣传材料。Firefox 的本机临时加载不等于 Firefox XPI/AMO 发布；
如需正式提交，必须另行建立签名、审核和不可变产物记录。
