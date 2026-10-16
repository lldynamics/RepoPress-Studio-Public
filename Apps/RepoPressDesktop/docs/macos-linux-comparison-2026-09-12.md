# 最新 macOS 与 Linux 差异复核 · 2026-09-12

远端最新主线已下载并单独检出；当前 Linux 实现及未提交修改保留。Linux 核心写作、搜索、RSS、AI、Git 基础操作和 P19–P22 仍有对应实现；新版最值得补齐的是编辑器导航、批量标签/分类、图片引用修复、发布恢复及保存冲突处理。旧路线中的预览提升和结构修复已不属于当前主线实现。

## 拉取结果与比较基线

| 项目 | 本次核实结果 |
| --- | --- |
| 远端 | `https://github.com/lldynamics/RepoPress-Studio-Public.git`；实时查询默认分支为 `main` |
| 最新主线 | `58d1cf336644a993ef4a7c1d94cc0180e230c4f8`，2026-09-09 01:22:22 +0800，`chore: publish RepoPress Studio snapshot from 37d36be1` |
| 本地参考副本 | `/tmp/repopress-main-20260912-58d1cf3`，独立 detached worktree；`origin/main` 同时保存在原仓库 |
| 当前 Linux | `/home/cli/Projects/RepoPress`，`codex/linux-tauri-mvp`，HEAD `97f1fd75e12b4b9606974890bfa317a7bac9b6e3`；对照包含当前未提交的实现 |
| Linux 远端更新 | fetch 后当前 HEAD 与上游分支左右差距为 `0 / 0`，该分支没有新提交 |
| 应用方式 | 已 fetch 主线并本地检出；未把 `main` 合并进 Linux 工作分支，未提交、推送或清理现有修改 |

原克隆为浅克隆，并只配置获取 Linux 分支。单独运行普通 fetch 会漏掉主线，因此本次显式获取了 `main`。最新主线 [README](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/README.md) 明确定位 macOS 产品仓库，该快照不含 `Apps/RepoPressDesktop`；不能直接用它覆盖当前 Linux 工作区。

旧 Linux HEAD 与最新 main 的两个提交快照共有 **735 个文件差异**（新增 151、修改 369、删除 207、重命名 8；48,401 行增加、53,939 行删除）。这些数值包含分支内容、模块迁移和打包/测试变化，既不是新增功能数量，也不是当前未提交 Linux 代码的差异总量；没有据浅克隆推断提交演进距离。

## 最新主线新增或变化的重点

“新增”表示相对旧 `97f1fd7` 快照出现了对应文件，并结合当前调用入口确认能力；不据此断言整个产品概念首次出现。

| 能力 | 最新 macOS | 当前 Linux 与实际缺口 |
| --- | --- | --- |
| 编辑器和工作台导航 | `ContentView` 路由文稿、字段、正文范围及 Inspector；新增紧凑导航栏，支持窗口上下文 | 有工作区、文件树、命令面板和独立抽屉；缺跨模块统一定位协议和多窗口上下文。先收口单窗口导航即可，不必把多窗口作为首批前提。 |
| 搜索、替换、大纲 | 搜索命中可定位编辑范围；查找替换支持选区/正文范围及全部替换预览；大纲支持固定、折叠和活动章节 | **已有跨文档路径/正文搜索**，但结果点击只传文件，未传命中范围；有基础查找替换和章节操作，缺替换预览与大纲固定/跟随。 |
| 批量标签/分类 | 新增 `MetadataBatchMaintenanceService` 和编辑器面板，支持添加、移除、重命名、预览和逐篇应用 | 现有 `FrontMatterPanel` 只编辑当前文稿。缺跨文稿计划、逐篇基线复验与结果汇总。此功能限定 `tags/categories`，不是图片 EXIF 或任意元数据批改。 |
| 图片坏引用修复 | 新增 `AssetReferenceRepairService` 及 Store；资源管理器接入替换选择、预览与过期校验 | P19/P22 已有图片浏览、预览、插入和引用/Alt 报告；没有替换计划或确认写回。应从只读结果进入可审阅修复，继续保护旧缓冲和磁盘版本。 |
| 整工作树发布与重试 | 新增 transition coordinator、push retry 和逐文件 review 服务，管理 Git 事务 journal、审阅证据及安全重试 | 现有暂存、提交、fetch、push 有一次性计划与状态复验；缺跨重启事务恢复、专门的“已提交未推送”恢复状态和逐文件审阅完整性闸门。已有 diff 查看不能替代后者。 |
| 远端确认与发布记录 | 新增远端新鲜度 actions、工作树 release recording；远端 SHA 确认后记发布记录 | P20 记录本机命令结果，尚无经远端确认的 release ledger。provider API 文件级冲突预检属于 macOS 另一条发布路径，需要独立定义 Linux 范围。 |
| 保存冲突、安全退出 | 新增项目文件冲突服务和安全退出持久化流程；编辑器接入冲突/恢复面板 | 已拒绝覆盖磁盘外部变更，有恢复稿与历史版本；缺专门冲突审阅、多条恢复记录选择，以及退出前统一刷缓冲/持久化操作状态。 |

主要代码证据：

- 导航：macOS [ContentView](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/Sources/PersonalSitePublisherMac/Views/Workspace/ContentView.swift#L945)；Linux [搜索结果点击](../src/components/FileNavigator.tsx#L80) 与 [工作台接线](../src/App.tsx#L1201)。
- 元数据：macOS [MetadataBatchMaintenanceService](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/Sources/PublishingWorkbenchCore/Services/MetadataBatchMaintenanceService.swift#L6)、[维护面板](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/Sources/PersonalSitePublisherMac/Views/Editor/MetadataBatchMaintenancePanel.swift#L49)；Linux [FrontMatterPanel](../src/components/FrontMatterPanel.tsx)。
- 图片：macOS [AssetReferenceRepair Store](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/Sources/PublishingWorkbenchCore/Stores/WorkbenchStore%2BAssetReferenceRepair.swift#L16)；Linux [引用检查入口](../src/components/ImageReferenceCheckPanel.tsx) 与 [结果面板](../src/components/ImageReferenceReport.tsx)。
- Git：macOS [事务恢复](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/Sources/PublishingWorkbenchCore/Services/RepositoryWorktreePublishTransitionCoordinator.swift#L60)、[推送重试](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/Sources/PublishingWorkbenchCore/Services/RepositoryWorktreePushRetryService.swift#L31)；Linux [Git 操作执行](../src-tauri/src/core/git_publish.rs#L305)、[发布中心](../src/components/PublishCenter.tsx#L81)。
- 退出：macOS [SafeTermination](https://github.com/lldynamics/RepoPress-Studio-Public/blob/58d1cf336644a993ef4a7c1d94cc0180e230c4f8/Sources/PublishingWorkbenchCore/Stores/WorkbenchStore%2BSafeTermination.swift#L21)；Linux [保存冲突处理](../src/App.tsx#L1026)。

## 仍然存在的差距与已覆盖路径

| 范围 | 本次结论 |
| --- | --- |
| PR/MR | Linux 已能创建；macOS 现有按源/目标分支找回远端评审的恢复和状态追踪仍缺。网络结果不明后重新创建可能重复，不能把“请求失败”当作“远端未创建”。 |
| 图片处理 | 压缩、格式转换、裁剪、隐私元数据清理及恢复是既有缺口；本次不能把 P22 只读引用检查算成这些处理功能。 |
| RSS | 全文提取/重试、原文与翻译展示、保存到资料库、插入当前稿件都已接线；本次未发现需要整块重做的依据。阅读状态保护仅作源码核对，未重新进行故障注入验证。 |
| AI 与知识上下文 | Linux 有显式资料选择、远程 AI 权限过滤和发送计划；缺同等来源分组/引用摘要、资料推荐交互。完整 Agent/MCP 工具执行仍属后续范围，主线仍包含 `PublishingMCPClient`。 |
| 多站点 | P21 是命名本地仓库登记和受保护切换，尚非完整 SiteProfile。站点配置、复制和草稿归属仍需补齐；SiteProfile 模型本身不是本次快照新增。 |
| 高级工作流 | 安全 rebase/冲突处理、全工作区备份/迁移、建站模板、资料库高级组织及更完整的操作日志仍在清单中。 |
| Linux 原生体验 | 原生菜单/窗口、输入法、HiDPI、GNOME/KDE、X11/Wayland 和无障碍支持仍须目标环境验收；源码相似不构成像素或系统集成一致性的证据。 |

## 从旧计划中移除的目标

最新 main 不再包含 `PreviewPromotionPlan`、`PreviewPromotionFrontMatterPolicy`、`RemoteRepositoryPublishService+PreviewPromotion` 及对应 Store，也不再包含 `StructuralDraftRepairService`、对应模型与 Store。旧清单中的“预览提升”“结构修复”不再作为新版对齐目标；发布历史依据更新为现存的 `ReleaseHistoryDetailView` 和 `ReleaseLedgerService`。

该结论只说明当前快照及对齐范围，不推断维护者移除原因，也不意味着所有内容健康修复都已移除。批量标签/分类与图片引用修复是当前仍有明确入口的独立能力。

## 下一阶段建议

1. **优先补导航与编辑器定位**：搜索命中保留行/范围、发布问题定位相应文稿/字段、统一 Inspector 路由。再单独增加选区替换预览和固定大纲。
2. **批量标签/分类**：把字段和目标文稿冻结进预览计划，确认时逐篇复验，显示冲突/失败结果，保留正文及其他 Front Matter。
3. **图片引用修复**：复用 P22 检查入口，增加替换预览与确认；扫描未匹配不直接等同于文件不存在，不能据此删除资源。
4. **Git 恢复**：先只读识别已提交未推送，再做确认后的非强制重试和远端 SHA 核实；整工作树事务、发布台账和安全退出另拆批次。

后续可继续采用主线程负责协议、状态边界及最终验收，前后端按文件分工，并行安排独立只读审阅。本次仅拉取、三路源码复核和更新文档，没有开始新功能实施。

## 验证边界

核实了远端默认分支、两个分支 SHA、独立检出位置、端点差异和关键 UI → Store/服务、React → gateway/后端接线。检查了原有修改文件的 SHA-256 保留情况和文档差异格式。此次没有重新编译运行两平台，也没有重跑历史测试或比较原生窗口截图；P19–P22 文档中的测试数字仍是原批次记录。
