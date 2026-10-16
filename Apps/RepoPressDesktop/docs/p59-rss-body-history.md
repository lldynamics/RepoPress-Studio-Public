# P59：RSS 正文解析与历史全文判定

接续 [P58](p58-rss-failure-ledger.md)，以冻结的 `origin/main@878d8cc` macOS RSSFeedParser、RSSArticleFullTextService 和历史补全合同为参照，补齐 RSS/Atom 正文解析到历史全文判定的链路。

## 复核与更正

P57 曾把摘要存储描述为“数据库不保留原始 summary HTML”，该判断不准确，已在 [P57 记录](p57-rss-history-completion.md)更正。数据库一直保存解析器产出的 summary payload；RSS description/summary 的 XML 文本或 CDATA 可以保留 HTML，保存的并非原始 XML 字节。历史全文启发式与 macOS 已基本一致：空正文、content 与非空 summary 相等且可读长度小于 1200，或正文末尾 160 字符出现截断信号。

实际缺口是旧解析器按当前标签名分发文本：Atom `content/summary type=xhtml` 的嵌套 p、a、div 文本会丢失，内层 title、id、link 等还可能污染文章元数据。正文丢失又会令原本完整的短文进入全文补抓候选。本批修复解析字段的所属元素与深度，不放宽全文抓取权限或 URL 身份判断。

## 本批行为

- RSS description 与 content:encoded 的 HTML 文本/CDATA 沿用存储；Atom 缺省/text 按字面文本进行 HTML 转义，html 按 XML 解码后保存 HTML，xhtml 保存嵌套结构和内部空白，并去掉标准 XHTML div 外壳。XML MIME（如 application/xhtml+xml、vendor+xml）保留内容根，直系 xhtml:body 可作为低优先级正文回退。类型与外部内容规则依据 [RFC 4287 §3.1、§4.1.3](https://www.rfc-editor.org/rfc/rfc4287#section-4.1.3)。
- 正文子树和扩展名称空间不参与条目/元数据分发。正文内的 title、id、link、name、entry 都不能改写文章标题、身份、作者、原文链接或生成额外条目；Atom 作者仍取直接 author/name。RSS2 核心字段识别空或根名称空间，RDF 识别空或 RSS1 名称空间。
- 摘要优先级为 description 2、RSS summary 1；正文为 CONTENT namespace 的 encoded 3、核心 content/encoded 和 xhtml:body 1，Atom summary/content 2。同级保留首个非空值；高优先级可替换低优先级。属性按白名单稳定排序和转义，Atom 文本中的字面标签不会变成 HTML 标记。
- Atom 外部 content src 与不支持的二进制类型只参与本地忽略/摘要回退，不进入下载请求或封面地址。相对文章链接继续按订阅响应 URL 解析，XML 属性中的实体先解码。
- 解析器保留 20 MiB 输入、256 层深度、最多 10000 篇有效文章和 DTD/未定义实体拒绝。恰好 10000 篇可接受，第 10001 篇拒绝。每个正文/摘要序列化结果最多 4 MiB，转义膨胀也计入；单个名称空间 URI 最多 8 KiB，超限拒绝整次解析。

RSS 正常刷新会使用新的解析结果；已有文章无需数据库迁移，schema 4、JSON 与十表 SQLite 快照合同继续兼容。全文补齐仍由用户明确开启，先预览、确认再请求。就绪的同源全文缓存优先复用，短但完整、且与摘要不同的正文不只因篇幅短而请求。新增回归验证了摘要候选的显式选择、全文只写缓存、原正文/阅读/收藏状态保留和外部 src 不进入请求。真实刷新与 JSON 往返回归同时发现并修复了两处既有校验偏差：非空 read_at 应按可空非负整数处理，HTML summary 应使用与正文相同的 4 MiB 上限。字段格式、版本和整包 64 MiB 限制不变；负值或字符串时间戳拒绝，解析失败不会部分写入文章或订阅。

界面中英文同步改为“缺失或仅含摘要、截断内容的正文”，并明确完整短文与就绪缓存的处理方式。P58 的失败账本、跨段游标、重试确认、暂停/取消与并发状态复验继续沿用。

## 验收与范围

主线程负责解析器架构、名称空间/字段归属、边界和最终集成；独占工作包使用 `gpt-6-luna medium` 更新界面说明，`gpt-5.6-sol high` 编写独立解析/历史回归，`gpt-5.6-sol xhigh` 对比 macOS 合同并独立审阅。审阅发现 RSS2/RDF 名称空间混用与正文优先级偏差，均已修复并补回归。

最终组合门禁：

- `npx vitest run --maxWorkers=4`：208 个文件、1753 项通过。
- `cargo test --offline -- --test-threads=4`：Rust 全量 784 项通过。本批新增 22 项解析、边界、刷新/备份与历史全文回归均通过；包括正文解析失败不部分刷新、阅读/收藏/标签/正文往返保留、关闭正文缓存偏好和 1 MiB 以上摘要往返。
- `cargo clippy --offline --all-targets --all-features -- -D warnings` 通过。
- `npm run build`、`check:bundle`、`check:version` 通过。启动 JavaScript 698.7 / 700 KiB，9 个延迟 chunk，版本 0.1.0。Vite 保留既有混合导入与大 chunk 提示。
- 本批 6 个 Rust 文件格式检查、`git diff --check` 通过。全仓 fmt 仍只报告三个既有文件：`ai_connection.rs`、`ai_provider.rs`、`workspace_state.rs`，本批哈希未变。
- 2499 个原始文件无丢失；仅修改 10 个本批相关既有文件、新增 5 个文件，其余 2489 个原始文件哈希不变。增量补丁在原始字节副本中严格重放后逐文件哈希一致；HEAD 和暂存区未变。

测试仅使用合成内容、注入响应、临时数据库与本地测试服务器，不访问真实订阅或用户 RSS 数据。

完整 Atom 规范一致性、xml:base/语言继承、所有 feed 扩展、真实站点、真实 Tauri 桌面、Wayland/X11、中文输入法和辅助技术仍需后续验收。此批不代表完整 macOS RSS 等价；登录、查询参数分页、跨域/压缩 sitemap、JavaScript 来源和无限扫描仍不在历史补全范围。

原有脏树改动保留，未提交、推送、合并或清理 Git。原始字节副本、增量源码、审阅、日志、保留校验和可重放补丁保存在 `p59-rss-body-history` 证据目录。
