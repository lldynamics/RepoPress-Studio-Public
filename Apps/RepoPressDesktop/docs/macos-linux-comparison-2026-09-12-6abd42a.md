# macOS 与 Linux 最新对照 · 6abd42a

本轮已刷新远端 `main` 到 `6abd42a8bbf4254961498c359cd7e9ef037f2fe7`（2026-09-12 12:17:05 +0800，`feat: enhance AI setup, writing assistance, and editor workflows`）。Linux 依据 `codex/linux-tauri-mvp` 的 `97f1fd7` 加当前工作区实际实现。两个分支服务于不同平台；本次只更新远程引用，保留 Linux 工作区。

上一份 [58d1cf3 对照](macos-linux-comparison-2026-09-12.md)是历史记录。新主线相对它有 96 个文件变化，11,520 行增加、722 行删除，主要集中在 AI 配置、写作辅助和编辑体验。这些数字不是缺失功能数量。既有 P19–P23 已纳入本轮基线，不能再次当作待开发功能。

## 新主线带来的额外缺口

| 模块 | 当前 macOS 依据 | Linux 当前能力与待补内容 |
| --- | --- | --- |
| AI 配置与连接引导 | [AIConnectionSetupPresentation](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6abd42a8bbf4254961498c359cd7e9ef037f2fe7/Sources/PersonalSitePublisherMac/Views/Settings/AIConnectionSetupPresentation.swift)、`AIProviderSetupGuide`、`AIModelDiscoveryService` | Linux `AIAssistant` / `AIChatPanel` 已有服务类型、端点、模型手填、凭据和发送计划；还缺按连接状态给出的下一步引导、模型发现与模型能力说明。检查“凭据存在”不代表连接测试通过。 |
| 本地 AI 与 Codex 运行组件 | `LocalAIEngineSetupService`、`LocalAIModelDownloadService`、`CodexRuntimeSetupService` | Linux 已能使用配置好的本地 Ollama，但缺引擎发现/启动引导、模型下载和 Codex 组件准备流程。macOS 的 bundle identifier、Homebrew/AppKit 启动路径不能直接搬到 Linux；需单独设计 Linux 安装来源、权限与取消边界。 |
| 站点写作风格 | [AIWritingStyleProfileService](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6abd42a8bbf4254961498c359cd7e9ef037f2fe7/Sources/PublishingWorkbenchCore/Services/AIWritingStyleProfileService.swift)、`WorkbenchAIStore+WritingStyle` | 缺同站点公开文章范例选择、受限上下文、风格提取预览、术语与避免表达规则持久化、应用时来源复验。现有 AI 服务档案只配置服务，并非写作风格档案。 |
| AI 批量维护 | [AIBatchMaintenanceService](https://github.com/lldynamics/RepoPress-Studio-Public/blob/6abd42a8bbf4254961498c359cd7e9ef037f2fe7/Sources/PublishingWorkbenchCore/Services/AIBatchMaintenanceService.swift)、`AIBatchMaintenanceStore` / `AIBatchMaintenancePanel` | 缺摘要/标签建议队列、术语与内链审阅、取消重试及逐项来源复验。P25 的确定性标签/分类维护与远程 AI 批处理是两个不同范围。 |
| 资料写作目标 | `KnowledgeWritingContextView`，接入资料库与 RSS | Linux 可将 RSS 链接插入当前稿，资料也可显式选入 AI；还缺跨资料/RSS 表面持续展示并切换写作目标的统一入口。 |
| 编辑器与窗口 | `MarkdownFrontMatterFolding`、`MacMarkdownComposerArticleInformation`、`WritingListWindowPresentationState` | P23 已接通搜索/问题正文定位；P24 补选区替换预览、固定大纲和字段定位。原始 Front Matter 的视觉折叠、多窗口文章列表状态、原生附件叠层与 TextKit 几何行为仍有差距。属性面板折叠不等于编辑器原始元数据折叠。 |
| 建站与发布引导 | `SiteStarterDirectoryPreflightService`、`SiteStarterDeploymentLink`、`PublishDrawerConnectionPresentation` | Linux 已有仓库探测、受控预览和 Git 发布计划；还缺建站前目录检查界面、模板生成、部署引导，以及同等发布连接问题归并和账户修复导航。 |

本表是当前源码与调用入口的比较，没有运行 macOS 新版窗口，也不推断线上服务是否可用。macOS 参考均来自固定的 `6abd42a`，没有使用 Linux 分支中的旧 Swift 文件替代。

## 实施顺序与验收边界

| 优先级 | 工作包 | 本轮状态 / 后续验收目标 |
| --- | --- | --- |
| 当前 P24 | 编辑器：选区替换预览、固定大纲、Front Matter/SEO 字段定位 | 本任务由 Terra high、Luna medium、Terra high 三个独立线程实施，主线程接工作区和回归。实现详情与验收见下节。 |
| 当前 P25 | 批量标签与分类 | 由并行任务“完善 Linux 版 macOS 对齐”负责后端、合同、Gateway 和 UI；共享 App 集成顺序交接。验收以 [对齐清单](macos-linux-parity.md) 的 P25 记录为准。 |
| 后续 P26 已实施 | 图片坏引用替换 | 从 P22 只读报告进入逐项替换预览，绑定文章/图片快照，确认时复验；继续保留清单未匹配不等于文件不存在的边界。 |
| 后续 P27 已实施核心审阅 | 保存冲突与恢复 | 在拒绝覆盖外部变更之上，补磁盘/缓冲/基线对照、恢复记录选择与安全退出。不可将读失败转成覆盖写入。 |
| 后续 P28 已实施确认重试 | Git 发布恢复 | 先检测已提交未推送，确认后非强制重试、远端 SHA 核验；再补跨重启事务和经远端确认的发布台账。 |
| 随后 | AI 配置与写作风格 | 先连接状态/模型能力，后同站点公开范例提取与确认应用，再做 AI 批量维护。上下文发送继续需要用户确认。 |
| 随后 | 图片处理、多站点、资料高级组织 | 图片压缩/格式转换/裁剪/隐私清理与撤销；站点专属发布配置、草稿归属；资料批注/集合/推荐及来源说明。 |
| 独立批次 | Git rebase/冲突、Agent/MCP、备份迁移、建站模板 | 每项单独确定计划、状态复验、取消和恢复合同；不能由现有基础 Git、单条恢复稿或 AI 对话推定完成。 |
| 发布前 | Linux 桌面验收 | 同一产物验证 Ubuntu 22.04/24.04、GNOME/KDE、X11/Wayland、HiDPI、IBus/Fcitx5、AT-SPI。前端模拟测试与本机 Rust 测试不能替代矩阵证据。 |

原有操作日志 P20 仍缺业务历史投影、AI/MCP/RSS 等事件、导出与保留策略；PR/MR 仍缺网络结果不明后的找回与查询。旧主线移除的 PreviewPromotion / StructuralDraftRepair 不重新加入本轮追平目标。

## P24 范围

- 正文和冻结选区的查找替换，全部替换先预览再明确应用；切换文稿、编辑正文、变更查询或选项使旧预览失效。实际应用只改编辑缓冲区。
- 窗口内固定大纲，按光标显示活动章节，支持层级折叠和受保护定位。按编辑区域宽度选择侧栏或上方布局。
- 本地元数据报告与字段路由；补 `permalink` / `cover` 输入。无 Front Matter 时只定位添加入口，结构异常时只定位说明，报告不自动改写文稿。字段连续输入保持字段焦点。
- 该批次不新增 Rust 文件访问命令，不自动保存，不运行构建，不联系 AI 或外部图片服务；完整 SEO、Front Matter 源码折叠与多窗口仍待后续。

## 验收记录

2026-09-12 联合工作区验收（含 P24/P25）：

- 前端完整回归 79 个文件、479 项通过；实施前基线为 68 个文件、431 项。新增覆盖字段路由与连续编辑焦点、无元数据时不自动创建、身份/文本失效、大纲折叠和部分结果、替换前确认、冻结选区与 Worker 构造失败/超时/取消。P25 另含 Gateway、组件和真实 App 入口测试。
- `npm run build`（含 TypeScript）与 `npm run check:bundle` 通过；首屏 JavaScript 508.2 KiB，低于项目 700 KiB 预算。编辑器等较大块仍有 Vite 提示。查找 Worker 与批量元数据抽屉均作为独立产物输出。
- 并行任务负责并复验 Rust 全套 308 项通过；`cargo clippy --offline --all-targets --all-features -- -D warnings`、`cargo fmt --all -- --check` 通过。主线程检查了最终日志，未跳过受沙箱限制的本地回环测试。
- 浏览器使用正式 App、CodeMirror、Tauri Gateway 和真实 Worker，配临时内存 IPC 数据。验证了正文替换确认、选区冻结后导航仍保留范围、正则捕获组单次替换、耗时正则终止后正常查找、属性连续编辑焦点、宽窄布局与深浅色。正式浏览器演示中批量磁盘操作保持禁用。临时验收文件与服务已移除/停止。
- `git diff --check` 与本批新增文件空白检查通过；未提交或推送，保留现有工作区变更。

以上浏览器样本不是原生文件读写或发布证据。本轮未重新打包，也未执行 Ubuntu/GNOME/KDE、Wayland/X11、输入法和 AT-SPI 发布矩阵；不能据此宣布完整 macOS 功能对齐。

## 后续 P26–P28

以上三项后续范围已完成有界实施：当前文章的单引用修复、保存冲突审阅及原稿备份、已提交内容的确认式推送重试。跨文章修复、安全退出和跨重启发布事务仍未覆盖。最新联合验收见 [P26–P28 记录](p26-p28-safety-workflows.md)，本页 P24/P25 验收数字保留当时批次含义。
