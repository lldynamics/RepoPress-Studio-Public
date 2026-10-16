# macOS / Linux 全面源码对比（2026-10-12）

2026-10-13 复核更正与新计划见 [再次对比与完善计划](macos-linux-comparison-2026-10-13.md)：主线没有新增提交；Linux 已有单稿正则/捕获组替换、版本历史命令入口，内容健康也已关联 sync 高亮。下方相关缺失判定不准确，RSS 历史/隐私缺口亦已由 P56–P59 补齐；常规自动刷新退避与应用级调度则是本次新确认的待修项。下文保留历史记录，当前优先级以新计划为准。

2026-10-13 P59 增量：[RSS 正文解析与历史全文判定](p59-rss-body-history.md)已修复 Atom 嵌套正文丢失、正文/扩展字段污染元数据及正文优先级，并更正 P57 的摘要存储描述。RSS 当前范围以 P59 与 P58 记录为准；下方历史对比按原快照保留。

2026-10-12 P58 增量：[RSS 历史失败账本与分批重试](p58-rss-failure-ledger.md)已补跨段持久失败记录、失败不阻塞续查和确认式重试预览，数据库升级到 schema 4。RSS 当前范围以 P58 记录为准；下方历史对比按原快照保留。

2026-10-12 P57 增量：[RSS 历史分段续查与正文补齐](p57-rss-history-completion.md)已补持久游标、显式已有正文补抓、证据别名与检查点维护。RSS 当前范围以上述记录为准；下方历史对比按原快照保留。

2026-10-12 P56 增量：[RSS URL 隐私审阅与历史文章补全](p56-rss-privacy-history.md)已接通审阅后脱敏/排除、候选确认与有界补全、暂停恢复和失败重试；本报告原始对比结论按当时快照保留，RSS 后续范围以 P56 记录为准。

Linux 已具备实用的写作、资料、阅读、AI 与受保护发布流程，但尚未达到最新 macOS 的完整行为范围。本轮重新拉取主线、冻结本地源码，完成三路并行审阅及 Linux 自动验证；结论以实际接线和行为合同为依据，不以文件存在、测试数量或视觉相似推算完成率。

## 拉取结果与工作树保护

- 远端 `origin/main` 已从 `2d2858fc5ebc3843d1a281026304c2551741691c` 更新到 `878d8cca8e4044c534a5f63f3cc72d08ce6339a0`。最新提交为 2026-10-11 23:17:07 +08:00 的 `Fix PDF OCR language selection and repository test shard timeouts`。
- 本次相对旧基线新增 3 个提交，565 个文件变更，40,929 行增加、13,345 行删除；大量为 UI 重构和本地化，不能直接当作 565 个新功能。
- 当前分支仍为 `codex/linux-tauri-mvp`，HEAD 保持 `97f1fd75e12b4b9606974890bfa317a7bac9b6e3`。本轮远端列表已经没有该 Linux 分支；残留的 `origin/codex/linux-tauri-mvp` 是旧本地引用，不能当作当前远端分支。
- 最新 macOS 主线不包含 `Apps/RepoPressDesktop`。已将它完整展开到独立本地目录，而没有合入当前 Linux 分支；本地现有 701 个改动路径保留。两份本地 Swift 改动与本次上游变更重叠：`WorkspaceBackupRestorePreviewView.swift`、`WorkspaceBackupService+Restore.swift`，后续合并须逐项处理。
- 本批只更新比较文档和证据，不提交、推送、清理工作树，也不执行用户资料导出、恢复、删除或远端产品发布。

最新主线的完整源码在 [macOS README](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/macos-main/README.md)；本地 Linux 冻结源码在 [冻结 App.tsx](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/linux-source/Apps/RepoPressDesktop/src/App.tsx)。原始 [提交记录](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/upstream-log.txt)、[变更路径](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/upstream-paths.txt) 和 [拉取状态](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/refresh-state.json) 已保存。

## 最新主线带来的新差距

1. **工作区与站点语义调整。** 内部五个主路由仍相同，但 macOS 将 RSS 命名为“阅读”、sync 命名为“站点”，站点检查成为站点子功能。旧 compact rail 和 publish overlay 组件已删除，需按当前统一导航、响应式 Inspector 与发布路由比较。Linux 仍显示“RSS 阅读/同步”，旧“结构已追平”结论已过期。
2. **写作状态与反馈。** 新增文章状态、到期发布提醒、正文首行重复标题提示/修复；版本比较新增行高对齐、并排/堆叠与词段高亮，统计改为可取消、带版本复验的会话。Linux 已有版本比较和诊断，但这些新增行为仍有差距。
3. **Git 执行权限。** macOS 增加站点所属 SSH 提交签名及绑定仓库/common-dir 的钩子授权；Linux 继续禁用钩子和签名。需独立设计可选权限，保留默认隔离行为。
4. **发布与维护。** 增强文章/窗口/站点绑定的发布会话、延后问题展示、检查刷新、内容健康忽略规则；增加供既有部署 workflow 使用的定时触发片段。这些源码不代表发布服务已配置或已成功运行。
5. **RSS、AI 与 PDF。** 新增 RSS 历史补全及检查点恢复，完善 Codex 账户/设置与系统采集；PDF OCR 语言修复使首选简中/繁中/英文生效。Linux 已有 OCR 语言选择，不应标成无 OCR。

## 功能和交互矩阵

“已接通”仅表示静态 UI → gateway → command → core 完整；“部分”表示主路径存在但能力或状态语义有差异；“缺失”表示本次未找到等价产品入口。所有涉及原生窗口、文件对话框、SSG、网络服务或桌面交互的项仍需实机验收。

| 范围 | Linux 状态 | 当前覆盖与剩余工作 | 证据 |
| --- | --- | --- | --- |
| 导航、布局、Inspector、发布入口 | 部分 | 路由集合、可调列、聚焦和抽屉已接通；补“阅读/站点”语义、新窄窗策略、当前发布路由和窗口上下文，不能仅调整颜色。 | E1 |
| 编辑器、格式栏、大纲、诊断 | 已接通/部分 | 已有 CodeMirror、章节操作、片段、站内链接、中文排版；原生编辑体验、长文异步统计、首行重复标题提示仍有差距。 | E2 |
| 查找/替换 | 部分 | 正文/选区、字面搜索、预览复验和可取消 Worker 已有；没有 macOS 正则路径。 | E2 |
| Front Matter、SEO、批量元数据 | 部分 | 本地字段编辑/诊断和标签分类批量维护已有；不等于完整 SEO、社交卡片、复杂字段/作者及站点构建校验。 | E2 |
| Markdown 与真实站点预览 | 部分 | 受清理 Markdown 渲染、确认式 Hugo/Zola 预览已有；macOS 有更多生成器/静态预览分支、计划指纹和具体文章页面 HTTP 就绪。Linux 当前仅端口 TCP 就绪，需补页面状态、计划失效和按生成器扩展。 | E17 |
| 文章状态、到期提醒、定时触发片段 | 缺失 | 补站点稿状态语义、通知权限与提醒、现有部署 workflow 的片段预览；避免把提醒当自动发布。 | E3 |
| 草稿生命周期与版本比较 | 部分 | 新建/重命名/回收/历史/比较恢复已接通；补并排对齐、词段高亮、独立菜单入口。现有差异行不是新 macOS 完整比较布局。 | E4 |
| 保存冲突、安全退出、恢复稿 | 已接通/部分 | 当前文档三份文本审阅、先备份后合并入缓冲、退出恢复包已有；macOS 还覆盖工作台待写队列和多窗口，不能视为同一持久化合同。 | E4 |
| 文稿导出 | 部分 | 当前缓冲的 Markdown/HTML 已有；缺 PDF、打印、系统分享和对应原生验收。 | E5 |
| 图片和附件 | 部分 | 导入/浏览/预览/复用、引用诊断及当前稿单引用修复已有；缺压缩/WebP/缩放/裁剪/隐私元数据处理、跨稿修复与可撤销资源整理。 | E5 |
| 多站点 | 部分 | 当前是命名仓库登记/切换/移除；缺生成器、内容/资源路径、作者/分类、发布/AI 配置、复制、专属草稿和删除恢复。 | E6 |
| 多窗口 | 缺失 | Linux 仍是主窗口 App；需独立设计窗口所属文稿、站点、命令上下文及退出流程。 | E6 |
| Git 暂存/提交/fetch/push/重试 | 已接通 | 已有一次性计划、冻结基线、当前目标复验和远端 SHA 查询；fetch 只更新引用，不做同步合并。 | E7 |
| Git 签名、可信钩子、安全同步 | 缺失/部分 | 缺可选签名/钩子策略以及 merge/rebase 冲突、取消、stash 和中断恢复。不能通过开放仓库任意脚本实现追平。 | E7 |
| PR/MR、发布台账与部署 | 部分 | P31–P34/P39 已覆盖创建/未知结果查询/证据聚合；缺完整发布包逐文件线上写入、审阅合并状态与具体发布/文章部署归因。手动部署观察仍未归因。 | E8 |
| 回滚、下线、恢复证据 | 部分 | P35–P40 已有单提交资格、逆向预览、候选、条件远端追加、未知证据和私有归档；下线影响只读。多提交/merge 回滚、完整文章下线另立边界。 | E8 |
| 内容健康、操作日志、修复编排 | 部分 | 已有有界只读诊断、扫描过期保护和精简日志；缺指纹忽略/恢复规则、审阅式修复队列、完整业务投影、导出和保留策略。 | E9 |
| 全工作区备份 | 部分 | P41 预检、P42 配置、P43 RSS、P44 草稿、P45–P46 保存资源包分别可用；仍无跨库一致恢复点和外部附件闭合。独立 SQLite/JSON 导出不能称整工作区备份。 | E10 |
| 单资料库恢复与历史 | 已接通/有界 | P47–P55 已补包核验、私有候选、合并策略/隐私重置、安装、显式恢复、归档、最新历史清理及完整历史导出；P55 同 mount 输出、数量/容量限制仍在。待补回执保留策略及真实断电验收。 | E10 |
| 分类/文章选择恢复、整工作区恢复 | 缺失 | macOS 覆盖工作台、资料库、RSS、附件与失败回退，Linux 尚未形成等价多组件恢复事务。 | E10 |
| 跨端工作区交换 | 缺失 | 未接入 `com.repopress.workspace-exchange/v1`；需站点/草稿/附件 codec、路径冲突预览、未知元数据处理及确认式导入。不得把现有资料包当兼容交换包。 | E10 |
| AI 连接、模型发现、Codex | 部分 | Ollama/OpenAI-compatible、模型列表和文本探测已有；缺 Codex App Server/账户生命周期、丰富预设与能力证据。连通不等于流式/工具/结构化输出能力已验证。 | E11 |
| 连续对话、流式、取消、历史 | 已接通/部分 | 文本多会话、流式与取消已有；默认进程内，显式口令解锁才启用加密库。缺图片附件和高阶聊天工作台；持久化不同是隐私取舍。 | E11 |
| AI 凭据与发送权限 | 已接通/合同不同 | Secret Service、逐资料授权、每轮发送预览/确认及执行复验已有；macOS 另有全局远程禁用、精确目的地授权和 Codex 账户绑定，需明确新增权限层，不能把一次发送确认变成永久授权。 | E11 |
| 固定 AI 写作/应用内计划 | 缺失 | macOS 当前固定工具仍生成可确认的 WorkbenchAutomationPlan；Linux 只有发送/编辑计划，尚无等价应用内命令计划、模板及回滚。旧 Agent loop 已退役，不能混为一谈。 | E11 |
| 资料导入、文件夹、历史 | 部分 | 持久化资料、分类、保存正文/归档、历史查看、PDF/浏览器接入已有；缺统一文件/文件夹/图片/网页分析预览、资料版本比较/恢复与来源刷新。 | E11/E16 |
| 集合、标注、反向链接 | 缺失/部分 | 基础分类已有；缺收藏/已存或智能集合、资料原生标注和文章反链。RSS highlight 不等于资料标注。 | E11 |
| 独立笔记、rpnotes 与同步 | 缺失 | 缺独立笔记编辑/附件/快照和 .rpnotes 导入导出；CloudKit 需 Linux 替代设计，普通资料/Markdown 导出不是笔记协议。 | E16 |
| 本地语义检索 | 部分/合同不同 | 资料查询混合词面和本地 hash 特征，仓库索引为 384 维会话内存；macOS 资料索引有持久 SQLite/融合检索。需实测召回和延迟，不能仅凭维度判质量。 | E11 |
| RSS 常规阅读、全文、进度、标注 | 已接通 | 订阅/刷新/搜索、已读/收藏、全文缓存、进度、标注与导出已有；真实网络、后台刷新和阅读体验未在本批验收。 | E12 |
| RSS 历史补全 | 缺失（本轮新增） | 缺同源目录/robots/sitemap 发现、默认10页/500URL、默认20篇批次、持久检查点、取消/继续/重试。按有界网络导入独立实施。 | E12 |
| RSS OPML/备份及 URL 隐私 | 部分，需优先补隐私审阅 | Linux 有 OPML/JSON/SQLite 导出，但 OPML 原样输出已存 URL，URL 校验未排除查询参数；缺 macOS 对疑似 token/key 查询参数的脱敏/排除选择。应先补风险预览，再扩展历史抓取。 | E12 |
| 翻译与跨语言稿关系 | 部分 | 正文/结构化翻译及离线缓存已有；RSS 列表译题、跨语言稿生成/关系及原文变更复核仍有差距。Apple Translation 需替代方案。 | E12（补充见下） |
| PDF 文字层与 OCR | 部分 | 已有显式 eng/chi_sim/eng+chi_sim、bwrap 固定命令及12页上限；缺繁中与逐页文字层/空白页 OCR 混合。macOS 默认 OCR 200页，调用配置上限500，仅计需 OCR 页；本轮修复关闭 Vision 自动语言检测。 | E12 |
| 浏览器、Share、Shortcut 采集 | 平台分叉 | Linux 保留认证回环浏览器桥；macOS 已撤下旧扩展，当前使用 Share/App Intents 收件箱。Linux 尚无对应桌面系统入口，不应擅自删除现有浏览器能力。 | E16 |
| 私密内容遮挡 | 缺失 | 缺列表、搜索、概览中的私密摘要/正文/路径遮挡；凭据隔离和 AI 发送权限不能替代显示隐私策略。遮挡本身也不等于加密。 | E13 |
| 界面语言 | 部分 | Linux 已有中文/英文资源、动态消息和多批本地化；操作日志等仍有中文常量，应审计覆盖率及回退，旧“完全无本地化”判定已失效。 | E13 |
| 共享确定性规则 | 部分 | 两侧 40 条 golden cases 清单与逐例 checksum 相同，但 Linux React/Rust 未统一消费该清单；相同样例不证明实现一致。 | E14 |
| Linux 包、更新、可访问性 | 实现存在/待配置和验收 | deb/AppImage、签名链路及客户端一次性更新路径已有；普通配置 endpoint/public key 为空。需真实 CI 产物、升级、Ubuntu/GNOME/KDE/X11/Wayland/HiDPI/IME/AT-SPI 矩阵。 | E15 |
| macOS 专属系统能力 | 需替代设计 | AppKit、Keychain、Share Sheet、Shortcuts、CloudKit、Apple Translation、Sparkle 等不直接移植 SwiftUI；按 Linux 桌面接口和现有 Rust/React 边界实现等价需求。 | E11/E15 |

## 建议接下来的批次

这是一份按本次差距重新排序的建议，未在本批启动实施。

| 顺序 | 有界目标 | 验收边界 |
| --- | --- | --- |
| 0 | 固定可交付 Linux 基线与完整门禁 | 先解决三个既有 Rust 格式差异，保留可审阅增量；在后续获得提交/推送授权后建立可复现的远端 Linux 交付分支。接入共享 golden fixture 消费，实测同一 deb/AppImage。 |
| 1 | 最新工作区语义与发布状态 | 先补“站点/阅读”入口、站点检查子路由和文章状态，再补窄窗/发布路由；每次限定 App/共享接线唯一所有者，保留未保存缓冲和焦点。通知提醒作为独立增量。 |
| 2 | RSS URL 隐私与历史补全 | 先完成 OPML 疑似凭据参数风险审阅/脱敏/排除，再做用户触发的来源发现、范围/数量/目标预览，再确认导入、去重、进度、取消与失败恢复；不能自动抓取整站。 |
| 3 | 写作完成度 | 依次补首行重复标题提示、会话化统计、对齐/词段版本比较；正则需可取消有界执行；PDF 导出需要真实打开验证，打印/分享另批。 |
| 4 | 备份与交换闭合 | 先补恢复清理回执/保留策略及外部附件闭合；再设计多库一致导出与 manifest，最后分类/文章恢复及交换 codec。单资料库事务不可直接扩写成跨库原子承诺。 |
| 5 | 高级 Git 与发布证据 | 从只读同步计划和冲突诊断开始，单独实现签名/钩子权限及可恢复同步；补合并后部署归因、完整发布包和超出单提交的回滚。 |
| 6 | AI 与资料高级功能 | 固定单步写作计划、站点 AI/模板与 Codex 账户分批实施；资料标注/集合、混合 PDF 提取和繁中 OCR 分开验收，保留每轮发送和逐资料授权。 |
| 7 | 图片优化和桌面完成度 | 先单文件压缩预览/确认/可恢复替换，之后 WebP/裁剪/批量；隐私遮挡、多窗口、系统集成及真实桌面矩阵分别验收。 |

## 本批验证

| 检查 | 本轮结果 | 证据 |
| --- | --- | --- |
| 完整前端 Vitest | 205 文件、1707 项通过 | [日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-vitest.log) |
| 完整 Rust tests | 694 项通过；普通 sandbox 首次689通过/5项监听EPERM，提升权限后694/0 | [最终日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-cargo-test-escalated.log) |
| Clippy all-targets/all-features -D warnings | 通过 | [日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-cargo-clippy.log) |
| TypeScript / Vite 生产构建 | 通过；保留 dialog 静态/动态混合导入及 >500kB chunk 警告 | [日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-build.log) |
| 包体预算 | 通过；首屏 JS 694.2KiB、2文件、9懒加载块 | [日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-check-bundle.log) |
| 版本一致性 | 通过，0.1.0 | [日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-check-version.log) |
| cargo fmt --check | **未通过**；既有 ai_connection.rs:173、ai_provider.rs:216/336、workspace_state.rs:676，未改源 | [日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-cargo-fmt.log) |
| Linux CI 脚本自测 | 通过；10+7 AT-SPI夹具测试通过。AF_UNIX 合成编排夹具在普通及提升环境仍跳过；没有运行真实 compositor/GUI | [补充日志](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/validation-linux-ci-elevated.log) |
| 共享样例核验 | 两侧40例清单摘要相同，逐例 SHA 校验全部通过；未声称 TS/Rust 消费一致 | [清单](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/macos-main/Shared/RepoPressCoreContracts/swift/contracts/fixtures/v1/manifest.json) |
| 文档链接、源码保留、git diff --check | 通过；详见最终保留清单 | [保留记录](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/preservation.json) |


## 源码证据索引

| 编号 | 最新 macOS（固定提交） | 本地 Linux（本批冻结对应源码） |
| --- | --- | --- |
| E1 | [布局](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Workspace/WorkspaceLayoutViews.swift#L102)、[站点名称](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Resources/Localizable.xcstrings#L17152) | [导航](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/WorkspaceNavigation.tsx:9)、[可调列](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/ResizableWorkspace.tsx:52)、[工作区接入](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/App.tsx:1582) |
| E2 | [重复标题](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingMarkdownCore/MarkdownDuplicateTitleService.swift#L3)、[统计会话](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Editor/MarkdownEditorStatisticsSession.swift#L61)、[查替](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Editor/MacMarkdownComposerView.swift#L220) | [同步统计](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/App.tsx:295)、[字面查找](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/features/writing/markdownFindReplacePreview.ts:141)、[SEO 边界](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/MetadataInspector.tsx:22)、[批量字段注册](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/lib.rs:213) |
| E3 | [文章状态](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Models/ArticleState.swift#L6)、[提醒权限](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/App/ArticlePublishReminderCoordinator.swift#L36)、[触发片段](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Services/ScheduledPublishWorkflowTemplate.swift#L3) | [文稿命令范围](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/App.tsx:1499)、[现有文稿命令](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/lib.rs:230) |
| E4 | [对齐比较](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Editor/DraftVersionAlignedBodyView.swift#L5)、[工作台退出](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+SafeTermination.swift#L19) | [历史](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/DraftHistoryCenter.tsx:101)、[比较](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/DraftVersionComparisonView.tsx:39)、[冲突审阅](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/SaveConflictReview.tsx:108)、[退出接线](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/platform/editorExitGateway.ts:13) |
| E5 | [原生导出](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Support/MarkdownDocumentExportExecutor.swift#L87)、[图片变换](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Stores/ImageWorkbenchStore.swift#L793) | [导出范围](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/MarkdownDocumentExportMenu.tsx:40)、[图片边界](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/ImageWorkbench.tsx:264)、[图片注册](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/lib.rs:225) |
| E6 | [站点配置](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Settings/SettingsProfileBar.swift#L62)、[窗口上下文](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Support/WorkspaceWindowSession.swift#L66) | [登记模型](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/site_profiles.rs:25)、[站点交互](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/SiteProfileCenter.tsx:143)、[主窗口边界](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/commands/editor_exit.rs:116) |
| E7 | [执行权限](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingDomainContracts/RepositoryGitExecutionPolicy.swift#L3)、[同步计划](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Stores/RepositoryStore+SafeSync.swift#L5) | [Git 执行](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/git_publish.rs:386)、[fetch 范围](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/git_publish.rs:417)、[禁用 hooks](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/git_publish.rs:1676)、[注册](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/lib.rs:256) |
| E8 | [部署归因](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift#L51)、[回滚类型](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift#L107) | [统一证据](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/release_ledger.rs:18)、[持久未知意图](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/rollback_transaction.rs:327)、[独立查询](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/rollback_transaction.rs:359)、[真实入口](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/PublishCenter.tsx:197) |
| E9 | [忽略规则](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Services/ContentHealthSuppressionPolicy.swift#L3)、[固定命令](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Models/WorkbenchAutomationModels.swift#L33) | [只读扫描](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/RepositoryContentHealthPanel.tsx:88)、[精简日志](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/OperationLogCenter.tsx:119)、[过期保护](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/UnpublishImpactPanel.tsx:38) |
| E10 | [备份分类](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingBackupCore/Models/WorkspaceBackupModels.swift#L50)、[组件恢复与回退](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Services/WorkspaceBackupService+Restore.swift#L269)、[交换格式](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingBackupCore/Models/WorkspaceExchangeModels.swift#L3) | [预检合同](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/workspace_backup.rs:347)、[单库安装](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/knowledge_restore_install.rs:262)、[同 mount 导出](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/knowledge_restore_history_export.rs:135)、[备份恢复接入](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/WorkspaceBackupSettingsSection.tsx:36) |
| E11 | [AI 预设](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingAICore/AIProviderPreset.swift#L20)、[目的地授权](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingAICore/Services/AIDataSharingConsentStore.swift#L83)、[旧 Agent 退役](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+AutomationCommands.swift#L16)、[资料标注](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Knowledge/KnowledgeAnnotationViews.swift#L90) | [每轮发送](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/AIChatPanel.tsx:44)、[加密历史](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/ai_chat_vault.rs:26)、[检索混合](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/knowledge_library.rs:1298)、[会话特征](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/semantic_index.rs:18)、[AI 注册](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/lib.rs:277) |
| E12 | [历史补全限额](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingKnowledgeCore/Models/RSSHistoryBackfillModels.swift#L69)、[OPML 隐私选择](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Support/RSSOPMLFileTransferService.swift#L39)、[OCR 语言](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingKnowledgeCore/KnowledgePDFOCRService.swift#L16)、[OCR 默认与上限](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingKnowledgeCore/KnowledgeImportModels.swift#L11) | [阅读功能](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/RssReader.tsx:90)、[OPML 导出](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/rss.rs:1503)、[URL 校验](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/rss.rs:3561)、[OCR 限额/语言](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/ocr_extract.rs:14)、[RSS 注册](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/lib.rs:329) |
| E13 | [展示隐私](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift#L130)、[阅读名称](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Resources/Localizable.xcstrings#L17120) | [界面语言](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/i18n/i18n.tsx:1)、[残留常量](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/OperationLogCenter.tsx:119)、[搜索呈现](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/WorkspaceCommandPalette.tsx:1) |
| E14 | [40 条 golden 清单](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Shared/RepoPressCoreContracts/swift/contracts/fixtures/v1/manifest.json#L1) | [同摘要清单](/home/cli/Projects/RepoPress/Shared/RepoPressCoreContracts/contracts/fixtures/v1/manifest.json:1)；检查了 React/Rust 消费入口，尚无统一清单测试 |
| E15 | [macOS 平台](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Package.swift#L8)、[公共快照 CI](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/.github/workflows/quality.yml#L18)、[Sparkle 签名](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/script/generate_direct_appcast.sh#L20) | [空更新配置](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/tauri.conf.json:30)、[打包定义](/home/cli/Projects/RepoPress/.github/workflows/tauri-desktop.yml:106)、[桌面矩阵定义](/home/cli/Projects/RepoPress/.github/workflows/tauri-desktop.yml:289)、[离线夹具](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/scripts/ci/test-linux-wayland-atspi.sh:2) |
| E16 | [rpnotes 入口](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Knowledge/KnowledgeNoteTransferSheet.swift#L151)、[笔记包](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingKnowledgeCore/Services/RPNotesPackageCodec.swift#L1)、[Share 采集](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/ShareExtension/ShareViewController.swift#L53)、[Shortcuts](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/ShortcutExtension/AppIntents.swift#L6) | [导入入口](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/KnowledgeLibrary.tsx:186)、[独立浏览器采集](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/browser_capture.rs:171) |

| E17 | [生成器分支](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingWorkbenchCore/Services/LocalSitePreviewService.swift#L766)、[页面 HTTP 就绪](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PublishingPreviewCore/Services/LocalSitePreviewPageReadinessService.swift#L22) | [支持范围](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/site_preview.rs:119)、[TCP 就绪](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src-tauri/src/core/site_preview.rs:404)、[真实接入](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/App.tsx:1654) |

翻译补充：[RSS 列表译题](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/RSS/RSSReaderArticleListView.swift#L43)、[跨语言稿生成](https://github.com/lldynamics/RepoPress-Studio-Public/blob/878d8cca8e4044c534a5f63f3cc72d08ce6339a0/Sources/PersonalSitePublisherMac/Views/Workspace/TranslationCreationSection.swift#L24)；Linux [现有翻译接线](/home/cli/Projects/RepoPress/Apps/RepoPressDesktop/src/components/RssReader.tsx:5)。

完整审计细项和接线行号见 [写作/工作区](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/audit-writing-ui.md)、[AI/资料/RSS](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/audit-ai-knowledge-rss.md)、[发布验证](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/audit-release-validation.md)、[主线程 Git/数据审阅](/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/refresh-2026-10-12/audit-root-critical.md)。三名代理只写各自审计/验证产物，主线程复核并纠正了导航命名、SEO范围、OCR上限及OPML隐私判定。


## 范围与保留项

本报告是最新源码、静态调用链及本地自动测试的比较。没有运行 macOS 构建/真实窗口/公证，没有验证线上 Actions、真实生产更新端点、真实 PDF/OCR/SSG/AI 服务，也没有采集原生 Wayland、IME、HiDPI、读屏器或断电恢复证据。离线编排夹具通过或跳过均不能代替真实桌面验收。

已退役的 SiteStarter、浏览器扩展、外部 MCP 客户端、应用内模型下载以及旧 Agent 不作为自动追平目标；当前仍维护的 Codex 运行时和确认式工具计划须按最新源码独立比较。Linux 现有浏览器采集属于其既有独立能力，不能因 macOS 撤下扩展而擅自删除。

本批开始保存了 2,479 个仓库文件条目及改动补丁。原有源码逐项摘要复核，除本批三份既有文档增加索引和新增比较报告外，原始文件保持不变；Git HEAD、暂存区和所有既有改动保留。冻结验证目录仅构建输出/两项 Python 缓存变化，未更改所测源码。
