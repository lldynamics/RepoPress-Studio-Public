# AI 对话与 Agent：当前架构与演进边界

> 状态：实现现状文档
> 更新时间：2026-08-23
> 适用版本：macOS 14+、Swift 6

本文记录 RepoPress Studio 当前已经落地的 AI 对话、上下文和 Agent
边界。源码和测试是最终事实来源；本文不保留未落地的窗口设计、工期承诺
或路线图。

## 1. 能力总览

当前实现包含两种明确的会话作用域：

| 作用域 | 持久化语义 | 上下文默认值 |
| --- | --- | --- |
| `AIConversationScope.general` | `storageKey == "general"`，不归属任何草稿 | 通用对话；不会因为当前选中的文章或发布界面而自动附加内容 |
| `AIConversationScope.draft(UUID)` | `storageKey == "draft:<uuid>"` | 与指定草稿关联的文章、站点和用户选定引用 |

`AIConversation.draftID` 是从 `scope` 派生的可选兼容投影：通用会话返回
`nil`，草稿会话返回草稿 ID。新代码应优先判断 `scope`，避免把通用会话误当
成文章会话。

通用会话已经具备新建、切换、归档、模型/连接档案选择、思考级别、知识库
策略、图片附件、流式回复和手动重试。连接档案 ID 明确保存在会话中，密钥
仍由 Keychain 提供，不写入会话快照。

## 2. 上下文与隐私边界

`AIContextAssembler.generalEnvelope` 是通用请求的入口。它只接收调用方
显式提供的上下文引用、显式提示和知识库快照，不会自行扫描当前编辑器、
当前草稿、仓库或发布状态。

因此：

- 通用会话默认只发送会话消息和通用系统边界。
- 文章、段落、知识条目只有在用户选择并经过当前发送链路授权后才进入请求。
- 知识库检索遵循会话的 `KnowledgeRetrievalPolicy`；资料授权撤销、绑定漂移
  或远程请求确认失败时，发送在传输前终止。
- AI 请求经过数据共享同意、凭据解析、载荷预览和授权确认；凭据不进入
  持久化 JSON，也不进入公开仓库。

通用会话可以在用户明确提出并获得相应权限时通过 Agent 工具创建或操作草稿；
这不改变会话本身的 `general` 归属，也不等于隐式读取当前文章。

## 3. ChatCompletion 协议与 Provider 能力

请求/响应模型已包含 OpenAI-compatible 的工具协议：

- `AIChatCompletionRequest.tools` 与 `toolChoice` 描述本轮可用工具。
- `AIChatMessage.toolCalls`、`toolCallID` 表示助手工具调用和工具结果消息。
- `AIChatCompletionResult.toolCalls` 表示完整响应中的调用。
- `AIChatStreamUpdate.toolCallDeltas` 和累积的 `toolCalls` 支持流式工具块；
  SSE 适配器按调用索引合并增量。

`AIChatCompletionClient` 在请求归一化时读取具体连接档案和模型的
`AIProviderProtocolCapability.toolCalling` 状态。能力状态有
`supported`、`unsupported` 和 `unknown` 三种；探测服务负责生成证据。
普通文本聊天可以在没有 Agent 能力时继续使用，Agent 执行则要求能力状态
为 `supported`，否则以能力不可用结束，不伪造工具结果。

不同 Provider 的协议细节和能力可能不同，不能把某个 Provider 的探测结果
当成全局保证。未知能力、无效响应或工具协议历史不匹配都必须维持失败关闭
的行为。

## 4. Agent 执行与安全边界

Agent 循环由 `WorkbenchAIAgentLoopService` 驱动，工作台通过
`WorkbenchAIStore+AgentLoop.swift` 接入，待确认的继续执行由
`WorkbenchAIStore+AgentContinuation.swift` 处理。工具定义和参数校验来自
`WorkbenchAutomationService.swift` 的白名单注册表。

一轮执行的基本流程是：

```text
用户消息 → 模型请求（显式工具白名单） → 文本回复或 tool_calls
                                      ├─ 只读且允许自动执行 → 执行并回传结果
                                      └─ 外部影响或写操作 → 生成待确认计划/检查点
```

安全约束包括：

- 工具名、参数 JSON、调用 ID、目标草稿版本和允许命令集合在执行前校验。
- 未知工具、重复调用 ID、无效 JSON、参数不匹配、能力/权限不足时整轮终止，
  不执行后续调用。
- Agent 能力限定为注册表中的工作台命令，不含通用 shell、任意路径文件写入或
  任意外部命令。
- 具有外部影响的操作不会静默落盘。命令描述中的
  `allowsAgentAutomaticExecution` 决定是否可以自动执行，其余操作进入
  `awaitingConfirmation`，由用户审阅计划后继续。
- `WorkbenchAIAgentLoopLimits` 同时限制模型轮数、单轮/总工具调用数、参数
  与结果字节数、助手输出和完整 transcript 大小。默认值为 6 轮、单轮 4 次、
  总计 12 次调用，并对各类字节数设上限。
- 取消、模型传输错误、工具执行错误和限制触发都会产生明确终止状态；失败
  不会把未验证的助手轮次当成成功结果。
- `WorkbenchAIAgentLoopCheckpoint` 保存可信边界、待处理调用、已执行记录、
  预算和允许命令。恢复前会重新校验 transcript、草稿版本、能力、权限和
  检查点完整性；校验失败时不联系模型，也不执行工具。

知识库工具还要满足资料授权绑定。授权变化、知识快照漂移或远程确认失效时，
请求在知识内容继续流动前关闭。

## 5. 当前 UI 形态

应用场景目前只有一个：

```swift
WindowGroup("RepoPress Studio", id: "main-workbench") { ... }
```

AI 主要呈现在主工作台的 Inspector/上下文面板中，通用和草稿会话共用该表面，
通过界面中的上下文模式、会话选择和模型切换完成操作。当前没有独立的 AI
`Window`、迷你 `NSPanel` 或全局唤起快捷键。独立 AI 窗口、迷你面板和跨窗口
聚焦属于后续产品方向；实现前需要补充窗口生命周期、共享 Store、恢复行为、
辅助功能和多窗口并发策略，不能在文档或发布说明中当作现有功能。

## 6. 维护规则与剩余演进项

维护本文时应遵循以下边界：

1. 先更新源码和回归测试，再更新本索引；不要把设计草图写成完成状态。
2. 新增 Agent 命令必须进入注册表、能力白名单、参数验证、确认策略、执行
   记录和恢复校验，并补充未知工具、权限变化、取消及限制触发测试。
3. 新增 Provider 时必须单独记录工具调用、流式响应、结构化输出和视觉能力
   的探测证据；`unknown` 不能被展示为可用。
4. 若实现独立窗口或迷你面板，应先定义 Store 共享和关闭/恢复语义，再添加
   UI；不得通过复制第二个 AI Store 绕过会话一致性和授权边界。

尚未实现、但可以单独立项的方向：独立 AI 窗口和迷你面板、多窗口会话协同、
更细的 Provider 能力提示、工具运行记录的可视化，以及在不扩大权限的前提下
增加更多只读工作台工具。这些方向不改变当前通用会话和 Agent 的安全默认值。

## 7. 源码与测试索引

核心实现：

- `Sources/PublishingWorkbenchCore/Models/AIConversation.swift`
- `Sources/PublishingWorkbenchCore/Services/AIContextAssembler.swift`
- `Sources/PublishingWorkbenchCore/Services/AIChatCompletionModels.swift`
- `Sources/PublishingWorkbenchCore/Services/AIChatCompletionResponses.swift`
- `Sources/PublishingWorkbenchCore/Services/AIChatCompletionClient+RequestNormalization.swift`
- `Sources/PublishingWorkbenchCore/Services/AIChatCompletionClient+SSE.swift`
- `Sources/PublishingWorkbenchCore/Services/AIChatCompletionClient+Streaming.swift`
- `Sources/PublishingWorkbenchCore/Models/AIProviderCapability.swift`
- `Sources/PublishingWorkbenchCore/Services/AIProviderCapabilityProbeService.swift`
- `Sources/PublishingWorkbenchCore/Services/WorkbenchAIAgentLoopService.swift`
- `Sources/PublishingWorkbenchCore/Models/WorkbenchAIAgentLoopModels.swift`
- `Sources/PublishingWorkbenchCore/Services/WorkbenchAutomationService.swift`
- `Sources/PublishingWorkbenchCore/Stores/WorkbenchAIStore+GeneralChat.swift`
- `Sources/PublishingWorkbenchCore/Stores/WorkbenchAIStore+AgentLoop.swift`
- `Sources/PublishingWorkbenchCore/Stores/WorkbenchAIStore+AgentContinuation.swift`
- `Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift`
- `Sources/PersonalSitePublisherMac/Views/AIChat/AIChatWorkspaceInspectorComponents.swift`

回归覆盖：

- `Tests/PublishingWorkbenchCoreTests/AIConversationScopeMigrationTests.swift`
- `Tests/PublishingWorkbenchCoreTests/WorkbenchGeneralAIChatTests.swift`
- `Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift`
- `Tests/PublishingWorkbenchCoreTests/WorkbenchAIAgentLoopServiceTests.swift`
- `Tests/PublishingWorkbenchCoreTests/WorkbenchAIStoreAgentLoopIntegrationTests.swift`
- `Tests/PublishingWorkbenchCoreTests/WorkbenchAgentKnowledgeAuthorizationTests.swift`
