# 文档来源与维护规则

本文是文档的来源索引。README 提供产品概览和常用入口，专题文档解释操作与限制，配置和实现定义可执行行为，运行证据说明某一次验证的结果。不要在这些位置分别维护同一套版本号、阈值、检查清单或发布步骤。

## 优先级与冲突处理

1. **声明与配置**：有专用配置的事实只在该配置修改，例如版本、门禁归属、质量阈值和协议标识。下表指定每类事实的来源。
2. **实现与契约测试**：脚本、应用代码负责执行配置；CLI 的实际参数解析、帮助和契约测试定义执行语义。配置与实现不一致是需要修复的缺陷，不能只改文档掩盖。
3. **当前操作文档**：解释前置条件、步骤、失败处理和证据边界，链接上述来源；不复制整份机器清单，不另设默认值。
4. **README 摘要与历史记录**：README 链接当前指南；历史报告只说明当时的源码、环境、结果和未完成项，不能升级为当前验收结论。

运行证据另有适用范围：配置说明“应执行什么”，日志、结果 JSON、源摘要和产物哈希说明“这次实际执行了什么”。本地通过、CI 通过、签名公证、线上可下载分别核验。计划中的行为必须标为方案；发现冲突时先核对当前配置、实现和测试，再同步文档，不能用过时文字反向放宽门禁。

## 关键事实的唯一维护位置

| 事实 | 权威来源 | 文档职责 |
| --- | --- | --- |
| Swift 工具版本、最低系统、target 与依赖 | [Package.swift](../Package.swift)、[依赖锁定文件](../Package.resolved) | README 给环境概览；CI 固定 Xcode 取自实际工作流的 `DEVELOPER_DIR`，不把它混作产品最低版本 |
| 允许的模块依赖与兼容导出 | [边界检查器](../script/check_swift_module_boundaries.py)的策略常量 | [模块依赖指南](module-dependencies.md)解释职责与审查，精确集合用 `--describe-policy` 查询 |
| App 版本与构建号 | [BuildVersion.xcconfig](../Packaging/BuildVersion.xcconfig) | [版本规则](release-versioning.md)只解释递增和验证，不维护另一组当前版本 |
| 门禁命令、输入、证据与 profile 归属 | [release_checks.json](../script/release_checks.json) | 用运行器 `--list` 查询，README 不复制完整检查清单 |
| 参数选择、超时与结果格式 | [release_gate_runner.py](../script/release_gate_runner.py)、[结果 schema](../script/release_gate_result.schema.json) | [脚本目录](../script/README.md)说明职责和固定入口 |
| 覆盖率、格式、测试数与性能质量基线 | [quality_baselines.json](../script/quality_baselines.json) | 解释指标含义，不在文档建立另一套阈值；未入此配置的 trace 阈值由分析器参数定义 |
| CI 触发条件、任务关系和环境 | [实际安装的工作流](../.github/workflows) | README 只链接来源；开发仓与公开快照的工作流不同，不互相推断运行状态 |
| 构建与启动模式 | [build_and_run.sh](../script/build_and_run.sh) | 通过 `--help` 查询参数；README 保留最小构建/启动示例 |
| Developer ID 发布行为与参数 | [package_direct_release.sh](../script/package_direct_release.sh)、[entitlements](../Packaging/DirectDistribution.entitlements) | [直发指南](direct-release.md)是唯一人工操作步骤；它不证明线上已发布 |
| 性能采集与判定 | [采集入口](../script/capture_release_performance_trace.sh)、[trace 分析器](../script/analyze_markdown_scroll_trace.py)、[Release 基准入口](../script/run_release_performance_benchmarks.py) | [性能指南](performance-profiling.md)集中维护复现方法和人工验收边界 |
| 浏览器协议、渠道和扩展身份 | [browser-extension-protocol.json](../BrowserExtension/browser-extension-protocol.json) | [扩展说明](../BrowserExtension/README.md)解释安装；生成的 Swift/JavaScript 常量不手工维护 |
| 一级导航的顺序与路由 | [WorkspaceNavigationRouteDescriptor.swift](../Sources/PersonalSitePublisherMac/Views/Workspace/WorkspaceNavigationRouteDescriptor.swift) | README 概括产品入口，工作区文档解释状态归属，不各自设计导航 |
| 审核译文与应用资源同步 | [翻译主表](../script/ui_localization_translations.json)、[同步器](../script/sync_ui_localizations.py) | 临时片段归并到主表；已管理的资源通过同步器更新，不另建翻译主表 |

查看当前检查集合而不执行检查：

```bash
./script/check_release_gate.sh --quick --list
./script/check_release_gate.sh --tooling --list
./script/check_release_gate.sh --profile direct --list
./script/check_release_gate.sh --profile chrome --list
```

`--list` 默认只显示默认选择，不能当作包含所有自测和严格检查的总表。按 ID 定向运行也不等于完成整个发行 profile。完整发行 profile 面向含维护工作流与渠道台账的开发仓；公开快照使用其安装的源码 CI，不因包含同一运行器就具备完整发行条件。

## 文档类型与适用范围

共同维护并随公开快照导出的指南：本文、[直发指南](direct-release.md)、[版本规则](release-versioning.md)、[性能指南](performance-profiling.md)、[模块依赖指南](module-dependencies.md)。脚本职责目录和浏览器扩展说明随各自目录导出。

以下为**开发仓索引**，不随公开快照导出；路径用于在开发仓定位，内容中的历史证据仍受原始日期和源码范围限制：

| 路径 | 类型与职责 |
| --- | --- |
| `docs/document-workspace-design.md` | 当前架构说明：导航、状态归属、持久化与发布恢复 |
| `docs/ai-chat-evolution-design.md` | 当前架构说明：AI 上下文、工具和授权边界 |
| `docs/view-directory-structure.md` | 当前维护指南：视图领域与源码目录 |
| `docs/ai-connection-setup.md` | 当前连接指南；末尾日期测试是历史证据 |
| `docs/ai-writing-maintenance.md` | 当前使用指南；保留原验收范围 |
| `docs/safe-exit-project-conflicts.md` | 当前使用指南：冲突处理与恢复出口 |
| `docs/article-version-verification.md` | 当前集成指南：源摘要与发布页面版本 |
| `docs/build-cache-maintenance.md` | 当前维护指南：缓存保留与清理 |
| `docs/ai-first-round-improvements.md` | 实施记录：原批次 AI 改动与验证 |
| `docs/redesign-implementation.md` | 实施与验收记录：保留原始待办、结果和未完成边界 |
| `docs/writing-performance-fix-2026-09-08.md` | 历史性能修复记录 |
| `docs/writing-workflow-improvements-2026-09-09.md` | 历史功能验收记录 |

## 同步规则

- 改行为时，先修改其配置或实现以及必要测试，再更新所属专题文档。只有产品概览、环境要求或常用入口变化才同步 README，避免把细节重新复制回摘要。
- 新文档先确定类型、适用范围和源文件；相同主题扩展已有指南。当前指南链接源码，历史记录保留原日期、提交或摘要及失败证据；新一次验收另行记录，不覆盖旧结论。
- `README.md` 是开发仓入口，`README.public.md` 是公开快照模板，两者都不是行为配置。公共产品事实应保持一致；内部调试和公开构建条件可按范围分别说明。
- 公开文档和文件范围只由开发仓的 `script/export_public_snapshot.sh` 显式选择：模板被安装为公开 `README.md`，公开 CI 模板替换开发仓工作流。不要手改导出结果；回到源文档修改并重新导出。
- 更新相对链接时同时检查开发仓和临时公开快照。现有 `script/test_public_snapshot_export.sh` 验证文档副本与本地链接；本地导出验证不意味着允许推送或发布。
