# P32：PR/MR 执行记录与结果不明后的只读核实

GitHub/GitLab PR/MR 创建现在先持久保存请求证据，成功返回后还需读取详情精确核实。网络超时或结果不明确时，发布中心可以跨重启读取记录，经用户确认后只读查询，不会自动再创建一次。

## 已实现行为

- 生成计划只读取本地状态：冻结仓库身份、唯一推送 URL、平台、项目、来源/目标分支和本地来源 SHA。说明末尾会加入随机计划 UUID 关联标记；确认界面展示实际发送的说明、标记和冻结 SHA。
- 执行前消费一次性计划，重新检查仓库、分支和 HEAD，再 GET 托管项目与来源分支。远端来源 SHA 必须等于冻结值，否则不会 POST；项目数字 ID 在此时冻结，防止仅凭相同项目路径误认后续结果。
- POST 前提交并读回本地 `unconfirmed` 记录。证据只保存目标、项目 ID、SHA、关联标记和标题/说明的 SHA-256，不保存标题、说明原文或访问令牌。存储失败或记录上限会阻止创建。
- POST 返回编号与官方项目 URL 后，再 GET 对应详情。只有项目路径与数字 ID（GitHub 名称允许大小写差异）、来源/目标分支、来源 SHA、关联标记、标题/说明哈希、编号与精确 URL 均匹配，并且结果成功落盘，才报告已核实。
- 网络/HTTP/解析错误、详情不匹配或最终落盘失败都不报告创建失败或成功，保留未知结果供后续核实。关闭或合并后的 PR/MR 也在查询范围内；“已核实”仅表示找到该请求，不表示已合并、已部署或页面上线。
- 打开/刷新记录列表、生成核实计划都不访问远端。核实计划五分钟有效，绑定会话、仓库、完整记录及版本，执行前一次性消费；使用当前对应仓库/平台/Host 的凭据，执行前后复验仓库身份及 URL。
- 已知编号直接读取详情；未知编号先按来源/目标分支查询所有状态，最多 5 页、每页 20 条，唯一关联候选再读取详情。未找到匹配、多个候选、扫描未完整结束、权限/限流/服务错误都保持未核实，不能推断远端未创建。
- 核实允许本地 HEAD、暂存区或工作树已有后续改动；核实的始终是旧记录中的来源 SHA。远端来源提交或 PR/MR 文本后来被修改后，可能无法再精确匹配，应保留未知而非自动重建。
- 已核实记录允许经确认删除本地记录；仍未核实或正在执行的记录不能清理。已有编号在后续查询失败时仍保留，便于下一次按编号读取，但不会继续显示为已核实。

## 存储与接线

记录位于应用数据目录的 `remote-review-ledger/records.sqlite3`，目录 `0700`、文件 `0600`，使用 SQLite FULL 同步、事务、目录同步及读回验证，拒绝链接、身份替换和损坏。排他实例锁与活动记录租约阻止并发覆盖。所有 PR/MR 记录合计最多 200 条，每条最多 32 KiB；未知记录不自动淘汰。

P31 与 P32 复用 [私有 SQLite 文件生命周期](../src-tauri/src/core/durable_ledger.rs)，P31 的文件路径和既有表结构保持兼容，无格式迁移。两类记录分别存储和计数。

[发布中心](../src/components/PublishCenter.tsx) → [PR/MR 记录面板](../src/components/RemoteReviewRecordsPanel.tsx) → Gateway → [发布命令](../src-tauri/src/commands/publish.rs) → [执行记录](../src-tauri/src/core/remote_review_ledger.rs) / [官方 API 核实](../src-tauri/src/core/remote_review_verification.rs)。Tauri 命令只接收会话、记录/计划 ID 和删除版本；目标 URL 与请求正文不由渲染层传给核实命令。浏览器 demo 不执行核实或清理。

## 验证

- 前端完整套件：95 个文件、606 项通过，包含实际 PublishCenter 的冻结说明展示、确认防重放和结果不明后刷新记录，以及记录面板/网关合同。
- Rust 完整套件：386 项通过；其中 P32 新增 15 项 API/临时 Git 仓库测试、10 项存储测试。覆盖持久化先于 POST、存储不可用零 POST、远端 SHA 不同、POST 超时/500 后跨重启 GET 核实、不同项目/文本/提交拒绝、分页边界、错误响应、并发及本地清理。旧 P31 回归同时通过。
- TypeScript/Vite 构建、Clippy `--all-targets -- -D warnings`、版本一致性和 bundle 门禁通过；首屏 JavaScript 523.0 KiB、9 个懒加载块，Vite 的 500 kB chunk 提示仍存在。
- 没有对真实 GitHub/GitLab 发出创建、推送或核实请求；API 使用模拟传输，Git 仅操作临时仓库。真实凭据/权限、远端故障、桌面重启交互和发行产物仍待验收。

## 官方 API 与保留边界

字段及接口对照 [GitHub PR 列表与详情](https://docs.github.com/en/rest/pulls/pulls)、[GitHub 仓库](https://docs.github.com/en/rest/repos/repos)、[GitHub 分支](https://docs.github.com/en/rest/branches)、[GitLab MR](https://docs.gitlab.com/api/merge_requests/)、[GitLab 项目](https://docs.gitlab.com/api/projects/) 和 [GitLab 分支](https://docs.gitlab.com/api/branches/)。HTTP 传输只允许已有官方 Host，禁用代理/重定向，单响应上限 1 MiB。

本阶段支持官方托管服务的同项目分支 PR/MR；不支持 fork 跨项目创建或自托管端点，不补写旧请求。来源 SHA 检查是创建前和结果后的核实，服务端创建接口仍使用分支名称，不提供原子的 SHA 条件；两次请求间分支变化时可能已有远端对象，但不能报告精确核实成功。

仍缺完整逐文件发布审阅、部署错误到源文件定位、全工作区退出事务，以及文章下线的引用影响审阅和执行。后续可先实现只读的下线影响审阅，再单独推进删除/下线执行。
