# P50 当前保存资源核验与恢复资格策略计划

2026-10-05 接续 [P49 候选独立复验](p49-knowledge-candidate-check.md)。显式选择 P48 候选目录和冲突策略后，独立重新核验候选及当前保存清单引用的全部历史正文/归档，生成只读资格证据、策略计数、五分钟一次性重新核对和取消。浏览器演示拒绝新入口，不模拟成功；原生合同/Gateway、命令、AppState、Tauri 注册与设置中心同步接线。

## 核验范围

复用 P49 的严格候选协议、路径/私有权限、重复 JSON 键、完整引用/内容、持有文件 witness 与最终目录/inode/stamp 复验；不信任 P49 旧报告。P49 的公开报告保持原有清单比较含义和固定 `currentLibraryResourcesVerified=false`；P50 的 `currentResources` 是额外、明确独立的资源证据。

当前库不经过加载、迁移、初始化或 GC：纯校验已保存 manifest 与 completedOperations，按投影的唯一保存引用读取 blobs/archives。资源目录必须为当前用户的 0700 目录，引用文件必须为 0600 regular 单硬链接；O_PATH 先判类型，拒绝符号链接、FIFO、设备、别名和不安全权限，再打开已持有 inode。逐文件核对大小、SHA-256、UTF-8/归档格式，所有历史引用均包含；保存归档已声明缺失、截断或未知完整性则阻断。

每侧资源独立上限 1024 个/32 MiB；候选仍为 1026 个文件/34 MiB+4096 字节，清单 2 MiB、标识 4096 字节、JSON 131072 节点；候选与当前资源合用一次 5 秒合作式预算。超限不截断为成功，单次系统调用不能被预算抢占。

当前资源检查不是目录全量备份：未引用文件不打开、不计数、不清理，`unreferencedFilesVerified=false`；归档内部附件或外部引用闭合不在本批证据内，`externalReferencesVerified=false`。标识未签名，来源包摘要无法从候选重建，P49 的来源真实性两个 false 标志仍保留。

## 未知、变化与策略

当前清单未核验时资源 notChecked（检查中变化为 changed）；缺失当前库不会创建。当前资源可返回 checked/missing/unsafe/unreadable/invalid/changed/overLimit/incomplete，非 checked 状态的文件数、字节数和摘要全部 null。检查失败的目录/文件观察也纳入末尾复验及内部指纹；已读文件的 O_PATH witness 保留到候选、当前清单、资源、根目录的最终核验。

资格结果仅有 evidenceReady 或 blocked，代表后续人工审阅是否获得本批范围的证据。所有 blocked 的六项策略计数全部 null，包括身份冲突；身份冲突不抹掉已经成功核验的资源摘要。原因优先级：当前清单不可用、当前资源不可用、所选策略的身份冲突。

两种显式策略均保留当前独有项和全部当前身份，不删除或覆盖当前值：

- `requireNoIdentityConflicts`：同 itemId/folderId 的完整保存值存在差异即阻断；相同 ID 的完全相同值保留当前。
- `keepCurrentIdentities`：同 ID 的相同/变化候选值都跳过，保留当前值。候选独有项/文件夹仅给出潜在新增数；显示保留当前总数、跳过候选同 ID 数。

evidenceReady 仍不代表可以安装。这里没有构建并验证合并后的清单；跨 ID 文件夹同名、容量、完整引用图和候选隐私偏好等安装约束仍待下一阶段。`projectedManifestValidated=false`、`candidatePermissionsApplied=false`、`consistentSnapshot=false`、`filesystemWrites=false`、`restoreReady=false` 固定；候选 AI/语义索引授权不自动应用。所有策略计数只是身份策略意图，不承诺可执行合并。

## 计划与界面

最多两份进程内计划，绑定所选路径、当前应用根身份、策略、候选/当前清单/资源的完整观察指纹；不保存明文或资源文件描述符。应用根句柄用于固定目标。墙钟与单调五分钟期限同时检查，重新核对先消费旧 ID，失败/过期不得重用，取消幂等。

重新核对完整重开候选和当前库，生成新 planId/reportId；任一侧当前清单或资源不能核验则 inconclusive，两次都核验且指纹相同才 unchanged，否则 changed。同字节 inode 替换也返回 changed，即使界面可见数量与内容摘要相同。失败状态和摘要变化不降级为 unchanged。

界面严格核对固定字段/预算/标志、UUIDv4、UTF-8 路径、候选 basename/stageId、时间、资源证据与策略计数；显式操作，不自动检查。换源/策略/gateway/启用状态/刷新上下文即失效，过期、迟到、非法响应释放到原 gateway，一次性消费和同步 refs 防止旧 DOM/双击越界。只显示路径、数量、摘要和固定状态，不返回资料标题、正文、URL 或身份列表。

## 协作和验收

主线程负责数据/文件边界、共享接线、架构和最终集成；Luna medium 独占面板/测试与 Rust/Gateway 专项两个通道，Sol xhigh 独立只读复核。保留批前 608 个已有改动/未跟踪文件；不提交、推送、合并、reset、clean 或改写历史。

验收结果：

- 本批专项：面板 22 项 + Gateway 3 项、Rust 14 项全部通过；包含同字节 inode 变化、失败引用的迟到修复、空当前库零引用、真实 34 MiB 超限、资源 unknown/null、两种策略、过期/双击/迟到/非法 wrapper 与策略切换。
- 全量验收在冻结的 2402 文件组合副本运行，包含并行 UI 任务已完成的双语菜单/旧候选面板改动；前端 178 文件 / 1249 项、Rust 609 项全部通过。构建含 TypeScript 检查；`cargo check --locked`、最终 `cargo clippy --all-targets --locked -- -D warnings`、版本一致性均通过。
- 本批 7 个 Rust 文件格式检查通过；整仓格式检查仍报告 `ai_connection.rs`、`ai_provider.rs`、`workspace_state.rs` 三个既有文件差异，字节与批前一致，未改写。Vite 大于 500 kB 块提示保留；启动 JavaScript 681.2 KiB / 9 个延迟块，包体预算通过，版本 0.1.0。
- 本批 14 个代码文件与全量门禁冻结副本一致，门禁后只补本验收文档；4 个文档与代码形成 18 文件增量补丁，在隔离批前副本检查、应用后逐文件核对。
- 批前 608 个文件全部保留，589 个字节不变；10 个共享文件为 P50 增量，9 个文件由独立 UI 任务更新。新增 8 个 P50 文件和 8 个并行 UI 文件均保留。本批未覆盖并行 UI 改动；Cargo 清单/锁文件不变，`git diff --check`、新增链接及增量空白检查通过。

第一次工作区 TypeScript 检查恰逢并行 UI 任务写入测试，报告了暂时类型错误；双方文件稳定后，组合冻结副本的完整构建和测试均通过。文件系统专项使用隔离私有夹具，不使用真实资料库；未执行任何真实恢复或原生桌面验收。

本批证据保存在 `/home/cli/.codex/visualizations/2026/10/02/01a0fc1a-38e2-7e10-9bb9-c5c28fc936fe/p50-evidence/`。本机 /tmp 配额不足时只移除了本批失败的临时快照，随后改用获准磁盘目录保存快照、冻结副本、日志与测试夹具，没有删除以前批次证据。

## 下一阶段

P51 建议先构建隔离的合并清单投影，核验跨 ID 文件夹名称、容量、全部引用和隐私偏好重授权，确定可执行资格；之后再实现确认式安装事务、崩溃回滚及真实恢复验收。P50 没有恢复执行命令，报告不会授予写入权限。外部附件闭合、多库原子/整个工作区、macOS 包交换、独立笔记、原生 WebView/文件选择器、GNOME/KDE Wayland/X11、打包及线上 CI 仍未验收。
