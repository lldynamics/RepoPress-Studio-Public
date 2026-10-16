# macOS / Linux 再次对比与完善计划（2026-10-13）

2026-10-15 P63：[确认式启动与 HTTP 页面就绪验证](p63-preview-readiness.md)接通五分钟一次性计划、配置/文稿复验、所有权定向停止和页面核验后嵌入；TCP/进程启动不再被当作页面就绪。前端 2,021 / Rust 825 测试通过，首屏 685.0 KiB；原生矩阵仍单独验收。

2026-10-15 P62B：[draft/ready 预览确认变更](p62b-article-state-changes.md)已接入文章状态面板，确认只修改编辑内容、可独立撤销，普通保存继续核对原路径与 SHA；前端 1,970 / Rust 790 测试及新 deb/AppImage 冒烟通过；编辑、切换和保存会作废旧预览。提醒与文稿部署证据仍待后续实施。

2026-10-15 实施更新：[P60 自动刷新与本地交付基线](p60-rss-automatic-refresh.md)已完成本报告建议的刷新修复、格式和包体收口，接入首个共享 YAML 兼容切片并构建本机安装包；当前进度以 P60 记录为准，以下比较与排期保留为原快照。

当前 Linux 已覆盖核心写作、阅读、资料管理、AI 辅助及受保护的 Git 发布流程。本次发现 RSS 自动刷新会走强制刷新默认值、绕过常规退避，应优先修正；同时把现有成果收口为可复现的 Linux 交付基线，再补工作区与站点语义、文章状态、写作和预览体验。RSS P56–P59 已接通，不应继续列为“从零补齐”；整工作区恢复、跨端交换和高级 Git 仍需分批设计。

本次只拉取、对比、验证并更新计划，没有实施新的产品功能。

## 1. 最新基线与拉取结果

| 项目 | 本次核实结果 |
| --- | --- |
| 远端 | `https://github.com/lldynamics/RepoPress-Studio-Public.git` |
| 最新 macOS 主线 | `878d8cca8e4044c534a5f63f3cc72d08ce6339a0`；2026-10-11 23:17:07 +08:00；`Fix PDF OCR language selection and repository test shard timeouts` |
| 相较 2026-10-12 对比 | 新增 **0** 个上游提交；已成功重新 fetch，不能将旧提交描述为本次新增功能 |
| Linux 分支 | 本地 `codex/linux-tauri-mvp`，HEAD `97f1fd75e12b4b9606974890bfa317a7bac9b6e3`；远端同名分支不存在，本地 remote-tracking ref 是历史残留 |
| 工作区 | 开始时 726 个改动路径：29 个已跟踪修改、697 个未跟踪文件；共记录 2504 个原始路径 |
| 比较方式 | `origin/main` 没有 `Apps/RepoPressDesktop`，因此展开独立 macOS 源码，与包含 P59 的 Linux 冻结副本比较；没有把 main 合入当前开发分支 |

首次同时 fetch 两个分支因远端 Linux 分支不存在而失败，随后单独 fetch main 成功。当前开发 HEAD 与上游之间存在大量路径差异，29 个已跟踪修改路径都与两条历史线的差异相交；这是历史差异，不是本次新增冲突。直接切换或合并不能替代行为对照。

本次完整源码副本和证据在 [refresh-2026-10-13](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/git-comparison.json)。macOS 参考 [固定源码 README](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/macos-main/README.md)，Linux 验证使用 [冻结 App.tsx](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/linux-source/Apps/RepoPressDesktop/src/App.tsx)。

## 2. 对旧计划的更正

1. **RSS 历史补全已接通。** P56 URL 隐私审阅、候选发现与确认导入，P57 分段游标、已有文章正文补抓和检查点维护，P58 持久失败账本与分批重试，P59 RSS/Atom 正文解析及全文判定都已有产品链路。当前任务是网络样本、桌面体验和剩余边界验证，不能继续列为缺失。
2. **正则查找替换已实现。** Linux 已有正则开关、捕获组、Worker 超时/取消和确认式替换预览；2026-10-12 矩阵中的“没有 macOS 正则路径”判定错误。
3. **导航不是从零实现。** 内容健康抽屉已经关联 sync 主导航高亮。剩余是“阅读/站点”命名、站点工作区组织及上下文语义；需要按流程调整，不能只换两个标签。
4. **草稿历史已有命令入口。** 版本比较已有分区、双行号及折叠。剩余是并排/堆叠、行高对齐和词段高亮；不应笼统列“缺版本比较/历史入口”。
5. **备份要按范围描述。** 配置、RSS、草稿快照及单资料库恢复已存在；整工作区一致备份、恢复和 macOS 交换协议仍未接通。P55 的回执/保留策略也不能代表这几个大范围已经完成。

**本次新确认的优先项：常规 RSS 自动刷新语义。** [计时器复用 refresh()](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/RssReader.tsx:146) → [Gateway 默认 force=true](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/features/rss/rssGateway.ts:29) → [Rust 只有 !force 才检查 next_refresh/next_retry](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/rss.rs:1291)，所以自动刷新当前会跳过已有调度与失败退避判断。这是静态调用链确认的问题，尚未以真实站点复现或修复；P56–P59 的历史任务限额/失败账本是另一条流程。阅读页又是 [条件挂载](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/App.tsx:1573)，离开阅读页会清除计时器；现有设置也明确写着“工作区活跃时自动刷新”，因此这一点是范围差异，不是违反当前文案的缺陷。扩展至应用级调度需要新的显式模式选择。

## 3. 当前能力与真实差距

“已接通”表示源码存在可达的产品调用链，不表示真实网络、原生窗口或发布产物已验收。部分能力的范围限制是当前设计选择，需要单独评估后再扩展。

| 范围 | Linux 当前状态 | 下一步实际差距 |
| --- | --- | --- |
| 工作区导航与布局 | 部分 | 已有主路由、侧栏、Inspector、可调列和受保护跳转；补最新“阅读/站点”组织、上下文绑定和窄窗策略 |
| 文章状态与提醒 | 已有 draft 字段，缺少等价完整流程 | 对齐 draft/ready/published/localOnly 四态投影及问题入口，再独立做提醒；到期不等于已发布 |
| 编辑、查找、大纲、SEO | 主路径已接通 | 单稿正则无需重做；补首行重复标题诊断、长文异步统计及正文/字符口径；跨稿批量替换、复杂 Front Matter/完整 SEO 分批处理 |
| 草稿版本比较 | 部分 | 保留双行号/折叠/确认恢复；补对齐布局和词段差异，而不是重建历史库 |
| 站点预览 | 部分 | 当前 Hugo/Zola 有确认式启动；补具体页面 HTTP 就绪、输入变化使计划失效、进程退出/超时反馈，再考虑其他生成器 |
| 多站点与多窗口 | 部分 / 缺失 | 站点目前主要是名称与仓库路径登记；缺生成器/路径/作者/发布/AI 配置及迁移；窗口所属站点、文稿和退出事务另批 |
| RSS 阅读与历史 | 主路径已接通，自动刷新存在具体差距 | P56–P59 保留；先修自动刷新 force/退避和调度生命周期，再做真实来源验收、列表译题；跨域、登录、JS 来源、无限抓取不作为默认追平目标 |
| AI 对话与选区编辑 | 主路径已接通 / 高级能力缺失 | OpenAI-compatible/Ollama、流式取消、逐轮发送审阅和可选加密历史已有；补固定写作计划、站点模板、能力证据，再独立接入 Codex 账户/运行时 |
| 资料、PDF、笔记 | 部分 | 资料保存/分类/历史已有；补繁中与逐页文字层/OCR 混合、版本比较/恢复、标注与集合；独立笔记及 `.rpnotes` 是独立产品范围 |
| Git 与发布台账 | 主路径已接通 / 高级同步缺失 | 已有计划式暂存、提交、fetch/push/重试、PR/MR 证据和单提交回滚；补只读同步诊断、可恢复同步、签名/可信钩子策略、部署与具体提交/文章归因 |
| 图片与文稿输出 | 部分 | 图片导入/引用诊断/单引用修复、Markdown/HTML 导出已有；补单图片优化与可恢复替换，再扩展裁剪/WebP/批量；PDF 导出、打印分别验收 |
| 备份与跨端交换 | 单库流程存在 / 整体缺失 | 外部附件闭合、跨库一致 manifest、恢复事务与故障回退、分类/文章恢复；另接 `com.repopress.workspace-exchange` version 1 |
| 隐私显示、健康规则、日志 | 部分 | 补私密标题/摘要/路径遮挡、内容问题忽略/恢复规则、业务日志保留/导出；显示遮挡不等于加密 |
| 共享确定性规则 | 尚未形成 Linux 统一消费门禁 | 两侧 40 条清单摘要一致，但未找到 React/Rust 对共享 manifest 的统一消费；应按规则域加入契约测试 |
| Linux 交付与更新 | 实现存在，交付闭环未完成 | 当前 updater endpoint/public key 为空；缺可复现远端 Linux 基线、真实签名候选与升级证据，以及同一产物的桌面风险矩阵 |

## 4. 实施顺序与验收

以下编号是建议批次，尚未开始实现；每个批次都应保留独立可审阅增量，完成后再取下一项。

| 优先级 / 批次 | 有界交付内容 | 必须通过的验收 |
| --- | --- | --- |
| **P0 / P60：RSS 自动刷新** | 先让自动调度显式使用非强制模式、尊重 next_refresh/next_retry，保留手动刷新；应用级调度作为后续可选增量，新增显式模式选择，旧偏好保持仅阅读页范围 | 假时钟＋Gateway 参数＋Rust 调度夹具：未到期不请求、失败退避不绕过、关闭偏好即停止、慢请求不重叠；未来选用应用级模式后切页不重置/复制任务；不自动扩大旧设置的联网范围 |
| **P0 / 交付基线并行收口** | 收口 3 个 Rust 文件的 4 处格式差异；为首屏包体腾出余量；保存可重放源码基线、环境与测试清单；先接入一个共享确定性规则域的 TS/Rust fixture 消费 | 完整前后端回归、build、bundle、version、Clippy、全库 fmt、差异保留检查；共享样例既验证输入输出，也验证实现调用；不只核对样例 SHA |
| **P1 / P61：工作区语义** | [2026-10-15 核心增量已落地](p61-site-workspace.md)：阅读/站点入口、站点总览与检查/发布/管理、窄窗布局，保留 rss/sync 标识及命令 ID | 中英文、窄宽窗浏览器、焦点、脏缓冲取消切换及延迟结果回归已通过；原生矩阵和多窗口验收仍待完成 |
| **P1 / P62：文章状态** | [2026-10-15 只读阶段已交付](p62-article-state-projection.md)：文章检查器、通用草稿归属与问题定位；四态词汇中的 published 因缺少文稿绑定证据保持不产出。[P62B 预览确认 draft/ready 变更](p62b-article-state-changes.md)已交付；到期提醒和文稿部署证据仍待实施 | 归属/只读稿/未来日期/时区/缺失字段/非法结构及旧版本定位回归通过；draft=false、Git push 成功或日期到期不报告线上已发布；原生矩阵待验收 |
| **P1 / P63：预览就绪** | [2026-10-15 P63 已实现](p63-preview-readiness.md)：保持 Hugo/Zola 现有执行边界，补 HTTP 页面验证、一次性启动计划与旧上下文拒绝 | 端口监听但页面 404/500、超时、进程退出、文稿/配置漂移均不能显示成功；仓库脚本不会因此自动执行 |
| **P1 / P64：写作完成度** | [P64A 重复标题诊断与有界会话](p64a-duplicate-heading-diagnostics.md)已完成；接续 P64B 正文统计会话、P64C 版本比较布局/词段高亮，独立落地 | Front Matter 排除策略、中文/emoji/CRLF、长文取消与过期结果；差异比较不修改原稿，确认恢复前再次核验 |
| **P2 / P65：站点配置** | 版本化配置模型、生成器与内容/资源路径、作者及默认字段；配置迁移和复制先于发布/AI 档案扩展 | 旧注册表可读、路径复验、切换隔离、不隐式搬迁草稿/附件；为后续发布、交换提供稳定站点身份 |
| **P2 / P66：备份与交换** | 按“附件引用完整性 → 统一备份清单与一致性协议 → 隔离恢复预览 → 可恢复安装”推进；交换 codec 单独实施 | 损坏/缺失附件拒绝；跨组件失败可恢复；导入不覆盖冲突或重新授予 AI 权限；双端 golden 包互读及故障注入 |
| **P2 / P67：Git 与部署** | 只读 ahead/behind/冲突诊断先行；恢复型同步、可选签名、可信钩子分别实现；部署绑定提交/文章证据 | HEAD/index/worktree 漂移拒绝；冲突/取消/重启恢复；远端结果未知保留为未知，默认隔离执行保持有效 |
| **P3 / P68：AI、资料、阅读** | 可确认的单步写作计划；PDF 繁中/混合提取；资料版本比较/标注/集合；RSS 列表译题；Codex 独立接入 | 逐轮目的地/内容确认，取消与失败无部分写入；PDF 逐页来源证据；翻译保留原文并绑定缓存；账户权限与生命周期专项验收 |
| **P3 / P69：图片与系统体验** | 单图优化预览和可恢复替换先行，再扩格式/批量；PDF 输出、私密显示、多窗口、系统采集分开推进 | 输出实物可打开、图片质量与元数据检查、失败保留原文件；原生文件对话框、剪贴板、中文输入和辅助功能验收 |

**桌面交付验收贯穿 P60–P69。** P60 后就应建立一份可启动 deb/AppImage，随后每个里程碑复用同一套冒烟流程。正式候选按 [Linux release acceptance](linux-release-acceptance.md) 的五行 Ubuntu/GNOME/KDE、X11/Wayland、1x/2x、IBus/Fcitx5、AT-SPI/读屏器矩阵采集证据；当前常用 Fedora/KDE 另作补充环境，不替代合同。签名配置、远端交付分支和正式发布在具体产物可审阅后处理，当前拉取/规划不包含提交、推送或发布授权。

P61 完成后，P62 与 P63 的核心实现可独立开发；共享 App/Gateway 接线顺序集成。P65 是复杂站点发布和交换映射的前置条件；P66/P67 的数据与 Git 决策由主线程设计复核，不与普通 UI 改动混在同一工作包中。

## 5. 下一批建议：P60

执行进度（2026-10-16）：P60 本地交付基线、P61 核心工作区及 P62 只读状态/P62B 明确变更已完成；P63 HTTP 预览就绪验证及 P64A 重复标题诊断已完成；下一批建议 P64B 正文统计会话，提醒与文稿部署证据另行设计。以下保留原规划依据，已执行范围以各批交付文档为准。

先补自动刷新语义，交付基线独立收口，随后优先 P61。P60 先修自动/手动区分；应用级调度作为之后的可选增量，必须提供显式模式选择，旧 `backgroundRefreshEnabled=true` 仍保持仅阅读页范围，不能自动迁移成全应用联网。主线程负责 `App.tsx`、`RssReader.tsx`、Gateway/合同和最终接线；实施规模足够时可分配三个互不重叠工作包，小改动则由主线程直接完成：

| 工作包 | 独占范围与约束 | 验收 |
| --- | --- | --- |
| 调度控制器 | 仅新增的纯调度模块及其测试；主线程先确定输入/停止/进行中合同，实施者不改 App/RssReader | 假时钟覆盖启停、单飞、慢请求、偏好变化、异常后继续；没有同步重入 |
| Rust 退避回归 | 仅新增聚焦测试文件；模块注册及生产实现修正由主线程处理 | 临时数据库与注入响应覆盖未到期/失败退避、手动与自动差异、读写状态保留 |
| 独立接线复核 | 只读审查组件→Gateway→command→core 和退出活动登记，报告由其独占 | 自动参数必须显式；退出/取消/切页没有重复请求或孤立任务；本地夹具不访问真实订阅 |

常规聚焦测试可用 Luna medium；行为合同与跨层取舍由主线程负责。共享合同、Gateway、命令注册和 `AppState` 始终由一个集成者写入。聚焦验证建议运行 `npx vitest run src/components/RssReader.localization.test.ts src/features/rss/rssGateway.test.ts --maxWorkers=4`，另新增并运行自动刷新 UI 集成与控制器测试；后端运行 `cargo test --offline --manifest-path src-tauri/Cargo.toml rss`，集成后跑完整门禁。现有本地化测试不能替代新调度回归。首屏预算保留 700 KiB，基线收口建议额外留出至少 20 KiB 开发余量，不直接上调门槛。

## 6. 本次验证与证据

| 检查 | 本次结果 |
| --- | --- |
| 完整 Vitest | **208 文件 / 1753 项通过** |
| 完整 Rust tests | **784 项通过**；首次受限环境 779 通过、5 项监听 EPERM，同命令在允许本地监听的环境重跑后 784/0 |
| Clippy all-targets/all-features `-D warnings` | 通过 |
| TypeScript / Vite 生产构建 | 通过；仍有 dialog 混合导入和大 chunk 警告 |
| 包体预算 | 通过；首屏 JS **698.7 / 700 KiB**，余量约 1.3 KiB，9 个延迟 chunk |
| 版本一致性 | 通过；0.1.0 |
| 全库 `cargo fmt --check` | **未通过**；`ai_connection.rs`、`ai_provider.rs`、`workspace_state.rs` 共 4 处既有格式差异，未修改源码 |
| Linux CI 脚本自测 | 通过；AT-SPI 10+7 项测试通过，AF_UNIX 编排夹具因环境限制跳过，未运行真实桌面 |
| 共享样例 | 两侧 manifest 各 40 例、SHA-256 一致；只确认清单相同，不代表 Linux 实现已经消费这些规则 |

完整命令、退出码与日志见 [验证汇总](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/validation-summary.md)。上述测试通过没有覆盖新发现的自动刷新组合语义，因此仍需 P60 回归。

两侧精确行号与产品接线见 [写作/工作区审计](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/audit-writing.md)及 [RSS/AI/资料审计](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/audit-rss-ai.md)。主线程另核对：

- 站点配置：[Linux 简单注册表](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/site_profiles.rs:25)；[macOS 站点配置](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/macos-main/Sources/PublishingWorkbenchCore/Models/SiteProfile.swift:15)。
- Git 权限与部署：[Linux 禁用签名](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/git_publish.rs:400)、[禁用钩子](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/git_publish.rs:1676)、[部署未归因提示](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/ReleaseLedgerPanel.tsx:272)；[macOS 站点所属执行策略](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/macos-main/Sources/PublishingDomainContracts/RepositoryGitExecutionPolicy.swift:5)。
- 备份/交换：[Linux 预检仅元数据](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/workspace_backup.rs:1)、[单资料库安装](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/knowledge_restore_install.rs:301)；[macOS 多组件备份](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/macos-main/Sources/PublishingWorkbenchCore/Services/WorkspaceBackupService.swift:14)、[交换协议](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/macos-main/Sources/PublishingBackupCore/Models/WorkspaceExchangeModels.swift:3)。
- 交付配置：[Linux 空 updater 配置](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/tauri.conf.json:32)；[真实桌面证据合同](linux-release-acceptance.md)。

原始 2504 个路径均保留，其中 2501 个原字节未变，仅 3 份既有文档增加本次索引/更正，新增本报告；冻结验证源码逐项哈希未变。HEAD 与暂存内容保持原状态，`git diff --check` 通过。详见 [保留校验](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/preservation.json)及 [本次文档增量](/home/cli/.codex/visualizations/2026/10/13/01a1339a-5f06-72e0-a166-13968925e22d/refresh-2026-10-13/plan-docs.patch)。

## 7. 范围边界

本报告依据最新公共源码与当前本地 Linux 实现；没有验证 macOS 构建、真实 AI/订阅/站点/部署服务、线上 Actions、签名更新或 Linux 原生窗口矩阵。自动测试、离线夹具和纯源码调用链均不能替代这些验收。

退役的旧 Agent loop、外部 MCP 客户端、SiteStarter、应用内模型下载不再作为默认追平目标。macOS 撤下旧浏览器扩展不构成删除 Linux 既有采集桥的理由。CloudKit、Apple Translation、AppKit、Keychain、Sparkle 等按 Linux 等价需求另行设计，不直接搬用 SwiftUI 实现。
