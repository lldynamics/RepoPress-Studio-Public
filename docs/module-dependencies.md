# 模块依赖与跨模块审计

本文是当前架构维护指南，说明模块职责、依赖审查和门禁证据；不保存另一份手工依赖清单。文档与实现的优先级见[来源规则](README.md)。

## 唯一来源

| 事实 | 维护位置 |
| --- | --- |
| 实际 target、产品、内部依赖和外部 package | [Package.swift](../Package.swift)；外部版本由 [Package.resolved](../Package.resolved) 锁定 |
| 允许的生产/测试依赖、外部产品与模块映射、兼容导出 | [边界检查器](../script/check_swift_module_boundaries.py)中的策略常量；与实际声明精确比较 |
| Workbench 兼容导入数量上限 | [quality_baselines.json](../script/quality_baselines.json)的 `swiftModuleBoundaryMaximums`；不得为了通过检查而抬高 |
| 检查调用、输入和证据 | [release_checks.json](../script/release_checks.json)中的 `swift-module-boundaries` 与 `swift-module-boundaries-tests` |

直接查询检查器所执行的规则，无需 Swift、构建或联网：

```bash
python3 script/check_swift_module_boundaries.py --describe-policy
```

输出中的 `productionDependencies` / `testDependencies` 是精确内部依赖集合；未列出的边不允许引入，删除已列出的边也要同步审查策略。`externalProductDependencies` 指定每个 target 允许依赖的产品及 package，`externalProductModules` 说明产品提供的导入模块。产品名不一定等于模块名，例如同一个 Markdown parser 产品还提供 inline parser 模块。

## 模块职责与方向

| 层次 | 职责和方向 |
| --- | --- |
| `PublishingCoreSupport`、`PublishingDomainContracts`、`BrowserExtensionProtocolSupport` | 通用基础设施、跨域值契约、扩展协议；不依赖业务或工作台 target |
| `PublishingMarkdownCore`、`PublishingGitCore`、`PublishingAICore` | 各自领域能力；仅使用策略列出的底层依赖，不反向依赖 Workbench 或 App |
| `PublishingKnowledgeCore`、`PublishingAgentContracts` | 组合所需的领域能力或契约；新增跨域边须说明必要性 |
| `PublishingWorkbenchCore` | 跨域编排、Store 与兼容适配；兼容导出集中于指定 umbrella 文件 |
| `PersonalSitePublisherMac` | macOS UI 与应用装配；直接使用领域模块时明确声明直接依赖 |
| `Tests/<target>` | 测试目标同样受精确依赖策略约束；不能用测试工程绕过生产边界 |

公共值类型优先放在合适的契约模块，领域实现留在所属 Core，跨域工作流由上层组合。不要为了复用一个类型让底层反向依赖工作台。不要通过新增 re-export 隐藏消费者的真实依赖。

## 已执行的阻断检查

- 从 SwiftPM `dump-package` 读取当前声明，拒绝未知 target、产品映射漂移、未明确启用 Swift 6、依赖集合变更和内部循环；生产与测试目标都纳入图中。
- 扫描 `Sources/<target>` 和 `Tests/<target>` 中的 Swift 导入。内部模块及已登记第三方模块必须有直接依赖，传递可达不能代替直接声明；错误包含文件和行号。
- 扫描普通、属性修饰、访问级别、scoped、跨行和分号分隔的 import；检查所有条件编译分支，屏蔽注释及普通、raw、多行字符串中的伪导入。
- `@_exported import` 只能存在于 [PublishingCoreModuleExports.swift](../Sources/PublishingWorkbenchCore/Support/PublishingCoreModuleExports.swift)，且与精确兼容导出集合一致。其他文件导出系统模块也会失败。
- 只接受标准 target 目录（默认路径或显式标准路径），拒绝自定义路径及非空 `sources` / `exclude`，避免 SwiftPM 编译范围与扫描范围偏离。扫描采取保守范围；若未来需要自定义布局，先统一导入、源码摘要和导出校验使用的文件集合，再修改此策略。
- 执行兼容导入数量上限；`--enforce-umbrella-retirement` 可进一步要求源码和测试的 Workbench 导入全部归零。

这是导入与声明审计，不是 Swift 类型检查器。它不解析符号使用，不能证明不存在通过兼容导出、动态查找、通知或共享存储形成的运行时耦合；编译和行为测试仍由现有质量流程执行。系统模块没有被第三方产品白名单穷举。

## 运行与报告

通过现有统一入口运行，无需增加脚本或第二套 CI：

```bash
./script/check_release_gate.sh --check swift-module-boundaries
./script/check_release_gate.sh --check swift-module-boundaries-tests
```

快速门已包含真实模块检查；脚本自测属于 tooling 集合，以运行器 `--quick --list` / `--tooling --list` 为准。开发仓现有 [质量工作流](../.github/workflows/quality.yml)在 PR、主分支推送和定期任务中调用该门禁；公开快照使用其安装的工作流。这里描述配置，不证明远端任务已经启用或执行成功。

成功报告写入 `.build/swift-module-boundaries.json`，包含实际依赖图、拓扑顺序、源码导入边、兼容层使用数量及源码/清单摘要。`dependencyAudit` 额外提供：

- `declaredDependenciesWithoutImports`：已声明但源码未观察到直接 import 的内部边，供审查是否多余。兼容 re-export 等情况也会产生候选，不能据此自动删除依赖或判失败。
- `transitiveDependencies`：每个 target 的完整可达集合，包含直接和间接依赖，便于发现依赖面扩张；可达不代表允许直接导入。

报告按名称稳定排序，可以比较同源环境中的变化。失败时同一报告路径被写为 `status: failed` 并保留错误，避免旧成功报告被当作本次证据；如输出目录不可写，必须以非零退出码和错误日志为准。

## 修改依赖时

1. 先检查是否可以通过现有契约或上层组合解决，说明新增边的责任归属及替代方案。
2. 在同次变更更新 `Package.swift`、检查器的对应精确策略和 [回归 fixture](../script/test_swift_module_boundaries.py)。外部产品同时维护 package 身份与导入模块映射，不能只把新名称加入放行列表。
3. 运行真实模块门及其自测；涉及源代码时，再运行对应 Swift 测试与快速门。检查失败是待修复事实，不能把基线上调或修改文档当作修复。
4. 审阅新增可达路径和无直接导入的候选；删除依赖前通过编译与行为测试确认。架构职责发生变化时更新本文，精确边仍由检查器输出。
