# RepoPress macOS 与 Linux 差距复核 2026年10月2日

2026-10-12 已重新拉取并全面复核：[最新对比报告](macos-linux-comparison-2026-10-12.md)采用 `878d8cc` 主线和当前 Linux 冻结源码。本文件保留此前阶段记录；当前导航/文章状态、RSS 历史补全、OCR、OPML 隐私、P55 恢复链及门禁结论以新报告为准。

2026-10-07 P55 增量：[恢复历史完整快照导出](p55-knowledge-restore-history-export.md)已补任意完整历史的确认式资料包导出，包可独立进入既有核验/候选/合并恢复链；暂仅支持与应用数据根相同 mount 的新目标。清理回执查看与保留策略、整工作区恢复仍待实施。没有重新拉取，下方 macOS 源码基线保留。

2026-10-07 P54 增量：[最新恢复历史清理](p54-knowledge-restore-cleanup.md)已补不可撤销确认、最新历史容量回收、简短审计回执与中断显式继续；保留当前库及活动终态恢复证据。下一批可补历史导入与回执保留策略，外部附件闭合和整工作区恢复仍待实施。没有重新拉取，下方源码基线保留。

2026-10-07 P53 增量：[终态恢复事务归档](p53-knowledge-restore-archive.md)已补确认式活动槽释放、最多 4 份私有历史及已知中断状态的显式继续；全部快照与原日志保留，下一批建议 P54 磁盘清理与历史容量回收。没有重新拉取。

2026-10-07 增量：[P52 资料库安装事务与显式恢复](p52-knowledge-restore-install.md)已补持久意图、私有完整副本、原子交换和单独确认的完成/取消/回滚；下一批建议终态快照容量管理。没有重新拉取，下方 macOS 源码比较基线保留。

2026-10-05 增量记录：[P51 合并清单投影与隐私重置确认](p51-knowledge-merge-projection.md)已补内存合并与一次性复验；未执行安装，下一批建议 P52 安装事务与崩溃回滚。以下源码比较基线保留，没有重新拉取。

最新 macOS 公开源码已下载到本地，`origin/main` 更新为 `2d2858fc5ebc3843d1a281026304c2551741691c`，提交时间为 2026-09-30 19:51:05 +0800。相对 [上次对照](macos-linux-comparison-2026-09-26.md) 的 `6857545bdca00884593193175cffb654cc092a22` 新增 7 个提交。Linux 远端仍为 `97f1fd75e12b4b9606974890bfa317a7bac9b6e3`，本地 HEAD 与它一致；本次 Linux 能力判断包含当前未提交工作区。

Linux 已覆盖主要写作、资料、RSS、AI 和受保护的 Git 发布路径。距离完整 macOS 行为对齐，主要还差完整发布证据与恢复、工作区备份和跨端交换、独立笔记、完整站点配置、预览与同步高级能力，以及真实 Linux 发行验收。旧 Agent 等已退役功能应从追平目标中移除。

同日后续已实施 [P34 统一只读发布台账](p34-release-ledger.md)：聚合 P31/P32 本地证据、复验当前目标并展示部分来源；手动部署观察保持未归因。随后 [P35 基础回滚资格审阅](p35-rollback-qualification.md)接通本地单父提交/根树检查及确认式只读远端头查询；[P36 单提交逆向预览](p36-rollback-change-preview.md)补上变化路径、两端对象核验和部分结果提示。下表和顺序已更新实施状态；文末原源码复核的验证结果保留，后续门禁见阶段文档。随后 [P37 本地逆向提交候选](p37-local-rollback-candidate.md)补上完整的有界目标树、一次性计划和临时构建验证；[P38 确认式远端逆向追加](p38-rollback-transaction.md)已补冻结远端头、精确条件更新、持久未知证据和只读恢复查询；[P39 统一恢复历史与本地诊断](p39-rollback-history-diagnostics.md)已把恢复事务纳入时间线，增加容量、已知分支未决和本地目标变化诊断；[P40 本地恢复证据归档](p40-rollback-evidence-archive.md)已补当前仓库私有 JSON 的范围预览、隐私确认、一次性复验和不可覆盖写入；仍不清理/解锁/恢复导入台账，随后 [P41 工作区备份预检](p41-workspace-backup-preflight.md)已接通设置中心七类只读元数据清单、敏感范围排除与短时重新核对；随后 [P42 配置备份导出](p42-workspace-config-backup.md)已补工作区/站点/AI 三类 JSON 的严格校验和确认式私有导出；随后 [P43 RSS 单库快照](p43-rss-snapshot-backup.md)已补 WAL 一致采集、正文/笔记/全文与翻译缓存/撤销记录的确认式 SQLite 导出；随后 [P44 草稿数据库快照](p44-draft-snapshot-backup.md)已补普通草稿或跨仓库历史/回收正文的单库预览、内容/引用核验与确认导出；随后 [P45 资料引用预检](p45-knowledge-reference-integrity.md)已补保存正文/归档的全历史引用核验和有界部分结果；随后 [P46 资料保存文件备份包](p46-knowledge-saved-package-backup.md)已补保存引用范围的严格采集、排除操作回执和确认式私有不可覆盖 JSON 导出；随后 [P47 独立资料包校验与内存隔离预检](p47-knowledge-package-check.md)已补不可信包严格解析、摘要/引用闭合及一次性来源复验和临时内存解码；随后 [P48 私有磁盘候选](p48-knowledge-package-stage.md)已补显式父目录/来源预览、敏感明文同意、私有一次性复制与完整读回；随后 [P49 候选独立复验与清单冲突预览](p49-knowledge-candidate-check.md)已补只读候选布局/引用/内容检查和当前保存清单的冲突汇总；整工作区、多库原子快照、当前资源/恢复资格、一般恢复和迁移仍待补齐。

## 源码更新与比较范围

执行了以下引用更新。下载对象和更新远端引用后，继续保留现有 Linux 分支及本地改动，没有把 macOS 主线合并进工作区。

```sh
git fetch origin refs/heads/main:refs/remotes/origin/main refs/heads/codex/linux-tauri-mvp:refs/remotes/origin/codex/linux-tauri-mvp
```

| 新提交 | 提交日期 | 远端提交说明 |
| --- | --- | --- |
| `1892650` | 2026-09-26 | Sync RepoPress public source from da172759 |
| `83b1cdd` | 2026-09-26 | Update RepoPress Studio public source snapshot |
| `bc19757` | 2026-09-27 | Sync reviewed public snapshot from bd34de2a |
| `afe7d3a` | 2026-09-27 | Sync completed RepoPress Studio changes from d971ce10 |
| `37c1d08` | 2026-09-28 | Sync RepoPress Studio improvements from b5e5d9f7 |
| `362f010` | 2026-09-29 | Sync workspace safety, preview fixes and legacy cleanup |
| `2d2858f` | 2026-09-30 | Sync publishing safeguards and writing workflow fixes |

这 7 个提交涉及 1,089 个文件，包含模块迁移、共享源码、测试、翻译资源和产品收缩，文件数不能换算成 Linux 功能完成率。macOS 依据固定 SHA 的源码读取；Linux 依据实际 UI、Gateway、Tauri 注册和 Rust core，不把当前分支中的旧 Swift 文件当作最新主线。

## 本次需要修正的追平目标

| 最新 macOS 变化 | 对 Linux 计划的影响 |
| --- | --- |
| 旧 Agent 循环已退役，旧记录只供查看 | 不再移植旧 Agent 模式或外部工具循环。保留的写作 AI、站点风格和确认式自动化需按当前入口分别核对。 |
| 工具栏自定义改为固定高频项和插入/格式菜单 | Linux 不再需要补旧 macOS 自定义工具栏；后续对齐响应式分组，并保留或迁移 Linux 既有偏好。 |
| 应用内语言覆盖设置已撤下，启动时清理旧语言配置 | Linux 仍需系统语言下的中文/英文资源；旧 macOS 手动语言切换界面不再是追平要求。 |
| 隐私设置收缩为私密内容遮挡 | 补齐列表、搜索和概览中的遮挡及无障碍输出规则；不沿用旧快速隐藏和自动离席锁定待办。遮挡不代表本地加密。 |
| 发布和恢复模块继续拆分 | `LocalGitPublishService` 等旧文件删除不能解读为发布能力消失；统一 `ReleaseLedger`、部署状态和回滚仍需对照。 |
| 预览增加执行身份与具体页面就绪校验 | Linux 已有可信仓库确认，但仍需冻结配置后复验，并确认文章页面实际返回成功；端口可连接不足以证明页面就绪。 |
| 共享源码快照改为 `Shared/RepoPressCoreContracts/swift` | 对齐最新输入输出和 golden fixtures，再为 TypeScript/Rust 增加适配验证。新快照不表示 macOS SwiftUI 应用可以直接运行在 Linux。 |
| macOS 增加 Share Sheet 和 Shortcuts 资料入口 | Linux 可设计文件关联、拖放或桌面分享入口；Apple 扩展、entitlements 和 CloudKit 需要平台替代设计。 |

此前已经从主线撤下的建站向导、浏览器扩展、外部 MCP 客户端和应用内模型下载，继续不列为 Linux 追平要求。Linux 现有浏览器采集能力可以保留，其后续维护属于 Linux 产品自己的范围。

## Linux 当前状态与待补工作

“部分”表示已有可用基础，待补列才是差距；“缺失”只针对该行具体行为。“待验收”表示代码或脚本已存在，但本轮没有相应环境证据。

| 模块 | Linux 当前状态 | 仍需要做什么 |
| --- | --- | --- |
| 统一发布台账与恢复审阅 | 部分：P34 本地台账、P35 基础资格观察、P36 逆向路径/对象预览、P37 有界完整目标树/临时候选、P38 确认式单冻结提交追加/持久恢复证据、P39 恢复历史/容量/未决诊断及 P40 确认式私有证据归档已接通，未归因部署观察单独展示 | 补完整逐文件发布审阅、整次多提交推送恢复、超出 P37 有界普通文件范围的恢复完整性、一般冲突验证、精确部署关联、合并观察、超出 P38 范围的回滚和撤回执行。已核实推送、PR/MR 或完整逆向预览不代表合并、部署、上线或可执行回滚。 |
| 文章下线 | 部分：P33 只读引用影响审阅、来源复核和定位 | 补路由和复杂引用覆盖、后端执行前复验、下线或删除 PR/MR、失败恢复及清理事务。零引用和只读报告不能授权删除。 |
| 安全退出与恢复 | 部分：P30 当前文章冻结、读回复核和恢复包 | 扩展至全工作区待写入状态、附件和后台任务；提供恢复冲突选择、逐阶段失败说明以及真实桌面关闭验收。 |
| 工作区备份恢复 | 部分：P41 七类预检、P42 已保存配置的确认导出、P43 RSS 与 P44 草稿/历史的单库一致性 SQLite 快照、P45 保存资料引用预检、P46 保存文件包导出、P47 严格包校验/内存预检、P48 私有磁盘候选、P49 候选独立复验/清单冲突预览 | P50 已补当前资源核验/只读资格策略证据；P51 已补内存投影/隐私重置确认；P52 已补本地单资料库安装、回滚与中断恢复；P53 已补活动恢复事务槽释放；P54 已补最新完整历史清理、简短回执与容量回收。P55 已补兼容现有合并恢复的历史包导出。待补回执保留策略、外部附件闭合、多库原子备份与整工作区恢复。P41 不证明内容正确；P42/P43/P44/P46 是独立导出，P48 是非原子候选复制，P49 是只读候选核验和当前清单比较，不验证当前资源，未提供恢复。 |
| 跨端工作区交换 | 缺失 | 对齐站点摘要、草稿和附件交换格式，保留未知元数据；预览冲突、验证路径和附件，确认后事务导入。它与全备份、笔记包是不同协议。 |
| 独立笔记与笔记包 | 缺失 | 笔记编辑、归档、附件和 `.rpnotes` 导入导出；验证清单、校验和、重复身份及冲突副本。通用资料或 Markdown 导出不能替代笔记协议。 |
| 真实站点预览 | 部分：Hugo/Zola 已接通 | 加执行计划指纹与变更失效、文章页面 HTTP 就绪和诊断；按独立批次补 Astro/Hexo/Jekyll、Quartz 静态快照等站点支持。 |
| 多站点完整配置 | 部分：P21 命名登记和受保护切换 | 内容/资源路径、默认作者分类、站点发布配置、配置复制和专属草稿归属；站点 AI 配置单独绑定共享连接。 |
| Git 同步与冲突 | 部分：已有 fetch、提交、push、选择性暂存和重试 | 补安全同步计划、merge/rebase 冲突处理、取消、中断恢复；执行前绑定仓库、HEAD、index/worktree 和远端状态。 |
| AI 连接与能力 | 部分：P29 模型列表、小型文本探测已收尾 | 补流式、结构化输出等能力证据与失效状态；连接成功不能直接等同于全部能力可用。需要真实服务验收。 |
| 站点写作 AI | 部分：选区编辑、流式对话、服务档案已有 | 站点范例和风格/术语规则、发送内容预览、来源复验、逐字段元数据接受、维护队列暂停重试与取消；补 AI 模板库，复用既有计划、审阅和应用链路。按当前写作工具范围实现，排除已退役 Agent。 |
| 本地引擎与 Codex | 部分：可使用已配置 Ollama | 补引擎发现和准备引导、Codex 运行时与账户连接、任务状态及取消。应用内模型下载不在本轮目标。 |
| 工作台与编辑器 | 部分：搜索定位、大纲、替换审阅、基础 SEO 已有 | 命令面板跨正文/资料/RSS 搜索、持续写作目标、模块可见性、独立窗口状态；常驻状态栏整合保存、诊断和统计；原始 Front Matter 折叠、完整 SEO/社交预览、作者和复杂元数据适配。 |
| 图片和附件 | 部分：P19/P22/P26 浏览、复用、引用诊断和单处修复 | 跨文章引用修复、封面/附件语义、压缩/WebP/裁剪、隐私元数据清理；移动删除须独立计划与撤销。 |
| 资料库与 RSS | 部分：导入、阅读、分类、资料版本、语义搜索和正文翻译已有 | 资料集合、批注、来源关系、笔记协作；RSS 列表标题翻译的有界批次、缓存、取消及仅发送标题的确认。Apple Translation/CloudKit 需 Linux 替代方案。 |
| 内容维护与日志 | 部分：确定性检查和 P20 本机日志 | 审阅式修复队列、业务历史投影、发布关联、AI/RSS 等事件及保留策略；明确扫描遗漏和过期状态。 |
| 隐私与界面语言 | 缺失对应完整 UI | 私密摘要、正文、路径的列表/搜索遮挡及无障碍规则；系统语言选择下的中文/英文资源和回退。当前界面大量中文常量需要本地化。 |
| 更新与桌面发行 | 待配置及目标环境验收 | 配置生产更新 endpoint、公钥和受保护签名链路，验证同一 AppImage 更新；`.deb` 通过包管理升级。完成 GNOME/KDE、X11/Wayland、HiDPI、中文输入法和 AT-SPI 真实矩阵。 |

## 建议实施顺序与验收范围

以下是更新后的实施顺序，P34–P53 已完成各自的有界范围；其他建议尚未实施，没有执行真实发布。

1. **发布恢复：P34–P40 已实施；P41 预检与 P42 配置导出已完成，P43 RSS 与 P44 草稿/历史单库快照已完成，P45 保存资料引用预检已完成，P46 保存资料包导出与 P47 独立包校验/内存隔离预检已完成，P48 私有磁盘候选已完成，P49 候选独立只读复验/清单冲突预览已完成，P50 已补当前资源核验和只读资格/策略证据，P51 已补内存合并投影与权限重置确认，P52 已补本地单资料库安装事务与显式恢复，P53 已补终态归档与活动槽释放，P54 已补最新完整历史的确认式清理与容量回收，P55 已补历史快照资料包导出和既有合并恢复链兼容；下一批建议清理回执查看与确认式保留策略。** P34 汇总 P31/P32 并保留未知/部分来源；P35 提供基础条件审阅与确认式远端头查询；P36 只读核验单个冻结提交的逆向变化对象，不证明整次推送恢复或无冲突。实现及验收见 [P34](p34-release-ledger.md) / [P35](p35-rollback-qualification.md) / [P36](p36-rollback-change-preview.md)。[P37](p37-local-rollback-candidate.md)已补上有界完整目标树核验、短时计划和临时候选构建/清理。[P38](p38-rollback-transaction.md)已接通明确准备/确认、精确预期头条件更新、写请求前持久意图及重启后的只读恢复查询。[P39](p39-rollback-history-diagnostics.md)已整合恢复业务历史和容量/已知目标未决诊断，历史首证据与最新观察独立保留；[P40](p40-rollback-evidence-archive.md)已实现保留台账的确认式私有 JSON 归档；台账修复/容量回收/恢复导入、一般冲突、多提交恢复及真实远端验收仍未完成。
2. **补数据恢复与迁移。** [P41](p41-workspace-backup-preflight.md)已明确七类元数据范围与敏感排除，[P42](p42-workspace-config-backup.md)已补所选已保存配置的校验与确认导出；[P43](p43-rss-snapshot-backup.md)已补 RSS 单库一致快照，[P44](p44-draft-snapshot-backup.md)已补普通草稿/历史各自快照，[P45](p45-knowledge-reference-integrity.md)已补清单到全部已保存历史正文/归档的引用预检，[P46](p46-knowledge-saved-package-backup.md)已补保存引用范围内的资料包导出，[P47](p47-knowledge-package-check.md)已补严格独立包校验与只读内存隔离预检；[P48](p48-knowledge-package-stage.md)已补确认式私有磁盘候选，[P49](p49-knowledge-candidate-check.md)已补候选独立复验/清单冲突预览，P50 已补当前资源/身份策略资格证据，P51 已补内存合并投影与隐私重置确认，P52 已补单资料库确认安装与显式恢复；P53 已补终态归档及活动槽释放；接着补归档磁盘清理与历史容量回收、外部附件闭合，然后做多库工作区交换与笔记包。这些独立导出分别定义格式；未知版本、损坏附件、路径穿越、符号链接、目标变化和恢复中断必须有明确结果，凭据不得进入导出。
3. **加强预览与同步。** 先在既有 Hugo/Zola 流程增加执行身份复验和具体页面就绪，再逐种站点扩展；Git 先做只读同步/冲突计划，再加可取消的执行与恢复。
4. **补高频写作流程。** 工作台模块显隐、统一搜索和 RSS 标题翻译可以独立推进；隐藏模块时回退写作区，导航、命令与后台刷新保持一致。标题翻译只发送标题，失败保留原题，本机后端与远程 AI 授权分开处理。站点配置、站点风格、Codex 文本连接和 AI 模板先稳定共享合同，再接 UI。用最新 golden fixtures 防止 Front Matter、端点和差异算法跨端漂移。
5. **扩展图片、隐私和窗口体验。** 图片处理和跨文章修复分别验收；隐私遮挡覆盖视觉与辅助技术；多窗口使用独立文稿会话，不能共享一个可被覆盖的缓冲区。
6. **并行收集 Linux 发行证据。** 准备签名候选并验证更新，按 [Linux 发行验收合同](linux-release-acceptance.md) 用同一产物完成五个环境的启动、中文输入、候选窗与无障碍检查。UI、凭据、Portal 和打包采用 Linux 平台实现。

架构继续使用 `Apps/RepoPressDesktop` 的 Tauri 2、React/TypeScript、CodeMirror 与 Rust。通过固定输入输出和测试样例共享行为，不直接搬运 SwiftUI/AppKit 窗口。并行实施时，Gateway、contracts、Rust 注册和 `AppState` 等共享文件由一个集成线程拥有，避免重叠修改。

## 固定源码依据

| 范围 | macOS 最新固定源码 | Linux 当前依据 |
| --- | --- | --- |
| 发布台账 | [ReleaseLedgerService](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift) | [发布中心](../src/components/PublishCenter.tsx)、[Git 台账](../src-tauri/src/core/publish_ledger.rs)、[PR/MR 台账](../src-tauri/src/core/remote_review_ledger.rs)、[Tauri 注册](../src-tauri/src/lib.rs) |
| 全工作区备份和交换 | [备份清单](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingBackupCore/Models/WorkspaceBackupModels.swift)、[交换合同](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingBackupCore/Models/WorkspaceExchangeModels.swift) | [Gateway 合同](../src/contracts/repository.ts)、[P41 元数据预检](../src-tauri/src/core/workspace_backup.rs)、[P42 配置导出](../src-tauri/src/core/workspace_config_backup.rs)、[P43 RSS 快照](../src-tauri/src/core/rss_snapshot_backup.rs)、[P44 草稿快照](../src-tauri/src/core/draft_snapshot_backup.rs)、[P45 资料引用](../src-tauri/src/core/knowledge_integrity.rs)、[P46 保存资料包](../src-tauri/src/core/knowledge_backup.rs)、[RSS 备份](../src-tauri/src/core/rss.rs)；没有整工作区导出/恢复或交换命令 |
| 笔记与知识库恢复 | [笔记包 codec](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingKnowledgeCore/Services/RPNotesPackageCodec.swift)、[整库恢复](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingKnowledgeCore/Services/KnowledgeLibraryBackupService%2BRestore.swift) | [资料库 UI](../src/components/KnowledgeLibrary.tsx)、[core](../src-tauri/src/core/knowledge_library.rs)；现有条目导出不是整库事务恢复 |
| AI 新入口 | [站点 AI 设置](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PersonalSitePublisherMac/Views/Settings/AISiteSettingsView.swift)、[Codex runtime](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingAICore/Models/CodexManagedRuntime.swift)、[模板库](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PersonalSitePublisherMac/Views/Editor/AIPublishingTemplateLibraryView.swift) | [选区 AI](../src/components/AIAssistant.tsx)、[连续对话](../src/components/AIChatPanel.tsx)、[站点登记](../src-tauri/src/core/site_profiles.rs) |
| RSS 译题与模块显隐 | [标题翻译](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PersonalSitePublisherMac/Support/RSSListTitleTranslationController.swift)、[模块可见性](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PersonalSitePublisherMac/Support/WorkspaceModuleVisibility.swift) | [RSS UI](../src/components/RssReader.tsx)、[工作区状态](../src-tauri/src/core/workspace_state.rs) |
| 当前文章恢复和下线审阅 | macOS 工作台退出、恢复及发布流程 | [P30](p30-editor-safe-exit.md)、[退出实现](../src-tauri/src/core/editor_exit.rs)、[P33](p33-unpublish-impact.md)、[引用审阅](../src/components/UnpublishImpactPanel.tsx) |
| 预览合同 | [执行计划](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingPreviewCore/Models/LocalSitePreviewPlan.swift)、[授权复验](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingWorkbenchCore/Services/LocalSitePreviewService.swift#L364)、[具体页面就绪](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingPreviewCore/Services/LocalSitePreviewPageReadinessService.swift#L22) | [UI](../src/components/SitePreview.tsx)、[Gateway](../src/platform/repositoryGateway.ts)、[core](../src-tauri/src/core/site_preview.rs) |
| 共享行为 | [Swift 快照](https://github.com/lldynamics/RepoPress-Studio-Public/tree/2d2858fc5ebc3843d1a281026304c2551741691c/Shared/RepoPressCoreContracts/swift)、[40 个 golden cases 清单](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Shared/RepoPressCoreContracts/swift/contracts/fixtures/v1/manifest.json) | [Front Matter](../src/features/frontmatter/frontMatter.ts)、[批量元数据](../src-tauri/src/core/metadata_batch.rs)、[远端评审](../src-tauri/src/core/remote_publish.rs)；尚未接入最新清单的统一消费门禁 |
| 退役范围 | [旧 Agent](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingWorkbenchCore/Models/AIAgentRetirement.swift)、[旧语言配置清理](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PersonalSitePublisherMac/Support/LegacyAppLanguageCleanup.swift) | 更新后的本次目标清单 |
| 私密内容遮挡 | [隐私模型](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift#L134)、[搜索遮挡](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingWorkbenchCore/Stores/PrivacyProtectionStore.swift#L33) | [命令面板](../src/components/WorkspaceCommandPalette.tsx)、[设置](../src/components/SettingsCenter.tsx)、[App](../src/App.tsx) |
| 更新和发行 | 平台各自的发行合同 | [Tauri 配置](../src-tauri/tauri.conf.json)、[发行验收](linux-release-acceptance.md) |

## 初次源码复核的验证与未验收范围

| 检查 | 本轮结果 |
| --- | --- |
| `npm test -- --run` | 99 个文件、643 项通过。 |
| `npm run build` | TypeScript 和 Vite 生产构建通过；仍有部分压缩块超过 500 kB 的提示。 |
| `npm run check:bundle` | 通过；首屏 JavaScript 523.1 KiB、9 个懒加载块。 |
| `npm run check:version` | 通过；0.1.0 一致。 |
| `cargo test --offline --manifest-path src-tauri/Cargo.toml` | 受限环境下 386 项中 381 通过，5 项在初始化本机回环监听时因权限限制失败。 |
| 本机回环专项复验 | 允许本机回环后，AI 连接和浏览器采集共 22 项全部通过，包含原先失败的全部 5 项。不是重新执行一次完整 Rust 套件。 |
| 源码和文档检查 | 固定源码链接及本地链接验证通过，`git diff --check` 通过。开始时记录了 385 个已修改/未跟踪文件的哈希；本轮只更新其中两份文档索引，其他 383 个文件逐字节保持一致，另新增本报告。 |

本轮未运行 macOS 应用、真实 AI/GitHub/GitLab 发布、真实签名更新或完整桌面矩阵，也未重跑 Clippy/fmt 或打包。因此结论是源码合同与本地测试层面的能力对照，不是两平台运行时全部对齐。更新配置当前仍为 `endpoints: []`、`pubkey: ""`，普通本地包不能据此宣称具备生产更新能力。
