# 保存到资料库浏览器扩展

这是“个人网站发布控制台”的本机网页采集扩展。它会提取当前网页的正文、标题、作者、
摘要、标签和语言，并可同时保存一份 MHTML 页面归档。Firefox、Chrome 和 Edge 都通过
应用安装的 Native Messaging 宿主写入本机资料库，不向扩展开放 localhost 主机权限，
也不经过云端服务。

## 开发版安装

1. 打开“个人网站发布控制台”，进入资料库，点击工具栏中的拼图按钮。
2. 在连接窗口点击“在 Finder 中显示扩展”，并复制连接令牌。
3. 按浏览器选择安装方式：
   - Chrome / Edge：打开扩展管理页，启用“开发者模式”，点击“加载已解压的扩展”。
   - Firefox：打开 `about:debugging#/runtime/this-firefox`，点击“临时载入附加组件”。
4. Chrome / Edge 选择 `BrowserExtension` 文件夹；Firefox 选择
   `BrowserExtension/Firefox/manifest.json`。
5. 在应用的“浏览器原生连接”区域，为正在使用的 Firefox、Chrome 或 Edge 点击“安装原生连接”。
6. 打开一个普通网页，点击扩展图标，粘贴令牌并连接。

连接成功后，可以选择现有资料库分类，也可以在保存时直接创建新分类。再次保存同一网址
会按资料库的导入规则更新或去重，并可重新归类。

## 直接保存与采集模式

弹窗主界面只保留“直接保存当前页面”主操作，不再生成或要求确认保存前预览。
插件会从页面自动读取标题、作者和标签，在一次保存操作内完成采集、页面身份校验、写入和索引。
默认折叠的“保存选项”仍支持四种采集模式：

- **净化正文**：提取语义化标题、段落、列表与链接，过滤常见导航、广告和交互噪声，不保存页面归档。
- **完整网页**：保存同一份可检索净化正文，并额外生成 MHTML 或自包含离线 HTML 归档。
- **选中文字**：只保存用户当前选中的文字；没有选择内容时会明确拒绝空内容。
- **仅链接**：保存页面标题和原始网址，适合稍后阅读或轻量引用。

“保存选项”内可选择分类、新建分类、记住来源网站，并设定是否允许 AI 检索。
完整网页的离线归档会在直接保存时生成。

## 智能分类选择

分类选择器支持名称搜索，并在插件本地保存最近使用与用户收藏的分类。启用“记住此网站的分类选择”后，
插件会按去除 `www.` 的来源域名记录选择；以后采集同一网站时优先恢复该分类，用户仍可在保存前修改。

为保持直接保存路径简洁，弹窗不再在保存前生成作者、标签和相关分类建议面板。
分类依然优先恢复来源域名记忆，其次使用上次选择；用户可在折叠选项中随时更改。

## 快速操作与批量保存

- 网页右键菜单提供“保存净化正文”；选中文字和链接的右键菜单分别提供摘录保存与仅链接保存。
- `Command/Ctrl+Shift+K` 打开采集面板，`Command/Ctrl+Shift+Y` 快速保存当前网页净化正文，
  `Command/Ctrl+Shift+U` 快速保存当前选中文字。用户可在浏览器扩展快捷键设置中重新绑定。
- 在标签栏用 Command/Ctrl 多选标签页后，插件可按当前采集模式、分类和默认 AI 权限顺序保存最多 10 项。
- 首次批量使用分两步授权：插件临时读取所选标签页地址并立即撤销 `tabs` 权限；再次点击后只申请
  所选 HTTP/HTTPS 网站的精确来源权限。采集后台和弹窗都会在成功或失败后尝试撤销本次新增权限，
  已经由用户长期授予的权限不会被移除。
  非当前标签页的正文采集需要用户明确授予可选的 HTTP/HTTPS 网页访问权限；普通单页保存仍只使用 `activeTab`。
- 弹窗内可用 `Command/Ctrl+Enter` 直接保存、`Command/Ctrl+Shift+B` 启动批量保存。

工具栏徽标会区分连接、保存中、成功、失败和待处理数量，并同步更新可供屏幕阅读器读取的按钮标题。
批量任务逐项隔离失败；成功、离线入队、重复待确认和失败数量会分别汇总，不因单个页面失败中断其余页面。

## 保存回执与打开资料

保存成功后，插件不再只显示“新增/更新/跳过”数量，而是显示“已保存到长期参考”回执，包含：

- 资料 ID 和标题。
- 实际保存到的分类（未归类时明确显示“未分类”）。
- 存储文件大小与 MHTML、离线 HTML 或仅正文归档类型。
- 全文和本地语义索引状态，以及 AI 使用权限。

回执会保留在扩展本地存储中。点击“在资料库中打开”后，插件通过已鉴权的本机接口请求应用
切换到资料库、清除会隐藏该资料的搜索/分类范围，并选中准确文档。该接口不接受未鉴权请求。

## 重复网页处理

采集到与资料库现有资料相同的标准网址时，导入会在写入前暂停，不再静默更新或重新归类。
插件会显示现有资料的标题、分类、大小、更新时间，以及本次采集是否包含新正文，再由用户选择：

- **保存新版本**：使用同一文档 ID 创建新修订，即使正文未变也会明确保留一个新版本。
- **仅移动分类**：以单次原子更新修改原资料的分类，不写入归档、不创建修订，也不继承本次表单的
  标题、作者、标签或 AI 权限。
- **保留副本**：使用新文档 ID 保存独立副本，保留原始来源网址，标题附加“（副本）”。
- **取消**：删除本次待处理采集，资料库不发生任何变化。

离线队列恢复时如果遇到同网址，该项会转为“需手动处理”并保留完整采集内容，不会被当作已导入而移出队列。

## 待保存队列

如果应用未打开、本机桥接短暂中断或返回可重试的服务端错误，插件会先完成正文和页面归档采集，
并将完整导入请求保存在扩展自己的本地存储中。待应用恢复后，后台会按指数退避自动重试；
重新打开插件并成功连接时也会立即重试。

- 队列上限为 10 项或 96 MB，任一条件先到即拒绝继续写入，不会静默丢弃旧项目。
- 每次直接保存时创建稳定的 operation ID；超时、离线重试和重复网页处理始终复用同一 ID。
- 队列只合并同一 operation ID 的重复写入。同网址的选中文字、完整网页和不同时间版本会分别保留，
  不会再按网址与分类静默覆盖。
- 队列不保存连接令牌；重试时只读取插件当前的本机令牌。
- `401`/`403` 鉴权错误和 `422` 内容错误不会被无限自动重试；界面会标记需要手动处理的项目。
- 插件弹窗会显示队列数量和占用空间，并提供“立即重试”与需要二次确认的“清空队列”。

## 数据边界

- 三种浏览器扩展都通过 `runtime.sendNativeMessage()` 调用固定名称的原生宿主；Firefox 清单只允许
  `knowledge-capture@jinfang.local`。Chrome 与 Edge 使用各自独立的来源列表：开发期间只允许固定开发来源
  `chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam/`；商店分配正式 ID 后，只给对应浏览器追加该
  商店来源，不会把 Chrome Web Store ID 加到 Edge 清单或反向混用，也不使用通配来源。
- 两套扩展清单都不再申请访问 localhost 的 `host_permissions`。宿主只转发四个资料库接口，
  限制单次输入 50 MB、输出 1 MB，并通过当前用户专属、权限为 `0600` 的 Unix Domain Socket
  连接应用；应用仍要求随机连接令牌。
- Native Messaging 宿主使用 5 秒连接超时；资料导入和本地索引允许最长 120 秒响应时间。应用在发送
  成功响应前持久化 operation ID、请求指纹和回执，重试时直接重放原回执，不再次创建资料或版本。
  幂等账本最多保留 256 项、30 天，且不保存网页正文和归档。
- 应用不再监听 TCP 端口，也不再返回 CORS 头或处理浏览器 OPTIONS 预检。套接字路径按 macOS 用户 ID
  隔离，启动时拒绝覆盖同路径的普通文件，退出时清理套接字。
- 连接令牌有效 30 天；旧版长期令牌会平滑获得首次有效期。过期或在应用中手动更换后，旧令牌立即失效，
  插件会清除浏览器端副本并要求重新配对。
- 插件提供“断开并清除令牌”和“重新配对”；这些操作只删除令牌，不删除离线待保存队列和分类偏好。
- 鉴权接口拒绝普通 `http/https` 网页 Origin，只接受 Chromium `chrome-extension://` 或 Firefox
  `moz-extension://` 扩展来源；本机状态探测接口不返回令牌或资料内容。
- `alarms` 只用于本机待保存队列的定时重试；`unlimitedStorage` 用于保留可能较大的离线页面归档，
  插件自身仍强制 10 项/96 MB 上限。
- Chrome / Edge 默认保存 MHTML；超过 24 MB 时自动退回到清理后的 HTML。
- Firefox 不提供 MHTML 页面归档接口，会在 24 MB 上限内把可读取的图片、样式和字体
  内联为自包含 HTML；`dns` 权限只用于每次资源请求和每一跳重定向前解析主机，解析到私网、回环、
  链路本地、保留或组播地址时拒绝下载。扩展禁用自动重定向并逐跳重新校验，响应体按块读取，超过
  单资源或剩余归档预算时立即取消；跨域、超时、被安全策略拒绝或过大的资源会在保存结果中列入缺失数量。
- 登录态页面的归档可能包含页面当前可见的私人内容，请按资料库本地文件一样保护。
- `chrome://`、扩展商店页面等浏览器受保护页面无法采集。

Native Messaging 由直接分发版应用打包独立 Swift 宿主，并在用户确认后分别将清单写入 Firefox、
Google Chrome 或 Microsoft Edge 的当前用户 `NativeMessagingHosts` 目录。应用移动或升级后可点击
“修复原生连接”刷新绝对路径。Chrome/Edge 清单中的公开开发密钥只用于让未打包扩展保持固定 ID；
从 Chrome Web Store 或 Edge Add-ons 发布时，必须把两家商店各自分配的正式 ID 回填到协议身份源；
生成器会把它们加入对应宿主的 `allowed_origins`，不会要求手工修改用户目录中的清单。

Chrome/Edge 与 Firefox 使用各自最小化的 Manifest V3 清单，并通过同步脚本共享同一套
采集与弹窗代码。Firefox 临时安装会在浏览器重启后失效。

## 协议身份与生成物

`browser-extension-protocol.json` 是原生宿主名、消息协议版本、路由、大小上限和
Firefox/Chromium 开发与生产扩展 ID 的唯一来源。`chromeProductionID` 与
`edgeProductionID` 为 `null` 时表示商店尚未分配身份，不会自动回退成一个伪生产 ID。
修改它之后执行：

```bash
python3 script/generate_browser_extension_protocol.py --write
python3 script/generate_browser_extension_protocol.py --check
```

生成器会同步 Swift 和 JavaScript 常量、Firefox 后台脚本顺序及发布配置，并校验
Chromium 清单公钥实际派生的固定 ID。生成文件被手动修改、遗漏生成或清单 ID
不一致时，浏览器发布门禁会直接失败。

## 不可变发布账本

`release-ledger.json` 是浏览器扩展的共享发布账本。Chromium 和 Firefox 打包器会对两份清单、
共享脚本、弹窗资源、图标、语言包及 Firefox 发布配置计算统一的源码 SHA-256，并在生成候选包后记录
版本、ZIP/XPI 文件名、产物 SHA-256 和候选生成时间。已存在的同版本产物只能按相同字节复用；脚本会
拒绝版本倒退、版本数字别名、同版本不同源码，以及用不同字节覆盖已有 ZIP/XPI。

发布门禁会验证当前源码与账本记录一致：

```bash
python3 script/browser_extension_release_ledger.py check
```

本地打包不等同于商店已经上线，因此账本把候选生成时间与真正发布时间分开。确认某个渠道已经发布后，
显式追加一次不可修改的 UTC 发布时间：

```bash
python3 script/browser_extension_release_ledger.py publish \
  --version 0.20.0 \
  --channel chrome \
  --published-at 2026-07-19T08:00:00Z
```

`--channel` 可取 `chrome`、`edge` 或 `firefox`。Firefox 只有在已签名 XPI 和对应 `updates.json`
都已进入账本后才允许登记发布时间；重复登记相同时间是无操作，修改已经登记的时间会被拒绝。

## Chrome Web Store 与 Edge Add-ons

两家 Chromium 商店共用经过兼容性验证的代码，但使用独立的商店条目、生产 ID、宿主来源白名单
和提交 ZIP。`chromium-store-listing.json` 保存中英文商店文案、HTTPS 隐私/支持地址，以及与清单
逐项对应的权限用途说明；生成包内的 `_locales/zh_CN` 与 `_locales/en` 会同步名称、短描述和工具栏标题，
让两家商店都能识别中英文条目。它不保存开发者账号凭据，也不会自动提交审核。

首次创建商店条目时生成可复现的最小 ZIP：

```bash
python3 script/chromium_extension_release.py check
python3 script/chromium_extension_release.py package
```

输出位于 `dist/browser-extension/`：

- `knowledge-capture-chrome-<version>.zip`
- `knowledge-capture-edge-<version>.zip`

ZIP 根目录直接包含 `manifest.json` 和运行文件，不包含 README、协议源、Firefox 文件或其他开发材料。
打包器会从商店清单移除只用于未打包开发版固定身份的 `key`，也拒绝自托管 `update_url`；两个商店
在首次上传后分别分配生产 ID，并负责把审核通过的 ZIP 转成其安装/更新格式。CI 会构建同样的两个 ZIP
并作为 `chromium-store-submission-zips` 工件保留，但不会登录商店或发布。

首次上传并取得两个草稿条目的 ID 后：

1. 将 Chrome ID 写入 `chromeProductionID`，Edge ID 写入 `edgeProductionID`。
2. 执行 `python3 script/generate_browser_extension_protocol.py --write`。
3. 执行 `python3 script/chromium_extension_release.py readiness`，确认两个 ID 均有效、彼此独立且不等于开发 ID。
4. 重新构建应用并在连接窗口修复 Chrome/Edge 原生连接，让用户目录里的宿主清单获得对应生产来源。
5. 重新运行浏览器发布门禁后再提交审核；严格总门禁会在任一生产 ID 仍待定时失败。

商店新版本仍使用同一打包命令；提交前必须先递增 `manifest.json` 与 Firefox 清单中的扩展版本。
打包成功后两个 ZIP 会原子安装到输出目录并追加到账本，不再覆盖同名版本产物。

## Firefox 长期安装与更新

Firefox 正式版只接受 Mozilla 签名的长期安装包。仓库将开发清单与发布清单分开：
开发清单不携带 `update_url`，打包时才注入经 HTTPS 保护的更新地址。当前清单要求
Firefox 142 或更高版本，以确保 `optional_host_permissions` 和数据收集声明在桌面与 Android
清单校验中都受支持；实际资料采集仍依赖桌面 Firefox 的 Native Messaging。

发布前使用固定的 `web-ext 10.5.0` 严格检查清单，任何警告都会阻止发布：

```bash
python3 script/firefox_extension_release.py lint
```

1. 生成可复现的待签名候选包：

   ```bash
   ./script/package_firefox_extension.sh
   ```

   输出在 `dist/browser-extension/`。文件名含 `-unsigned`，只用于检查，不能被
   Firefox 正式版长期安装。

2. 在 Mozilla Add-ons 创建 API 凭据，本机安装 `web-ext`，然后显式执行 unlisted 签名：

   ```bash
   export AMO_JWT_ISSUER='...'
   export AMO_JWT_SECRET='...'
   ./script/sign_firefox_extension.sh
   ```

   凭据只从环境变量读取，脚本不会写入仓库或打印密钥。签名成功后会校验 XPI 里的
   Mozilla 签名、扩展 ID、版本和 `update_url`，再根据已签名文件的 SHA-256 生成
   `updates.json`。已签名 XPI 与更新清单会通过不可变安装命令进入发布账本。

3. 将已签名 XPI 和 `updates.json` 一起上传到 `firefox-release.json` 配置的 HTTPS
   路径。脚本不会自动上传、公开发布或提交审核。上传后执行：

   ```bash
   python3 script/firefox_extension_release.py verify-remote
   ```

   这项严格门禁会逐次验证同主机 HTTPS 重定向、公网地址、HTTP 200、
   Content-Type 和下载大小上限，再比对扩展 ID、版本、最低 Firefox 版本、
   下载地址、SHA-256 及远端 XPI 字节，最后重新检查 XPI 签名与仓库载荷。

非 App Store 的 Debug 应用允许在没有已签名 XPI 时运行，方便开发临时加载；Info.plist 会明确记录
`PersonalSitePublisherFirefoxSignedPackageAvailable=false`，且不会创建空的 `Release` 目录。

Direct Release 构建则必须先在 `dist/browser-extension/` 找到与当前版本匹配的 Mozilla 已签名 XPI。
`build_and_run.sh --package-only --release` 会在编译前验证签名、扩展 ID、版本、更新地址和仓库载荷，
再把 XPI 与重新生成的 `updates.json` 放入应用；打包后会从应用资源目录再次验证更新清单与 XPI。
缺失、损坏或版本不符都会直接终止打包，不提供跳过开关。App Store 构建继续明确排除 XPI、
Native Messaging 宿主及其他浏览器扩展资源。资料库的“浏览器资料采集”窗口只对验证过的签名包提供安装按钮。

如果签名版已经发布到 `firefox-release.json` 配置的地址，但本机 `dist` 尚未保存它，可以显式执行：

```bash
python3 script/firefox_extension_release.py fetch-verified
```

该命令逐次限制 HTTPS 同主机重定向、公网地址、Content-Type 和响应大小；只有远端更新清单、SHA-256、
扩展版本、载荷及签名封装全部通过后，才会把 XPI 与 `updates.json` 原子替换到本地发布目录。

Firefox 签名产物准备完成后，Direct macOS 发行还必须执行 Developer ID 签名、Apple 公证、票据装订和
Gatekeeper 验证。完整命令与产物边界见 [`docs/DIRECT_DISTRIBUTION.md`](../docs/DIRECT_DISTRIBUTION.md)。
