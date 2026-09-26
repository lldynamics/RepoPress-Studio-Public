# `script/` 维护契约

文档、配置、实现与运行证据的优先级统一见[文档来源与维护规则](../docs/README.md)。本页维护脚本职责，不另行定义质量阈值或 CI 调度；表中的调用场景是定位提示，精确选择以清单和 `--list` 为准。

本目录只编排外部工具、构建过程和可审计证据；产品逻辑放在 `Sources/`，产品行为测试放在 `Tests/`。维护者通常只需要记住固定入口：构建启动用 `script/build_and_run.sh`，质量统一用 `script/check_release_gate.sh`，直接分发用 `script/package_direct_release.sh`。其他脚本按需调用，不能把脚本目录当作新的产品层。

Quartz 4 静态预览的固定 Python 运行器保存在 `Sources/PublishingWorkbenchCore/Services/QuartzStaticPreviewRunner.swift`，不是本目录的新入口：应用需要把完整运行内容纳入预览授权指纹，且 Quartz 自带 `--serve` 的 HTTP 与 WebSocket 端口无法一起限制在回环地址。输入是每次启动都已确认的仓库根目录、受信任的 Node 路径和分配的本机端口；运行器在时间、文件数、大小和磁盘余量上限内复制仓库到临时目录、阻断逃逸符号链接、执行一次有超时和日志上限的 Quartz 构建，再只在 `127.0.0.1` 提供生成的静态文件。构建及其子进程位于独立进程组；停止、超时或父进程退出时会结束构建进程并清理副本。构建或校验失败时退出并留下有界诊断。浏览器页面就绪和后台回环探测使用 `LocalSitePreviewStartupBudget` 的同一启动预算；Quartz 预算覆盖仓库副本、静态构建及短暂余量，普通开发服务器保持原有短等待。调用者是 `LocalSitePreviewService`；`QuartzStaticPreviewRunnerTests` 验证构建、回环访问和清理。若 Quartz 为 HTTP 与热更新端口都提供可靠的回环绑定，或应用采用等效的原生静态文件服务器，可一并退役此运行器及其授权规则。

长期检查的可执行契约以 `release_checks.json` 为准：`source` 声明输入，`evidence` 声明证据，`command` 声明命令，`groups` / `profiles` 声明调用场景。检查失败返回非零；运行器保存逐项结果、超时和失败日志。`--list` 可与选择参数组合预览，不执行检查。构建和专题工具的写入位置、选项及外部前提以各工具的 usage 为准；`--tooling` 使用隔离 fixture 验证脚本行为，不构成真实发布证明。

## 入口

| 文件 | 职责 | 主要调用者 / 验证方式 |
|---|---|---|
| `build_and_run.sh` | 构建、签名并启动 RepoPress Studio；把共享菜单扩展放入 `Contents/PlugIns`、快捷指令扩展放入 `Contents/Extensions`，先签扩展再签主应用；支持调试、发布、验证、启动性能等模式，并把最终应用放入 `dist/`。 | 维护者、本地发布流程；`test_build_and_run_lock.sh` 验证并发 bundle 锁，`--verify` 验证构建产物与窗口。 |
| `check_release_gate.sh` | 质量门统一兼容入口，把选择参数交给清单驱动的发布门。 | 本地维护、CI；`test_release_gate_selection.py` 与 `test_release_gate_runner_contract.py` 验证选择和契约。支持 `--quick`、`--tooling`、`--profile`（`direct`、`all`）、`--list`、`--check ID`。 |
| `package_direct_release.sh` | 组装并校验两个系统入口扩展的注册声明，再独立重签扩展与主应用、公证并验证 macOS 直接分发包。 | 直接分发发布者；`test_package_direct_release.sh` 验证隔离 fixture、参数和失败语义。 |

## 单项检查

这些脚本各自负责一个检查领域；发行门等领域编排可以组合多个检查，单项检查不要再承担发布或产品逻辑。

| 文件 | 职责 | 主要调用者 / 验证方式 |
|---|---|---|
| `check_accessibility.sh` | 检查 SwiftUI/AppKit 源码的可访问性标签、控件契约和必需资源。 | `check_release_gate.sh` quick/CI；由脚本内静态断言验证。 |
| `check_accessibility_runtime.sh` | 运行 macOS 无障碍 UI 回归；可构建隔离 fixture 或验证指定应用。 | 发行 profile / CI；非截图回归要求显式应用路径，失败即退出非零。 |
| `check_build_version.sh` | 校验 `BuildVersion.xcconfig`、Info.plist 与应用版本字段一致。 | 构建/发布门；`test_build_version_gate.sh`。 |
| `check_ci_quality_workflow.sh` | 检查 GitHub Actions 质量、工具链和共享 Swift 工作流的固定 action。 | CI 配置维护；脚本断言。 |
| `check_launch_performance.sh` | 通过标准构建入口执行启动基线检查。 | 发行性能流程；调用 `build_and_run.sh --launch-baseline`，失败返回非零。 |
| `check_localization_gate.sh` | 检查 Swift 编译器导出的应用本地化键、补充提取键、Core 资源和目录完整性。 | quick/本地化维护；与 `sync_ui_localizations.py` 配合，脚本断言失败即阻断。 |
| `check_public_snapshot.sh` | 检查公开快照的源边界、敏感路径、共享 Swift 包子树和其来源摘要。 | 公开快照发布前；`test_public_snapshot_export.sh` 与脚本静态断言。 |
| `check_quality_baseline_policy.py` | 拒绝质量基线被无声放宽，保证阈值单调或有明确迁移。 | release gate；`test_quality_baseline_policy.py`。 |
| `check_repository_source_boundary.sh` | 检查仓库源码边界、SwiftPM 构建锁、两个系统入口扩展、UI 测试输入、链接目录和发布模式下的来源完整性。普通模式只报告 checked paths 下没有未跟踪的构建/发布输入；`--release` 还要求当前 HEAD 对应的提交工作树完全干净。 | quick/发布；`test_repository_source_boundary.sh`。 |
| `check_swift_accessibility_fields.py` | 查找 `TextField`/`TextEditor` 缺少直接 accessibility label 的 Swift 源码。 | `check_accessibility.sh`；`test_swift_accessibility_fields.py`。 |
| `check_swift_coverage.py` | 运行 Swift 覆盖率并执行 Sources 行覆盖基线及变更行约束。 | 发行与深度覆盖率流程；`test_swift_coverage_gate.py`。 |
| `check_swift_format.sh` | 对 Swift 源码执行格式静态检查并保存结果证据。 | quick/CI；`test_swift_format_gate.sh`。 |
| `check_swift_module_boundaries.py` | 核对实际依赖与精确策略，检查循环、源码导入、第三方产品和兼容导出，记录依赖审计报告；规则查询用 `--describe-policy`。 | quick/CI；`test_swift_module_boundaries.py`；职责与证据边界见[模块依赖指南](../docs/module-dependencies.md)。 |
| `Shared/RepoPressCoreContracts/swift/verify-source.py` | 核对已提交的共享 Swift 源码、测试与 fixture 是否匹配 `source-lock.json`。 | `shared-repopress-source-lock` 通过 `check_release_gate.sh` 运行；公开快照门复用它，不能另建平行摘要检查。 |
| `check_swift_release_build.sh` | 使用发布配置编译 SwiftPM 产品并校验可交付构建。 | release profile；`test_swift_release_build_gate.sh`。 |
| `check_swift_safety.py` | 拒绝未审查的强制操作、`try?` 和 `@unchecked Sendable`。 | quick；`test_swift_safety_gate.py`。 |
| `check_swift_strict_build.sh` | 按清单语言模式执行严格并发构建，默认编译测试，也可限定一个 target。 | direct profile 或定向 `--check swift-strict-build`；`test_swift_strict_build_gate.sh`。 |
| `check_test_isolation.py` | 拒绝测试使用应用默认持久化位置，保障测试隔离。 | quick；`test_check_test_isolation.py`。 |
| `check_typography.py` | 检查工作台最小可读字号与相关字体契约。 | quick；`test_typography_gate.py`。 |
| `check_ui_product_contract.sh` | 检查视图目录分层、关键工作台视图路径与产品 UI 契约。 | direct profile / 定向检查；`test_ui_product_contract.py`。 |
| `check_ui_runtime.sh` | 校验已组装应用 bundle、两个扩展的注册声明、manifest 与可选启动运行时证据。 | release/profile；依赖 `release_artifact_manifest.py`，失败即非零。 |

## 构建、发布与专题工具

这些工具仍是按需维护入口，不改变固定主入口。专题入口可生成证据或平台产物，但不能被误当成用户入口。

| 文件 | 职责 | 主要调用者 / 验证方式 |
|---|---|---|
| `benchmark_knowledge_semantic_search.sh` | 在指定规模和迭代次数下测量知识语义搜索并写 JSON 基准。 | 性能专题；检查输出 JSON、配置和退出码。 |
| `benchmark_markdown_syntax_highlighting.sh` | 测量 Markdown 语法高亮基线并写 JSON。 | 性能专题；参数 usage 与输出文件检查。 |
| `benchmark_swift_module_builds.py` | 测量 SwiftPM target 构建拓扑、耗时和摘要，不修改工作树。 | 性能专题；`test_benchmark_swift_module_builds.py`。 |
| `capture_release_performance_trace.sh` | 启动或复用发布应用，采集 Instruments 性能 trace 及目录证据。 | 性能专题；`test_capture_release_performance_trace.sh`。 |
| `capture_trace_provenance.py` | 为 trace 输出源树和 bundle 摘要，避免嵌入工作树内容。 | trace 编排；检查 JSON 中的 digest/版本字段。 |
| `export_public_snapshot.sh` | 从开发树导出空目录中的公开快照并执行边界检查。 | 公开快照发布；`test_public_snapshot_export.sh`，发布前另跑 `check_public_snapshot.sh`。 |
| `generate_direct_appcast.sh` | 使用 Sparkle 工具为直接分发归档生成 appcast。 | 直接发布专题；检查签名、公钥、URL 和生成文件。 |
| `run_release_performance_benchmarks.py` | 运行独立 Release 性能测试，拒绝跳过/缺失证据并写自包含 JSON。 | release 性能 profile；`test_release_performance_benchmarks.py`。 |
| `run_swift_tests.sh` | 固定调用 Swift 测试进程执行器，提供完整测试清单入口。 | release gate/CI；`test_run_swift_tests.py`。 |
| `sign_sparkle_framework.sh` | 对 Sparkle framework 执行签名、验证和开发者 ID 约束。 | 直接分发打包；检查 `codesign`/`plutil` 输出和退出码。 |
| `stamp_article_version.py` | 将构建 HTML 绑定到精确 UTF-8 Markdown 源的摘要和版本。 | 站点/文章构建；`test_stamp_article_version.py`。 |
| `sync_ui_localizations.py` | 编译应用 target 导出 `stringsdata`，补充源码提取并同步应用 UI catalog 和 Core 展示资源。 | 本地化专题；`test_sync_ui_localizations.py`。默认直接维护主表；临时协作片段须在同次变更用 `--merge-reviewed-translations` 合并归档。 |

本地化检查会用 SwiftPM 编译 `PersonalSitePublisherMac`，按源码逐一读取编译器导出的 `Localizable` 键；缺少任何应用源码的导出即失败。旧的 `genstrings` 和显式源码提取仅补充编译器未推断的键。编译器键保留 `%@`、`%lld` 等实际类型，再与主词典生成的中英文 catalog 比对。导出文件仅放在忽略的临时构建目录中，检查结束后移除。

## 内部实现与共享组件

这些文件供上面的入口调用，维护者不应把它们扩展成新的用户入口。

| 文件 | 职责 | 主要调用者 / 验证方式 |
|---|---|---|
| `analyze_markdown_scroll_trace.py` | 解析 Markdown/rich scroll/typing 导出，按 signpost 窗口输出可审计摘要。 | `capture_release_performance_trace.sh` 或人工性能分析；检查 JSON schema 和 review 标记。 |
| `bundle_output_lock.sh` | 提供目录原子锁，保护 app bundle 替换临界区；被 source 时不产生副作用。 | `build_and_run.sh`、打包工具；`test_build_and_run_lock.sh`。 |
| `manage_build_cache.py` | 盘点并只清理允许重建的本地构建缓存。 | 维护/CI 清理；`test_manage_build_cache.py`。 |
| `quality_gate_common.py` | 提供 Swift 质量门共享 schema、差异和离线辅助函数。 | `check_swift_coverage.py`、相关 gate；由各自回归测试覆盖。 |
| `release_artifact_manifest.py` | 创建并验证 Release 应用 artifact 交接 manifest；构建输入摘要包含本地共享 Swift 包的声明和产品源码，输入缺失或变化时拒绝复用旧产物。 | `check_ui_runtime.sh`、直接打包；`test_release_artifact_manifest.py`。 |
| `release_gate_runner.py` | 读取 `release_checks.json`，选择并执行质量门，输出结果 schema。 | `check_release_gate.sh`；`test_release_gate_runner_contract.py`、`test_release_gate_selection.py`。 |
| `run_swift_test_process.py` | 在独立进程中运行完整 SwiftPM 测试清单，负责分片、证据和子进程清理。 | `run_swift_tests.sh`、release gate；`test_run_swift_test_process.py`、`test_run_swift_tests.py`。 |
| `verify_cloud_signature.py` | 核对已签名 Mac 应用与嵌入的 iCloud provisioning profile：App ID、团队、CloudKit/iCloud Documents/推送环境、有效期及签名证书。 | `build_and_run.sh` 的云调试签名与 `package_direct_release.sh` 的云发行验证；`test_verify_cloud_signature.py` 离线验证匹配、过期与错配；失败返回非零且不修改应用包。 |
| `window_visibility_probe.swift` | 等待指定 PID 的可见、前置窗口并输出运行时证据。 | `build_and_run.sh --verify` 或人工启动验证；编译为临时 probe 后运行。 |

`verify_cloud_signature.py` 是两个现有签名入口共享的只读核对组件，不能只靠其中一个入口的参数检查覆盖最终签名。输入依次为 profile 路径、已签名 `.app` 路径和 `Development` 或 `Production`；成功输出一行匹配结果，任何缺项或错配均非零退出。它不生成文件或联系 Apple；真实云端可用性仍由签名后的设备测试证明。若以后改用统一的 Xcode 托管签名并有等效的最终产物核对，可连同两个调用点退役本组件。

## 自测脚本

以下 `test_` 文件是脚本契约的回归测试。清单内的自测由 `--tooling` 调用，其余由领域门禁组合或按需运行；精确范围用 `--tooling --list` 查询。下表列出对应实现，不表示实现会反向调用自己的测试。

| 文件 | 职责 | 对应实现 / 运行方式 |
|---|---|---|
| `test_benchmark_swift_module_builds.py` | 验证 Swift 模块构建基准的参数、摘要和 fixture 行为。 | `benchmark_swift_module_builds.py`；Python fixture。 |
| `test_build_and_run_lock.sh` | 验证 app bundle 并发替换锁互斥且可释放。 | `bundle_output_lock.sh`；Bash fixture。 |
| `test_build_version_gate.sh` | 验证版本 gate 对一致、不一致和缺失输入的判定。 | `check_build_version.sh`；Bash fixture。 |
| `test_capture_release_performance_trace.sh` | 验证性能 trace 采集入口的参数、输出和失败路径。 | `capture_release_performance_trace.sh`；Bash fixture。 |
| `test_check_test_isolation.py` | 验证测试隔离源检查能拒绝应用默认持久化。 | `check_test_isolation.py`；Python fixture。 |
| `test_manage_build_cache.py` | 验证构建缓存 allow-list、预览和清理契约。 | `manage_build_cache.py`；Python fixture。 |
| `test_package_direct_release.sh` | 验证直接分发打包的隔离环境、签名调用和失败语义。 | `package_direct_release.sh`；Bash fixture。 |
| `test_verify_cloud_signature.py` | 验证 iCloud profile 与签名证书、有效期和云权限不匹配时会阻断。 | `verify_cloud_signature.py`；离线 Python fixture。 |
| `test_public_snapshot_export.sh` | 验证公开快照导出为空目录、敏感内容和 checker 的边界。 | `export_public_snapshot.sh`、`check_public_snapshot.sh`；Bash fixture。 |
| `test_quality_baseline_policy.py` | 验证质量阈值不能静默放宽。 | `check_quality_baseline_policy.py`；Python fixture。 |
| `test_release_artifact_manifest.py` | 验证 Release artifact manifest 的创建、哈希、缺失和漂移。 | `release_artifact_manifest.py`；Python fixture。 |
| `test_release_gate_runner_contract.py` | 验证 gate runner 的超时、增量输出和 artifact 绑定。 | `release_gate_runner.py`；Python fixture。 |
| `test_release_gate_selection.py` | 统一验证 quick/tooling 选择与 profile 归属，避免各检查重复定义调度规则。 | `check_release_gate.sh`、`release_gate_runner.py`；Python fixture。 |
| `test_release_performance_benchmarks.py` | 验证 Release 性能驱动器拒绝跳过或缺失证据。 | `run_release_performance_benchmarks.py`；Python fixture。 |
| `test_repository_source_boundary.sh` | 验证源码边界、链接 worktree 和 release 模式。 | `check_repository_source_boundary.sh`；Bash fixture。 |
| `test_run_swift_test_process.py` | 验证 Swift 测试清单解析、分片和进程契约。 | `run_swift_test_process.py`；Python fixture。 |
| `test_run_swift_tests.py` | 验证完整 Swift 测试入口的隔离进程、日志和清理。 | `run_swift_tests.sh`；Python fixture。 |
| `test_stamp_article_version.py` | 验证 HTML 版本戳与精确 Markdown 源摘要绑定。 | `stamp_article_version.py`；Python fixture。 |
| `test_swift_accessibility_fields.py` | 验证 accessibility field gate 的正反 fixture。 | `check_swift_accessibility_fields.py`；Python fixture。 |
| `test_swift_coverage_gate.py` | 验证覆盖率目标、变更行和失败输出。 | `check_swift_coverage.py`；Python fixture。 |
| `test_swift_format_gate.sh` | 验证 Swift format gate 的输入、fixture 和结果文件。 | `check_swift_format.sh`；Bash fixture。 |
| `test_swift_module_boundaries.py` | 验证 SwiftPM 模块边界及非法依赖 fixture。 | `check_swift_module_boundaries.py`；Python fixture。 |
| `test_swift_release_build_gate.sh` | 验证发布构建 gate 转发参数、环境和失败语义。 | `check_swift_release_build.sh`；Bash fixture。 |
| `test_swift_safety_gate.py` | 验证 Swift 安全规则、例外清单和回归 fixture。 | `check_swift_safety.py`；Python fixture。 |
| `test_swift_strict_build_gate.sh` | 验证 Swift 严格并发构建参数和 target 选择。 | `check_swift_strict_build.sh`；Bash fixture。 |
| `test_sync_ui_localizations.py` | 验证本地化提取、主表同步和 reviewed merge。 | `sync_ui_localizations.py`；Python fixture。 |
| `test_typography_gate.py` | 验证最小字号和 typography 违规定位。 | `check_typography.py`；Python fixture。 |
| `test_ui_product_contract.py` | 用真实视图和故意回归 fixture 验证 UI 产品契约。 | `check_ui_product_contract.sh`；Python fixture。 |

## 长期契约与退役规则

- `build_and_run.sh` 是唯一标准构建启动入口；发布包统一从 `package_direct_release.sh` 进入。质量检查统一从 `check_release_gate.sh` 进入：`--quick` 运行快速门，`--tooling` 运行脚本自测，`--profile direct|all` 选择发行渠道配置，`--list` 列出清单，`--check ID` 运行一个已登记检查。
- 公开快照、性能、本地化等专题保留现有按需入口；它们可以被编排入口组合，但每个单项检查只负责一个类别。`test_` 文件是自测实现，不另建并行工作流入口。
- 公开快照会自动复制本 README 作为维护文档；`export_public_snapshot.sh` 与 `test_public_snapshot_export.sh` 是开发仓专用的导出/验证工具，按公开快照边界排除，不应被误报为公开快照运行时内容。
- 新脚本必须先说明既有模块或参数为何无法容纳，并记录职责、输入、输出、失败语义、调用者、测试和退役条件；否则应扩展现有入口或 gate。临时工具只能放在被忽略的 `.build/tmp`，完成前删除；若工具已进入 Git 历史，保留历史，不把临时文件变成活动入口。
- 翻译默认直接维护主表。临时协作片段必须在同一次变更中使用 `--merge-reviewed-translations` 合并并归档，不能另造长期并行主表。
- `check_swift6_migration.sh` 和 `test_swift6_migration_gate.sh` 已退役并不属于活动清单；迁移诊断退役的原因是 `Package.swift` 已全部 Swift 6。替代路径是 `--check swift-module-boundaries` 与 `--check swift-strict-build`。旧的 `swift6-migration` 缓存目录只由管理缓存工具处理历史产物，不能作为新的检查入口。
