# 保存到资料库浏览器扩展

这是“RepoPress Studio”的本机网页采集扩展。它会提取当前网页的正文、标题、作者、
摘要、标签和语言，并可同时保存一份离线页面归档。当前版本支持 Safari、Chrome 和 Firefox，三者都通过
带随机令牌的 `127.0.0.1:17843` 本机回环接口写入资料库，不安装 Native Messaging 宿主，
也不经过云端服务。

## 开发版安装

1. 打开“RepoPress Studio”，进入资料库，点击工具栏中的拼图按钮，复制连接令牌。
2. 确认应用显示本机回环连接已经就绪。
3. 按浏览器选择安装方式：
   - Safari：运行 `./script/build_and_run.sh` 后，在 Safari 设置的“扩展”中启用
     “RepoPress Studio · 资料采集”；正式版扩展随 Mac App Store 应用安装。
   - Chrome：打开扩展管理页，启用“开发者模式”，点击“加载已解压的扩展”。
   - Firefox：打开 `about:debugging#/runtime/this-firefox`，选择“临时载入附加组件”，
     再选中 `BrowserExtension/Firefox/manifest.json`。
4. Chrome 选择 `BrowserExtension` 文件夹。
5. Firefox 选择 `BrowserExtension/Firefox/manifest.json`，打开一个普通网页，点击扩展图标，
   粘贴令牌并连接。

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

“保存选项”内可选择分类、新建分类、记住来源网站，并分别设定“建立本地语义索引”和“允许发送给远程 AI”。
本地索引默认开启，远程 AI 默认关闭；两项互不替代。
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
- 在标签栏用 Command/Ctrl 多选标签页后，插件可按当前采集模式、分类和默认语义检索设置顺序保存最多 10 项。
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
- 全文和本地语义索引状态，以及是否允许发送给远程 AI。

远程 AI 发送权限只在应用内明确开启的资料上生效。应用的 AI 设置会显示当前服务商、发送内容范围和撤销授权入口；
资料库条目本身也可单独撤销远程 AI 权限。浏览器扩展不会把旧的“加入本地语义检索”偏好迁移成远程发送许可。

回执会保留在扩展本地存储中。点击“在资料库中打开”后，插件通过已鉴权的本机接口请求应用
切换到资料库、清除会隐藏该资料的搜索/分类范围，并选中准确文档。该接口不接受未鉴权请求。

## 重复网页处理

采集到与资料库现有资料相同的标准网址时，导入会在写入前暂停，不再静默更新或重新归类。
插件会显示现有资料的标题、分类、大小、更新时间，以及本次采集是否包含新正文，再由用户选择：

- **保存新版本**：使用同一文档 ID 创建新修订，即使正文未变也会明确保留一个新版本。
- **仅移动分类**：以单次原子更新修改原资料的分类，不写入归档、不创建修订，也不继承本次表单的
  标题、作者、标签或语义检索设置。
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

- Safari、Chrome 和 Firefox 扩展都只访问固定的 `http://127.0.0.1:17843/*`。应用的沙盒监听器只绑定 IPv4 回环地址，
  不接受局域网或互联网连接。
- 每个请求必须携带协议专用请求头和随机配对令牌。应用会拒绝普通网页 Origin；Chrome 会校验已登记的
  开发或商店扩展 ID，Safari 会校验浏览器分配的 UUID 扩展来源。
- 浏览器跨域预检只允许 `GET`、`POST` 和固定鉴权请求头。普通网页无法在预检未通过时构造有效请求。
- 单次输入限制为 50 MB，输出限制为 1 MB。应用在发送成功响应前持久化 operation ID、请求指纹和回执，
  重试时直接重放原回执，不再次创建资料或版本。幂等账本最多保留 256 项、30 天，且不保存网页正文和归档。
- 连接令牌有效 30 天；旧版长期令牌会平滑获得首次有效期。过期或在应用中手动更换后，旧令牌立即失效，
  插件会清除浏览器端副本并要求重新配对。
- 插件提供“断开并清除令牌”和“重新配对”；这些操作只删除令牌，不删除离线待保存队列和分类偏好。
- 鉴权接口拒绝普通 `http/https` 网页 Origin，只接受 Chrome `chrome-extension://`、Safari
  `safari-web-extension://` 或 Firefox `moz-extension://<UUID>` 扩展来源；本机状态探测接口不返回令牌或资料内容。
- `alarms` 只用于本机待保存队列的定时重试；`unlimitedStorage` 用于保留可能较大的离线页面归档，
  插件自身仍强制 10 项/96 MB 上限。
- Chrome 默认保存 MHTML；超过 24 MB 时自动退回到清理后的 HTML。
- Safari 不提供 MHTML 页面归档接口，会在 24 MB 上限内把可读取的图片、样式和字体
  内联为自包含 HTML；`dns` 权限只用于每次资源请求和每一跳重定向前解析主机，解析到私网、回环、
  链路本地、保留或组播地址时拒绝下载。扩展禁用自动重定向并逐跳重新校验，响应体按块读取，超过
  单资源或剩余归档预算时立即取消；跨域、超时、被安全策略拒绝或过大的资源会在保存结果中列入缺失数量。
- 登录态页面的归档可能包含页面当前可见的私人内容，请按资料库本地文件一样保护。
- `chrome://`、扩展商店页面等浏览器受保护页面无法采集。

RepoPress 只维护一个 Mac App Store 应用版本。Safari Web Extension 以签名 `.appex` 内置于该应用，
由用户在 Safari 设置中启用；Chrome 版本从 Chrome Web Store 安装，Firefox 版本从
`BrowserExtension/Firefox/manifest.json` 临时加载。Mac 应用不把扩展文件写入
浏览器目录，也不安装额外宿主。Chrome 清单中的公开开发密钥只用于让开发者模式下的未打包扩展
保持固定 ID；商店正式 ID 写入协议身份源，以便应用校验扩展 Origin。

Safari、Chrome 与 Firefox 使用各自最小化的 Manifest V3 清单，并通过同步脚本共享同一套采集与弹窗代码。
Safari 清单不申请不受支持的 `pageCapture`，完整网页使用自包含 HTML 回退。

## Safari Web Extension

`BrowserExtension/Safari/manifest.json` 是 Safari 专用清单。它与 Chromium/Firefox
共享业务脚本、弹窗、图标和语言包，但不包含 `pageCapture`、`nativeMessaging` 或 Chromium
开发密钥。同步和构建命令：

```bash
./script/sync_safari_browser_extension.sh --check
./script/build_safari_web_extension.sh
```

构建脚本使用 Apple 的 Safari Web Extension 转换器生成临时 Xcode 工程，只构建扩展 target，
并输出 `RepoPressSafariExtension.appex`。`script/build_and_run.sh` 将该扩展嵌入
`Contents/PlugIns`，先签名子扩展再签名外层应用。App Store 分发必须为
`com.jinfang.PersonalSitePublisherMac.SafariExtension` 配置独立的 App ID 与 provisioning
profile；它仍属于同一个 RepoPress 应用，不产生独立浏览器商店版本。

## 协议身份与生成物

`browser-extension-protocol.json` 是本版本启用渠道、回环地址、协议请求头、路由、大小上限、
Safari bundle ID、Chrome 开发与生产扩展 ID 及 Firefox add-on ID 的唯一来源。Edge 身份字段仅为以后恢复
渠道保留，不在当前版本启用。保留的
共享协议只生成回环接口的地址、请求头、路由和大小限制。
当前扩展不会申请或调用 Native Messaging。`chromeProductionID` 与
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

`release-ledger.json` 保留各版本的历史发布记录。当前正式商店账本仍只登记 Chrome ZIP；旧版 Edge/Firefox
记录保持不可变。Firefox 的临时加载和真实浏览器验证不等同于 AMO 发布，也不会在本次修改中伪造签名或发布时间。
打包器会对清单、共享脚本、弹窗资源、图标和语言包计算统一的源码 SHA-256，并记录
版本、Chrome ZIP 文件名、产物 SHA-256 和候选生成时间。已存在的同版本产物只能按相同字节复用；脚本会
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

当前版本只登记 `chrome` 发布时间；重复登记相同时间是无操作，修改已经登记的时间会被拒绝。

## Chrome Web Store

`chromium-store-listing.json` 保存 Chrome 的中英文商店文案、HTTPS 隐私/支持地址，以及与清单
逐项对应的权限用途说明；生成包内的 `_locales/zh_CN` 与 `_locales/en` 会同步名称、短描述和工具栏标题。
它不保存开发者账号凭据，也不会自动提交审核。

首次创建商店条目时生成可复现的最小 ZIP：

```bash
python3 script/chromium_extension_release.py check
python3 script/chromium_extension_release.py package
```

输出位于 `dist/browser-extension/`：

- `knowledge-capture-chrome-<version>.zip`

ZIP 根目录直接包含 `manifest.json` 和运行文件，不包含 README、协议源、Firefox 文件或其他开发材料。
打包器会从商店清单移除只用于未打包开发版固定身份的 `key`，也拒绝自托管 `update_url`；Chrome
负责把审核通过的 ZIP 转成安装/更新格式。CI 可以构建同样的 ZIP，但不会登录商店或发布。

取得 Chrome 商店条目的正式 ID 后：

1. 将 Chrome ID 写入 `chromeProductionID`。
2. 执行 `python3 script/generate_browser_extension_protocol.py --write`。
3. 执行 `python3 script/chromium_extension_release.py readiness`，确认 ID 有效且不等于开发 ID。
4. 重新构建应用，确认回环服务端允许新登记的 Chrome 生产扩展 Origin。
5. 重新运行浏览器发布门禁后再提交审核；严格总门禁会在任一生产 ID 仍待定时失败。

商店新版本仍使用同一打包命令；提交前必须先递增扩展版本。打包成功后 Chrome ZIP 会原子安装
到输出目录并追加到账本，不再覆盖同名版本产物。

## Firefox 独立扩展

Firefox 是独立于 Mac App Store 应用的浏览器扩展路径。开发和本机验收使用
`BrowserExtension/Firefox/manifest.json` 的临时加载方式；应用设置页会打开
`about:debugging#/runtime/this-firefox`，并说明加载清单和粘贴连接令牌的位置。

协议生成、共享资源同步、兼容性回归和真实 Firefox BiDi E2E 会把 Firefox 作为启用渠道验证。
这不宣称已经提交或通过 Mozilla Add-ons（AMO），也不生成可长期安装的签名 XPI。根 Node 工具链不安装
`web-ext`，旧 Firefox 签名入口保持拒绝执行；以后要做 AMO 发布，必须在独立、无仓库 secrets 的受限流程中
重新建立 lint、签名、审核和不可变产物记录。

## 暂缓渠道

Edge 仍不属于当前发布范围，不在应用界面、支持页、App Store 文案或发布 profile 中承诺支持，也不会生成新的
Edge ZIP 或执行对应商店发布门禁。仓库保留旧版 Edge 适配源码和不可变记录，方便以后重新评估；这些文件不表示当前支持 Edge。

当前正式发布只包含随 Mac App Store 应用签名的 Safari Web Extension 和提交到 Chrome Web Store
的 Chrome ZIP。Firefox 扩展不嵌入 Mac App Store 应用，Edge ZIP、未打包扩展和 Native Messaging 宿主也不随应用分发。
