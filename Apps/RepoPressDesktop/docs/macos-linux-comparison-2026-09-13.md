# macOS → Linux 差异复核 · 2026-09-13

本次执行 `git fetch origin main` 成功，远端主线仍为 `6abd42a8bbf4254961498c359cd7e9ef037f2fe7`（2026-09-12 12:17:05 +0800）；相对上次固定基线没有新提交。Linux 依据 `codex/linux-tauri-mvp` 的当前工作区，包括未提交的 P19–P28，不能只拿分支提交 `97f1fd7` 比较。

本轮由主线程核对 AI、设置与总体清单，两路只读审阅分别追踪 UI/内容与 Git/恢复的入口、Gateway、命令注册和实现。macOS 源码从固定主线读取，没有拿 Linux 分支的旧 Swift 快照作参考。本表是功能及 UI 流程差异，不是两平台原生窗口的像素验收，也不是所有菜单项的逐项穷举。

## 本次确认已经接通的近期增量

| 批次 | Linux 已有行为 | 范围边界 |
| --- | --- | --- |
| P23/P24 | 正文搜索/问题定位、属性字段定位、冻结选区查找替换预览、固定大纲 | 当前窗口与有界正文/元数据；不代表完整 SEO 或多窗口 |
| P25 | 最多 20 篇标签/分类添加、移除、单值重命名，预览确认、字段冲突复验、保存前历史 | 简单 Front Matter；不等于完整 YAML/TOML 或 AI 批量维护 |
| P26 | 当前文章单个可靠内联图片引用的替换预览、图片复验、确认后写入缓冲 | 不跨文章批改；不自动保存、搬迁或处理图片 |
| P27 | 保存冲突的基线/缓冲/磁盘三文本审阅，原稿备份并核对后载入合并缓冲 | 仍需普通保存；不是完整冲突恢复档案或安全退出 |
| P28 | 已提交未推送检测、冻结地址及 HEAD 的确认式非强制重试、精确远端 SHA 核验 | 当前会话计划；不是跨重启事务或完整发布审阅台账 |

这些项目应标为“核心流程已接通、部分对齐”，不应重新列为整个功能缺失。具体保护和验收边界见 [P25](p25-metadata-batch.md)、[P26–P28](p26-p28-safety-workflows.md)。

## 剩余清单

“部分”指已有相关基础，但右侧范围尚未对齐；“缺失”只指该行列出的高级功能，不否定同类基础功能。“待配置/验收”与源码缺失分开记录。编号用于引用，不表示已授权自动开始下一批。

| 编号 | 模块 | 当前状态 | 还需要完成 |
| --- | --- | --- | --- |
| 1 | AI 连接与模型选择 | 部分 | 从手填端点/模型、凭据检查推进到真实连接测试、分状态修复引导、模型发现和能力说明 |
| 2 | 本地 AI / Codex 连接准备 | 缺失准备流程 | 本地引擎发现与启动引导、模型下载/进度/取消；Codex 组件检测、准备与账户连接。已配置 Ollama 的使用能力保留 |
| 3 | 站点写作风格 | 缺失 | 同站点公开范例选择、受限发送预览、风格提取、术语/避免表达规则持久化、应用前来源复验 |
| 4 | AI 批量维护 | 缺失 | 摘要/标签/元数据建议队列，术语和内链审阅，暂停/重试与逐项来源复验；P25 确定性批改不覆盖此项 |
| 5 | 编辑器与多窗口 UI | 部分 | 原始 Front Matter 视觉折叠、更完整的 SEO/文章信息、按窗口文章列表状态、附件展示交互；TextKit 行为需按 Linux 技术栈重新设计 |
| 6 | 批量元数据扩展 | 部分（P25） | 复杂 YAML/TOML、缺失 Front Matter 的审阅式创建、多对多重命名、区域相关匹配；继续避免整篇重写 |
| 7 | 图片修复与资源处理 | 部分（P19/P22/P26） | 跨文章/多引用修复、引用式/HTML/模板、封面与附件模型；压缩、WebP 转换、裁剪、隐私元数据清理、移动/删除与撤销 |
| 8 | 保存恢复与安全退出 | 部分（P27） | 完整冲突恢复档案与恢复选择；退出前排空待保存任务、持久化并读回验证，失败时阻止退出和导出恢复包 |
| 9 | 发布审阅、恢复与台账 | 部分（P28） | 重试前逐文件 patch/图片审阅完整性、跨重启事务恢复、PR/MR 网络结果不明后的找回、远端确认的发布记录及台账 |
| 10 | Git 同步与冲突处理 | 缺失高级流程 | rebase/merge 的审阅与执行、冲突解决、取消和中断恢复；现有 fetch/push 不等于同步工作流 |
| 11 | 多站点完整配置 | 部分（P21） | 模板/内容/资源路径、默认作者分类、部署配置、配置复制、站点专属草稿归属和删除撤销 |
| 12 | 资料库与 RSS 写作协作 | 部分 | 跨资料/RSS 持续显示并切换写作目标；资料批注、集合、推荐、反向关联与来源说明。已有分类/版本/显式 AI 授权保留 |
| 13 | AI Agent / MCP | 缺失 | 工具目录、权限与逐次调用确认、执行/取消、结果呈现；现有选区 AI 和连续对话不覆盖工具执行 |
| 14 | 全工作区备份与迁移 | 缺失 | 资料/RSS/草稿/配置/附件等统一清单，排除凭据，校验后暂存恢复、事务与回滚；RSS 文本备份仅覆盖 RSS |
| 15 | 建站与内容维护 | 缺失/部分 | 建站目录预检、模板及文件预览、确认生成、部署引导；把只读内容健康报告逐步接到可审阅的修复队列 |
| 16 | 操作日志高级功能 | 部分（P20） | 业务历史投影、AI/MCP/RSS 等事件、发布记录关联、导出与保留策略；现有日志只是有界本地动作结果 |
| 17 | 快速隐藏与私密内容遮挡 | 缺失 UI 流程 | 工作台临时遮罩、私密内容掩码、相应快捷键和无障碍隐藏；macOS 此功能本身仅为界面遮挡，不等于加密或身份锁 |
| 18 | 界面语言 | 缺失 | 跟随系统、简体中文/英文选择，统一 UI/菜单文案及启动时应用；文章翻译不等于界面本地化 |
| 19 | Linux 更新发布配置 | 待配置/验收 | 签名 AppImage 更新代码已存在，但当前默认配置 endpoint 与公钥为空；需要实际发布配置与产物端到端验证，`.deb` 按包管理方式升级 |
| 20 | Linux 桌面发行验证 | 待目标环境验收 | 同一产物覆盖既定 Ubuntu 22.04/24.04、GNOME/KDE、X11/Wayland、1x/2x、IBus/Fcitx5、AT-SPI 五行风险矩阵 |

## 主要代码依据

- 编辑器、批改及图片：Linux [App](../src/App.tsx)、[MetadataBatchCenter](../src/components/MetadataBatchCenter.tsx)、[ImageWorkbench](../src/components/ImageWorkbench.tsx)；macOS `MacMarkdownComposerFindReplace`、`MarkdownFrontMatterFolding`、`MetadataBatchMaintenanceService`、`AssetReferenceRepairService`。
- 保存与推送：Linux [SaveConflictReview](../src/components/SaveConflictReview.tsx)、[GitPushRetryPanel](../src/components/GitPushRetryPanel.tsx)、[Git 发布命令](../src-tauri/src/commands/publish.rs)、[Git 发布核心](../src-tauri/src/core/git_publish.rs)；macOS `ProjectFileConflictService`、`WorkbenchStore+SafeTermination`、`RepositoryWorktreePushRetryService`、`RepositoryWorktreePublishTransitionCoordinator`、`ReleaseLedgerService`。Linux 重试计划为进程内状态，面板列路径而非逐文件 patch/图片的完整审阅。
- AI：Linux [AdvancedTools](../src/components/AdvancedTools.tsx) 挂载 [AIAssistant](../src/components/AIAssistant.tsx) 与 [AIChatPanel](../src/components/AIChatPanel.tsx)，模型仍手填；[IPC 合同](../src/contracts/repository.ts) 和 [Rust 注册](../src-tauri/src/lib.rs) 没有连接测试、模型发现、写作风格或 AI 批量维护链路。macOS 的 [连接准备 UI](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6abd42a8bbf4254961498c359cd7e9ef037f2fe7/Sources/PersonalSitePublisherMac/Views/Settings/AIConnectionSetupSection.swift)、[模型发现](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6abd42a8bbf4254961498c359cd7e9ef037f2fe7/Sources/PublishingWorkbenchCore/Services/AIModelDiscoveryService.swift)、`WorkbenchAIStore+WritingStyle` 与 `AIBatchMaintenancePanel` 有对应入口与动作。
- 站点和资料：Linux [SiteProfileCenter](../src/components/SiteProfileCenter.tsx)、[KnowledgeLibrary](../src/components/KnowledgeLibrary.tsx)、[RssReader](../src/components/RssReader.tsx)；macOS `SiteProfile`、`KnowledgeWritingContextView` 和 `Views/Knowledge/`。Linux 的站点登记不能当作完整 SiteProfile，当前稿件插入回调不能当作统一写作目标。
- 隐私与语言：macOS [PrivacySettingsView](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6abd42a8bbf4254961498c359cd7e9ef037f2fe7/Sources/PersonalSitePublisherMac/Views/Settings/PrivacySettingsView.swift) 经 `SettingsPrivacyTabFactory` 接入，`ContentView` 显示 `quickHideOverlay` 并隐藏对应无障碍内容；[AppLanguageSettingsView](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6abd42a8bbf4254961498c359cd7e9ef037f2fe7/Sources/PersonalSitePublisherMac/Views/Settings/AppLanguageSettingsView.swift) 经 `AppearanceSettingsView` 接入。Linux [设置](../src/components/SettingsCenter.tsx) 与工作区偏好尚无对应流程。
- 更新与发行：当前 [Tauri 配置](../src-tauri/tauri.conf.json) 默认更新公钥/端点未配置；[Linux 发行验收合同](linux-release-acceptance.md) 与验证脚本存在，不能据此推定真实环境已经验收。

未附链接的 macOS 文件名均在固定 `6abd42a` 的 `Sources/PersonalSitePublisherMac/` 或 `Sources/PublishingWorkbenchCore/` 下核对。这里列的是可执行工作包，不用跨平台文件差异行数或文件数量计算“完成百分比”。旧主线已移除的 PreviewPromotion / StructuralDraftRepair 仍不重新加入目标。

## 建议下一批

建议先做第 1 项“AI 连接测试与模型发现”，随后做第 3 项“站点写作风格”，再做第 4 项“AI 批量维护”。第 2 项安装/下载流程独立设计 Linux 来源与取消边界。保存安全退出、全工作区备份和图片高级处理保持独立批次，避免与发布或资源写入混合扩张范围。

## 本次验证边界

本轮完成远端刷新、源码和入口链路复核、历史验收文档核对。没有修改生产代码、执行批改/发布、合并主线、提交或推送，也没有重跑测试、构建或原生窗口矩阵。

最新既有批次记录为 P26–P28 的前端 87 文件/525 项、Rust 322 项及构建/Clippy 通过，详情见 [历史验收](p26-p28-safety-workflows.md#联合验收)。这些是之前的结果，不是本轮重新运行的结论。
