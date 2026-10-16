# P31：Git 推送执行记录与跨重启只读核实

普通 Push 和 P28 已提交内容的 PushRetry 现在都先保存冻结的执行证据，再执行推送。发布中心可以在重启后读取这些记录；用户审阅目标并确认后，仅查询远端分支 SHA，帮助判断结果不明的推送。

## 已实现范围

- 推送前保存仓库规范路径与身份摘要、操作种类、远端名称与唯一推送 URL、分支、冻结 SHA；P28 同时保存审阅过的路径和执行前观察到的远端 SHA。记录不保存正文或凭据，Git 提交对象仍由源仓库持有。
- 使用权限 `0700` 的应用私有 `publish-ledger` 目录及 `0600` 的 `pushes.sqlite3`。SQLite 事务使用 `synchronous=FULL`，提交后同步目录并精确读回；存储不可用、损坏、替换、链接或超过边界时拒绝开始新推送，不回退到内存、不覆盖损坏数据库。
- 数据库持有非阻塞排他文件锁，第二个应用实例不能同时写入、核实或删除记录。持有者退出后锁自动释放，重新启动可读取遗留记录。
- 普通 Push 与 P28 都在隔离 Git 目录中推送冻结 SHA 到冻结 URL/分支，不使用可能变化的本地分支引用，不运行推送 hooks、不跟随 tags、不强制推送。只有后续 `ls-remote` 精确等于冻结 SHA 且结果成功落盘，才返回已核实成功。
- 发起前的状态为 `unconfirmed`；进程中断或无法读取远端时保持未核实。观察到其他 SHA 记录为 `different`，仅说明查询时远端不同，不能证明原推送失败。最终落盘异常时不报告成功，后续可重新只读核实。
- 打开、刷新记录列表及生成核实计划只读取本地状态。点击“确认只读核实”才查询远端；计划五分钟有效、一次性消费，绑定仓库会话、记录版本和冻结目标。网络前后复验仓库身份及唯一 URL，允许重启后 HEAD、暂存区、工作树已有新改动。
- 全部仓库合计最多 200 条、单条 4 MiB、总记录数据 16 MiB。达到上限不会自动淘汰；用户可在对应仓库明确删除已有观察结果的本地记录。删除校验记录版本及仓库，拒绝未核实或仍在执行的记录，不更改远端。
- 浏览器 demo 列表为空，核实及删除不可用；Tauri 命令只接收会话、记录/计划标识和删除版本，远端 URL 不由渲染层传入执行。

## 入口与实现

发布中心 → [PublishRecordsPanel](../src/components/PublishRecordsPanel.tsx) → [RepositoryGateway](../src/platform/repositoryGateway.ts) → [发布命令](../src-tauri/src/commands/publish.rs) → [持久记录](../src-tauri/src/core/publish_ledger.rs) / [Git 推送与核实](../src-tauri/src/core/git_publish.rs)。命令已接入 `AppState` 和 Tauri 注册。

## 本地验证

- 前端完整套件：93 个文件、592 项通过；最终记录面板调整后，9 项组件测试再次通过。
- Rust 完整套件：361 项通过。新增记录存储和 Git 临时仓库测试覆盖跨重启、精确/不同/未知结果、存储失败先拒绝、终态落盘失败、目标 URL/仓库身份改变、一次性消费、活跃记录、清理版本校验、容量和实例互斥。
- TypeScript/Vite 生产构建、Clippy `--all-targets -- -D warnings`、版本一致性及 bundle 门禁通过；首屏 JavaScript 522.3 KiB，9 个懒加载块。Vite 的 500 kB chunk 提示仍存在。
- 测试只使用临时 Git 仓库和本机模拟服务，没有对真实 GitHub/GitLab 发起推送或发布。真实鉴权、远端故障、桌面重启交互、AppImage/deb 及 GNOME/KDE 矩阵仍待验收。

## 保留边界与下一步

本阶段只覆盖启用 P31 后产生的 Git Push/PushRetry，不补写旧活动日志，不涵盖 Commit/Fetch 台账，也不代表 PR/MR 创建结果、部署成功或逐文件发布审阅完整性已经核实。记录保存提交标识及 P28 路径，不备份 Git 对象或文章附件。

同日后续已完成 [P32 PR/MR 执行记录与只读 API 核实](p32-remote-review-verification.md)的本地实现与测试；它使用独立的 PR/MR 记录，不改变本页 P31 的 Git 推送范围。
