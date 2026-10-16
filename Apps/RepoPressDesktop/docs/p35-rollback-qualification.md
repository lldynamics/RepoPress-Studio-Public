# P35：只读回滚基础资格审阅

发布中心的统一台账现在可对一条 Git 推送记录“审阅回滚条件”。先读取本地记录与对象，满足本地条件后再展示一次性只读查询计划；用户确认才查询远端分支头。结果仅说明查询时的基础条件，不授权或执行回滚。

## 已实现范围

- 入口仅位于 P34 的 Git Push/PushRetry 记录，PR/MR 不提供此入口。记录未核实、根提交、合并提交、本地对象缺失、替换引用、目标变化或证据无法复核，会显示具体阻塞原因且不生成远端查询计划。
- 从 P31 私有台账按当前会话仓库、记录 ID 和精确版本读取，要求已核实结果、核实时间及远端 SHA 与冻结 SHA 一致。计划冻结整条记录，包括仓库/common-dir 身份、唯一有效推送 URL、历史分支和 SHA，不使用当前 HEAD 替代历史来源。
- 本地检查实际来源提交、单个父提交和两份根树对象存在；拒绝 `refs/replace`，对象查询同时禁用替换、按需下载并禁用全部传输协议。部分克隆缺少对象时保留缺失状态，不自动 fetch。该检查不遍历全部 blob，也不模拟 revert 冲突。
- 候选计划五分钟有效、仅在内存中保留，最多 32 份；重启后需重新审阅。检查时先消费计划，再复验会话、完整记录、当前目标及父提交。过期、错误会话、仓库读取失败、目标/版本变化、凭据失败及网络错误都不能重用原计划。
- 明确确认后复用已有隔离 Git 只读 `ls-remote` 观察。凭据只在该阶段查找；网络前后重新核对本地证据，命令返回前再次比较会话仓库。不会 push、reset、revert、fetch 或修改任何台账记录。
- 新查询远端头精确等于冻结 SHA，才显示“查询时基础条件满足”；不同 SHA 显示阻塞，查询失败、分支缺失或结果不明确保持未知。报告展示查询时间、远端头和父 SHA，不推断原推送失败、PR/MR 合并、部署成功或页面上线。
- UI 校验计划/报告与选中记录身份、状态、父 SHA、时间及阻塞原因一致。关闭、切换会话、台账刷新、记录版本/目标/核实状态变化、禁用或网关变化都会清除候选和报告，旧响应不能回填。重复点击互斥，候选自动过期，可取消；结果报错后须重新审阅。

## 合同与接线

[发布中心](../src/components/PublishCenter.tsx) → [统一台账](../src/components/ReleaseLedgerPanel.tsx) → [资格面板](../src/components/RollbackQualificationPanel.tsx) → [合同](../src/contracts/rollbackQualification.ts) / [Gateway](../src/platform/repositoryGateway.ts) → [命令](../src-tauri/src/commands/publish.rs) → [一次性资格计划](../src-tauri/src/core/rollback_qualification.rs) / [Git 对象与远端观察](../src-tauri/src/core/git_publish.rs)。`AppState`、两份 Gateway 与 Tauri 注册已接通，无新权限或持久化迁移。

`plan_rollback_qualification` 只接收 `sessionId`、`recordId`、`revision`；`check_rollback_qualification` 只接收 `sessionId`、`planId`。目标 URL、SHA 和凭据不由渲染层传入执行。浏览器 demo 两个入口均明确不可用。

macOS 对照固定在 `origin/main` 的 `2d2858fc5ebc3843d1a281026304c2551741691c`：[记录身份模型](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublish/RemoteRepositoryRollbackModels.swift)及[回滚入口](https://github.com/lldynamics/RepoPress-Studio-Public/blob/2d2858fc5ebc3843d1a281026304c2551741691c/Sources/PublishingWorkbenchCore/Stores/PublishingStore%2BRemoteRollbackActions.swift)。Linux 本批只实现其身份复核思想下的基础只读资格，不移植远端写入。对象查询环境变量按 [Git 官方文档](https://git-scm.com/docs/git)核对，本机 Git 2.55.0。

## 验证

- Rust 完整套件 402 项通过，新增 8 项覆盖真实临时 Git/SQLite 与文件远端、后续脏工作区、远端和记录在查询前/中变化、未知结果、过期/错误会话/缺失仓库/重放/容量上限、根/合并/替换对象，以及部分克隆缺失对象保持未下载。正向只读查询前后 HEAD、index、正文、远端引用和台账记录不变。
- 前端完整套件 105 个文件、674 项通过，新增 8 项面板回归及 6 项 Gateway/台账集成回归，覆盖真实阻塞计划、状态矛盾、未经确认零查询、候选过期/消费、防陈旧响应、源刷新和只给 Git 记录提供入口。
- TypeScript、Vite 构建、Clippy `--all-targets -- -D warnings`、版本一致性和体积预算通过；版本为 0.1.0，首屏 JavaScript 523.8 KiB、9 个懒加载块。Vite 仍提示部分压缩块超过 500 kB，项目预算通过。
- 本批 Rust 文件格式检查、`git diff --check`、文件空白和阶段文档本地链接检查通过。全仓 `cargo fmt --check` 仍只报告批次开始前已有的 `ai_connection.rs` / `ai_provider.rs` 格式差异；这两份文件哈希未变。
- 批次开始的 395 个已修改/未跟踪文件中，仅改动拥有的 13 个文件，其他 382 个逐字节保持不变；另新增 8 个 P35 文件。未提交、推送、合并或清理用户工作区。独立审阅无剩余阻断。

主线程负责架构、Rust、共享接线与最终验收；`gpt-5.6-luna` / medium 分别负责独立面板和前端测试，`gpt-5.6-sol` / xhigh 负责只读审阅。日志位于本机临时目录 `/tmp/repopress-p35-2026-10-02/`。

## 保留边界与下一步

这是历史单父 Git 推送记录的基础条件观察，不是完整回滚资格证明。未检查全部子树/blob/附件是否可恢复、对象内容的完整性、逐文件变更范围、revert 冲突、分支保护和写入权限。条件满足后远端仍可能变化，不构成写入授权；报告和记录不备份提交对象，后续 GC 或外部修改可使本地证据失效。

取消候选只清除界面状态，未立即回收服务端内存槽位；取消或重新生成的旧计划在五分钟过期后清理。短时间反复生成最多会触及 32 份上限，此时需等待过期再审阅；后续可按会话/记录去重或增加显式丢弃接口。

本批没有回滚命令导出、本地或远端执行、PR/MR 撤回、合并提交 mainline 选择、站点全文/附件恢复和精确部署关联。真实 GitHub/GitLab、真实凭据及故障、原生窗口和 Linux 桌面矩阵未验收，也未打包或发布发行产物。

下一批建议 P36 有界的逐文件逆向变更只读预览：在单父提交基础上绑定路径、变更类型和两端对象，核验必要文件对象及遗漏，展示删除/恢复影响与不支持类型。之后再为回滚写操作制定独立的一次性计划、执行前远端复验和持久恢复事务。

同日后续：[P36 单提交逆向变更预览](p36-rollback-change-preview.md)已实施上述有界本地路径和对象核验；P35 原批次验收及基础条件语义保留。未变化对象、整次推送恢复、冲突与执行仍待补齐，下一步建议 P37 隔离的本地逆向提交候选。
