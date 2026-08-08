# AI 对话能力升级设计文档

> 范围：① 独立对话窗口 / 迷你对话（Part A）＋ ⑥ Agent 工具调用（Part B）
> 状态：设计稿，待评审
> 面向版本：RepoPress（macOS 14+，Swift 5.9+）

---

## 0. 背景与目标

RepoPress 已具备完整的 AI 对话底座（多 Provider、SSE 流式、会话持久化、文章上下文、写作辅助动作），
但目前对话入口**绑定在文章侧栏 Inspector 内**，且协议层**不支持工具调用（tool calling）**。

本设计解决两个核心问题：

1. **对话脱离文章**：让 AI 对话成为一等公民——独立窗口、快捷键唤起、通用对话（不依赖草稿）。
2. **从“问答”到“干活”**：让模型能调用本地工具（检索知识库、抓取 URL、读取/修改草稿、检查站点状态），
   把对话升级为可执行的 Agent。

设计原则：

- **复用优先**：不重造轮子，尽量复用 `WorkbenchAIStore` / `AIChatCompletionClient` / 现有写作辅助服务。
- **渐进式**：每个方向分阶段落地，每阶段可独立验收、独立发布。
- **安全默认**：所有“写”类工具必须显式确认；凭据不落盘（继续走 Keychain）。

---

## 1. 现状盘点（与本次设计相关的关键事实）

### 1.1 已具备

| 能力 | 位置 | 说明 |
| --- | --- | --- |
| 多 Provider 配置 | `Models/AIProviderConfig.swift`、`Models/AIConnectionProfile.swift` | OpenAI 兼容 / DeepSeek / OpenRouter / 本地 Ollama / 自定义，多档案 |
| 流式传输（SSE） | `Services/AIChatCompletionClient.swift` | `AsyncThrowingStream`、字节上限、用量统计、`AIChatStreamingTransport` |
| 会话持久化 | `Models/AIConversation.swift`、`Stores/AIWorkspaceStore.swift` | 每条会话带 `draftID`，按文章归档 |
| 文章上下文 | `Stores/WorkbenchAIStore+ChatSessions.swift`、`WorkbenchAIStore+ContextReferences.swift` | `contextMode`（site/general）、上下文引用、段落聚焦 |
| 写作辅助动作 | `Services/AIPublishingAssistantService*.swift`、`AIPublishingActionConvergence.swift` | 改写、审查、元数据修复、HTML 翻译、代码块、直接编辑等 |
| 知识库语义检索 | `Stores/KnowledgeDatabase+Search.swift` | FTS + LIKE + 语义向量（`KnowledgeChunkEmbedding`） |
| 数据共享同意 | `Services/AIDataSharingConsentStore.swift` | 已有 consent 体系 |
| 窗口/场景 | `App/PersonalSitePublisherMacApp.swift` | 单一 `WindowGroup("main-workbench")` + AppDelegate 管理 |

### 1.2 关键约束（设计必须绕开的坑）

1. **`AIConversation.draftID: UUID` 为非可选**，`activeAIConversationIDsByDraftID: [UUID: UUID]` 以 draft 为主键。
   → 通用对话需要把 `draftID` 可空化，或引入独立“通用会话”存储域。
2. **`sendAIChatMessage` 强制要求草稿**（无草稿时报「请先选择一篇文章」）。
   → 需要一条不依赖草稿的发送路径，且仍能按需“附加”文章上下文。
3. **`AIChatCompletionClient` 请求模型没有 `tools` / `tool_choice`，响应模型没有 `tool_calls`**。
   → Agent 方向必须先扩展协议层（这是 Part B 的前置依赖）。
4. **Provider 能力差异大**（本地 Ollama、OpenAI 兼容 vs DeepSeek 原生）。
   → 工具调用必须带“能力探测 + 优雅降级”。

---

# Part A：独立对话窗口 / 迷你对话

## A1. 目标与非目标

**目标**

- 新增独立的 AI 对话窗口（`⌘⇧Space` 唤起），支持**不依赖文章**的通用对话。
- 通用对话可“附加”当前文章 / 选中段落 / 知识库条目作为上下文（而不是强制绑定）。
- 提供轻量“迷你对话”弹出层：快捷键唤起、单轮快问快答、Esc 关闭，适合随手提问。
- 独立窗口内具备完整能力：流式输出、模型切换、会话历史、图片附件、代码块应用、插入正文。

**非目标（本阶段不做）**

- 不做会话的云端同步（继续纯本地持久化）。
- 不做多窗口同时打开同一条会话的冲突解决（单窗口即可，后续再说）。

## A2. 数据模型解耦：通用对话作用域

### A2.1 方案选型

| 方案 | 说明 | 评价 |
| --- | --- | --- |
| A. `draftID` 可空化 | `AIConversation.draftID: UUID?`，`nil` 表示通用会话 | ✅ 改动小、语义清晰；需迁移已持久化数据（解码兼容） |
| B. 独立存储域 | 新增 `generalConversations: [AIConversation]` 数组 | 隔离干净，但双份存储/双份 API，长期维护成本高 |

**结论：选 A**。理由：`AIConversation` 已自包含会话全部状态（`sessionState`），
`draftID` 仅是“归属键”。可空化后：

- 旧数据：`draftID` 仍是必填字段，解码不受影响（只把声明改为可选）。
- `activeAIConversationIDsByDraftID` 的键保持 `UUID` 不变，仅当 `draftID == nil` 时走新的
  `activeGeneralConversationID: UUID?` 字段（追加，非覆盖）。

### A2.2 迁移策略

1. `AIConversation.draftID` 声明改为 `UUID?`；`Codable` 用 `decodeIfPresent`，旧存档自动兼容。
2. `AIWorkspacePersistence` 增加可选字段 `activeGeneralConversationID: UUID?`，默认 `nil`，向前兼容。
3. 新增会话时若 `draftID == nil`，写入 `aiConversations` 数组（`draftID: nil`），
   不进入 `activeAIConversationIDsByDraftID`。
4. 增加一次性的本地校验：确保 `nil` draft 会话不进 `maximumConversationsPerDraft` 计数
   （沿用全局 `maximumConversationCount` 即可）。

## A3. 独立对话窗口

### A3.1 场景注册

在 `App/PersonalSitePublisherMacApp.swift` 增加：

```swift
Window("AI 对话", id: "ai-chat-window") {
  AIChatWindowRootView()
    .frame(minWidth: 420, minHeight: 560)
}
.defaultSize(width: 520, height: 720)
```

- 窗口数据流：`AIChatWindowRootView` 通过 `@EnvironmentObject` / AppDelegate 持有的 `WorkbenchStore`
  拿到 `WorkbenchAIStore`（与主工作窗共享同一 store，避免双实例状态分裂）。
- 若 store 尚未就绪（主窗未初始化），窗口显示 `ContentUnavailableView` + “打开主工作窗”按钮。

### A3.2 视图树

```
AIChatWindowRootView
├── AIChatWindowToolbar        // 会话选择、新建会话、模型快速切换、上下文附加、设置
├── AIChatMessageList          // 复用现有 AIChatWorkspaceInspector 的消息渲染组件
│   ├── 消息气泡（用户/助手）
│   ├── 代码块（复制/应用/插入光标）
│   └── 流式输入中的打字机效果（沿用 aiChatStreamPublishInterval 节流）
├── AIChatWindowComposer       // 复用 AIChatWorkspaceInspectorComposer 能力
│   ├── 文本输入 + 图片附件
│   ├── 上下文模式切换（通用 / 站点+文章）
│   └── 发送 / 停止生成
└── AIChatContextAttachmentBar // 可附加：当前文章、选中段落、知识库引用（@ 入口）
```

**复用清单**（尽量直接复用现有 View / Service，减少重复 UI）：

- `Views/AIChatWorkspaceInspectorComposer.swift`
- `Views/AIChatWorkspaceInspectorHeader.swift`（模型切换、会话选择）
- `Views/AIChatModelQuickSwitchSheet.swift`
- `Services/AIPublishingChatConversationPresentation.swift`（标题生成）
- `Stores/WorkbenchAIStore+ChatReplies.swift` 的发送链路（改造见 A4.2）

### A3.3 快捷键与命令

在 `.commands` 中注册：

```swift
CommandGroup(after: .appInfo) {
  Button("AI 对话") { openWindow(id: "ai-chat-window") }
    .keyboardShortcut(" ", modifiers: [.command, .shift])
}
```

同时在 `WorkbenchLaunchRootView` 用 `WorkspaceCommandPaletteAction` 思路，把
`⌘⇧Space` 的行为做成“若窗口已开则聚焦，未开则打开并聚焦”。

## A4. 迷你对话（Mini Chat）

### A4.1 形态

- **形态**：悬浮输入条（`NSPanel` + `nonactivatingPanel`）或 SwiftUI `.overlay` 全屏置顶浮层。
  推荐 `NSPanel`（`NSPanel.StyleMask.nonactivatingPanel`），因为它不抢主窗焦点、行为更接近
  Spotlight / Raycast。
- **唤起**：同一快捷键 `⌘⇧Space` 双语义——短按唤起迷你对话；迷你对话内再次 `⌘⇧Space`
  或“展开”按钮则切换为完整窗口。
- **交互**：
  - `Enter` 发送，`Esc` 关闭，`↑/↓` 切换历史提问。
  - 支持 `/` 前缀命令：`/ask`（通用）、`/with 文章名`（附加当前文章）、`/k 关键词`（附加知识库检索结果）。
  - 发送后原地显示流式回复摘要（最多 ~300 字）+ “在窗口打开”按钮。

### A4.2 发送路径（关键改造）

新增不依赖草稿的发送方法（放在 `WorkbenchAIStore+ChatReplies.swift`）：

```swift
public func sendAIGeneralChatMessage(
  _ text: String,
  imageAttachments: [AIChatImageAttachment] = [],
  attachedContext: AIChatWindowAttachedContext? = nil   // 可选附加：文章/段落/知识库
) async -> AIPublishingChatMessage?
```

- 内部走与 `sendAIChatMessage` 相同的：Key 校验 → 能力校验 → `beginAIChatOperation` →
  流式消费 → `upsertAIChatConversation` 链路。
- `attachedContext` 仅用于**本次请求的上下文注入**（不改变会话归属），
  并复用现有 `availableAIChatContextReferences` / `AIContextReference` 结构。
- 通用会话的 Provider 解析：`draftID == nil` 时使用“默认站点档案”或用户手动选择的档案
  （新增 `AIProviderProfileScope.general` 解析规则，见 A5）。

## A5. 文件级改动清单（Part A）

| 文件 | 改动 | 工作量 |
| --- | --- | --- |
| `Models/AIConversation.swift` | `draftID` 可空化；`decodeIfPresent`；`isGeneral` 计算属性 | S |
| `Stores/AIWorkspaceStore.swift` | 增加 `activeGeneralConversationID`；通用会话 CRUD 辅助 | M |
| `Stores/WorkbenchAIStore+ChatSessions.swift` | `prepareAIChat(for:)` 支持 nil draft；新增通用会话选择/新建 | M |
| `Stores/WorkbenchAIStore+ChatReplies.swift` | 新增 `sendAIGeneralChatMessage`；抽取公共发送核心 | M |
| `Models/AIProviderConfig.swift` | `AIProviderProfileScope.general` 档案解析 | S |
| `App/PersonalSitePublisherMacApp.swift` | 注册 `ai-chat-window` 场景 + `⌘⇧Space` 命令 | S |
| `Views/AIChatWindowRootView.swift`（新） | 窗口根视图 + 状态装配 | M |
| `Views/AIChatWindowMessageList.swift`（新） | 复用消息渲染的消息列表 | S |
| `Views/AIChatWindowComposer.swift`（新） | 复用 Composer 能力的输入区 | S |
| `Views/AIChatMiniPanel.swift`（新） | NSPanel 迷你对话浮层 | M |
| `Support/AIChatWindowPresentationSupport.swift`（新） | 窗口/浮层唤起、聚焦、切换逻辑 | S |
| `App/PersonalSitePublisherMacAppDelegate` 相关 | 窗口聚焦/恢复钩子 | S |
| 测试 | `AIConversation` 解码兼容、通用会话 CRUD、无草稿发送 | M |

> 规模估算：Part A 总计约 **1–2 周**（含测试），纯 UI + 数据层小改，无网络协议改动。

---

# Part B：Agent 工具调用

## B1. 目标与非目标

**目标**

- 协议层支持 OpenAI 兼容的 `tools` / `tool_choice` / `tool_calls`（SSE 流式 + 非流式）。
- 内置工具集 v1（只读为主 + 少量受控写操作）。
- 可中断、可确认、可追踪的 Agent 执行循环，进度在对话中实时呈现。
- 对不支持工具调用的 Provider 自动降级（退回纯文本 + prompt 约束）。

**非目标（本阶段不做）**

- 不做多 Agent / 子 Agent 编排。
- 不做任意外部命令执行、文件系统任意写入（安全边界内）。
- 不做模型自行连续多轮工具调用的“无限循环”放任（设硬上限）。

## B2. 协议层扩展（前置依赖）

### B2.1 请求侧

在 `Services/AIChatCompletionClient.swift`：

```swift
public struct AIChatTool: Codable, Hashable, Sendable {
  public enum Kind: String, Codable { case function }
  public var type: Kind
  public var function: AIChatToolFunction
}

public struct AIChatToolFunction: Codable, Hashable, Sendable {
  public var name: String
  public var description: String
  public var parameters: JSONValue   // JSON Schema 子集
}

// AIChatCompletionRequest 增加：
public var tools: [AIChatTool]?
public var toolChoice: AIChatToolChoice?   // enum: auto / none / required / named(String)
```

> `JSONValue`：项目现有 JSON 编码工具可复用；若没有，新增一个极小的 `Codable` 任意值类型。

### B2.2 响应侧

- `AIChatMessage` 增加 `toolCalls: [AIChatToolCall]?`；`AIChatToolCall` 含 `id`、`name`、`arguments(String)`。
- `AIChatMessageContent` 增加 `.toolRole` 形态，用于把“工具结果”作为 `role: "tool"` 消息回传。
- SSE 流式解析（`Services/AIChatCompletionClient.swift` 的 `recoveredStreamUpdates`）需能透传
  `tool_calls` delta；**v1 建议简化**：检测到工具调用意图后，切换到“非流式收完整 tool_calls 块”，
  文本部分仍走流式（大部分 OpenAI 兼容实现支持 `stream_options.include_usage` 与工具块一起返回）。

## B3. 工具注册中心与工具集 v1

### B3.1 注册中心

```swift
public protocol AIChatToolHandler: Sendable {
  var name: String { get }
  var description: String { get }
  var schema: JSONValue { get }                 // JSON Schema
  var requiresConfirmation: Bool { get }        // true → 写操作，需用户确认
  var permissionScope: AIChatToolPermission { get }
  func run(_ arguments: [String: JSONValue]) async throws -> AIChatToolResult
}

@MainActor
public final class AIChatToolRegistry {
  func tool(_ name: String) -> AIChatToolHandler?
  func allTools() -> [AIChatTool]
  func tools(for capability: AIProviderToolCapability) -> [AIChatTool]
}
```

### B3.2 工具集 v1（全部只读 + 2 个受控写）

| 工具 | 权限 | 确认 | 复用实现 |
| --- | --- | --- | --- |
| `knowledge.search` | 只读 | 否 | `KnowledgeDatabase+Search.swift`（FTS/LIKE/语义），返回 Top-N 命中摘要 |
| `knowledge.read` | 只读 | 否 | 读取指定知识条目正文（截断到上下文预算） |
| `draft.read` | 只读 | 否 | 读取当前文章 / 指定段落（`ArticleDraft` + `focusedParagraphID`） |
| `web.fetch` | 只读 | 否 | 复用 `RSSNetworkHTTPClient` 的抓取管线；仅 HTTPS、大小上限、去重 |
| `site.status` | 只读 | 否 | 复用 `SiteMaintenance` / 状态端点检查，返回部署健康摘要 |
| `draft.applyEdit` | 写 | **是** | 复用 `AIPublishingChatDraftApplicationService`（diff 预览 → 确认 → 应用） |
| `draft.insertAtCursor` | 写 | **是** | 复用现有 `insertAtCursor` 应用模式 |

> 知识库语义检索已有 embedding 表，`knowledge.search` 直接可用，无需新增向量管线。

### B3.3 Provider 能力探测

在 `AIProviderCapability.swift` 增加 `supportsToolCalling: Bool`：

- OpenAI 兼容 / OpenRouter / DeepSeek（v4 系）：默认支持，可让用户关闭。
- 本地 Ollama：由 `GET /api/tags` 的模型能力或连接测试结果探测，不支持则自动降级。

## B4. 执行循环与安全模型

### B4.1 循环（AIAgentSession）

```
用户消息 → [模型调用(带 tools)] → 响应
  ├─ 纯文本 → 结束
  └─ tool_calls → 逐个执行：
       ├─ requiresConfirmation == true → 挂起，等用户确认（diff 预览）
       └─ 否则直接执行 → 结果以 role:"tool" 回传 → 回到 [模型调用]
  硬上限：单轮最多 8 次工具调用，超出强制收敛为总结文本
```

- 挂在 `WorkbenchAIStore` 下，新增 `aiAgentSessionCoordinator`（仿照现有 `aiChatOperationCoordinator`）。
- 可取消：沿用 `Task.cancel` + 现有 byte/line 上限的取消传播。

### B4.2 安全默认

1. **写操作必须确认**：`draft.applyEdit` / `draft.insertAtCursor` 默认 `requiresConfirmation`，
   在对话中渲染“变更预览卡片”（复用 `AIChatDraftDiffPreview.swift`），用户点“应用”才落盘。
2. **会话内权限可降级**：用户可在会话头部把 Agent 模式切到“仅问答”，此时 `tools` 不注入。
3. **数据边界**：`web.fetch` 仅 HTTPS、单次 ≤ 1 MB、不携带凭据（复用 `RSSSubscriptionURLPrivacy` 的凭据剥离）。
4. **Consent 复用**：知识库检索是否允许远程 AI 处理，沿用 `AIDataSharingConsentStore` 与
   `onlyRemoteAIAllowed` 参数。

## B5. 流式与进度呈现

- 对话消息模型 `AIPublishingChatMessage` 增加 `toolRunRecords: [AIChatToolRunRecord]`（本地呈现用，
  不入请求体）。
- 进度 UI：消息流中渲染工具调用卡片（工具名、状态：运行中/成功/失败/等待确认/已取消、耗时、摘要）。
- 现有 `AIChatScrollBottomPreferenceKey` 自动滚动继续生效；工具卡片不打断打字机节奏。

## B6. 降级策略

| 场景 | 行为 |
| --- | --- |
| Provider 不支持 tools | 不注入 `tools`；改用系统提示词约束“可使用以下知识：…”，并隐藏工具 UI |
| 流式不支持工具块 | 自动切非流式收工具块（B2.2），文本段保持流式 |
| 工具调用超时/失败 | 失败结果回传模型继续生成；连续 3 次失败则该轮禁用该工具 |
| 用户无确认操作 | 工具挂起超过 2 分钟自动取消并回传“用户未确认” |

## B7. 文件级改动清单（Part B）

| 文件 | 改动 | 工作量 |
| --- | --- | --- |
| `Services/AIChatCompletionClient.swift` | `AIChatTool`/`AIChatToolCall`/`toolChoice`；请求与响应字段；SSE 工具块处理 | L |
| `Services/AIChatMessageContent.swift`（或并入 client） | `.toolRole` 形态 | S |
| `Models/AIProviderCapability.swift` | `supportsToolCalling` 探测 | S |
| `Services/AIChatToolRegistry.swift`（新） | 注册中心 + schema | M |
| `Services/AIChatToolKit/`（新目录） | 7 个工具实现 + 单元测试 | L |
| `Services/AIAgentSession.swift`（新） | 执行循环、上限、取消、收敛 | M |
| `Stores/WorkbenchAIStore+Agent.swift`（新） | 会话装配、确认桥接、进度发布 | M |
| `Models/AIPublishingChatMessage.swift` | `toolRunRecords` 本地呈现字段 | S |
| `Views/AIChatToolRunCard.swift`（新） | 工具卡片 UI（复用现有视觉样式） | M |
| `Views/AIChatDraftDiffPreview.swift` | 复用写操作确认 | S（复用） |
| 测试 | 协议编解码、循环上限、降级、写确认、凭据剥离 | L |

> 规模估算：Part B 协议 + 工具集 v1 约 **2–3 周**（含测试），是两部分中工作量最大的。

---

## 3. 分期路线图

| 阶段 | 内容 | 依赖 | 验收标准 |
| --- | --- | --- | --- |
| **P0（Part A 数据层）** | `AIConversation.draftID` 可空化 + 迁移 + 通用会话 CRUD | 无 | 旧存档无感迁移；通用会话可持久化 |
| **P1（Part A 独立窗口）** | 窗口场景 + 视图树 + `sendAIGeneralChatMessage` + `⌘⇧Space` | P0 | 无草稿可对话；可附加文章/段落/知识库 |
| **P2（Part A 迷你对话）** | NSPanel 浮层 + `/` 命令 + 摘要展开 | P1 | 3 秒内唤起；Esc 关闭；可转完整窗口 |
| **P3（Part B 协议层）** | tools/tool_calls 编解码 + 能力探测 | 无（可与 P0 并行） | 三款 Provider（DeepSeek/OpenAI 兼容/Ollama）端到端通 |
| **P4（Part B 工具集 v1）** | 注册中心 + 7 工具 + 执行循环 + 确认桥接 | P3 | 对话中可检索知识库/抓 URL/改草稿（带确认） |
| **P5（打磨）** | 工具卡片 UI、用量统计、降级兜底、回归测试 | P4 | 全流程稳定，无回归 |

建议执行顺序：**P0 → P1 → P3 → P2 → P4 → P5**（P3 协议层尽早启动，因为它独立且是 Agent 前置）。

---

## 4. 风险与开放问题

1. **SSE 工具块兼容性**：不同实现（OpenAI / DeepSeek / Ollama）对 `tool_calls` 流式块格式有差异。
   → P3 用真实 Provider 各跑一遍端到端夹具，必要时 v1 统一走“非流式收工具块”。
2. **通用会话的 Provider 归属**：无草稿时用哪个档案/站点？建议默认“上次使用的档案 + 全局默认”，
   并在窗口工具栏显式展示，避免用户困惑。
3. **上下文预算**：工具结果回传会吃掉 token。→ 每个工具结果强制截断（默认 ≤ 8 KB），
   并复用 `AIConversation` 的 `maximumTextCharacters` 预算。
4. **确认桥接的并发**：写工具挂起时若用户同时发起新消息，需锁住会话输入（复用 `isChatRunning` 语义）。
5. **`⌘⇧Space` 冲突**：该组合在部分输入法/系统设置下可能被占用，需提供设置项可改键位。

---

## 附录：复用资产速查

| 需求 | 复用 |
| --- | --- |
| 消息渲染 / 代码块 | `Views/AIChatWorkspaceInspector*.swift` |
| 会话选择 / 模型切换 | `Views/AIChatConversationPicker.swift`、`AIChatModelQuickSwitchSheet.swift` |
| 标题生成 | `Services/AIPublishingChatConversationPresentation.swift` |
| 知识检索 | `Stores/KnowledgeDatabase+Search.swift` |
| 抓取管线 | `Services/RSSNetworkHTTPClient`、`RSSSubscriptionURLPrivacy` |
| 草稿编辑应用 | `Services/AIPublishingChatDraftApplicationService.swift`、`AIChatDraftDiffPreview.swift` |
| 站点健康 | `SiteMaintenance` 相关服务 |
| 凭据存储 | `KeychainTokenStore`（AIProvider） |
| 数据同意 | `AIDataSharingConsentStore` |
