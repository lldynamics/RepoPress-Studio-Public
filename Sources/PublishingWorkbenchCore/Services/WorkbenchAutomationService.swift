import Foundation

public enum WorkbenchAutomationRegistry {
  private static let entries: [WorkbenchAutomationRegistryEntry] = [
    entry(
      .openSection,
      title: "打开工作区",
      detail: "切换到命令面板允许的工作区",
      systemImage: "sidebar.left",
      risk: .readOnly,
      arguments: [.section],
      required: [.section]
    ),
    entry(
      .selectDraft,
      title: "打开文章",
      detail: "按稳定文章 ID 选择并打开文章",
      systemImage: "doc.text.magnifyingglass",
      risk: .readOnly,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .createDraft,
      title: "新建文章",
      detail: "创建一篇可从回收站恢复的本地草稿",
      systemImage: "square.and.pencil",
      risk: .reversible,
      arguments: [.value],
      allowsAgentAutomaticExecution: true
    ),
    entry(
      .focusEditor,
      title: "聚焦编辑器",
      detail: "打开写作页并将焦点移到指定编辑字段",
      systemImage: "cursorarrow.rays",
      risk: .readOnly,
      arguments: [.draftID, .editorField],
      required: [.draftID, .editorField]
    ),
    entry(
      .showInspector,
      title: "打开 Inspector",
      detail: "显示当前工作区的检查面板",
      systemImage: "sidebar.right",
      risk: .readOnly
    ),
    entry(
      .runPreflight,
      title: "运行发布检查",
      detail: "检查当前文章的元数据、正文和发布风险",
      systemImage: "checkmark.seal",
      risk: .readOnly,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .refreshPublishPreview,
      title: "刷新发布预览",
      detail: "重新生成当前文章的本地发布预览",
      systemImage: "arrow.clockwise",
      risk: .readOnly,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .saveWorkbench,
      title: "保存工作台",
      detail: "立即保存当前本地更改",
      systemImage: "square.and.arrow.down",
      risk: .reversible
    ),
    entry(
      .updateMetadata,
      title: "修改文章元数据",
      detail: "预览后修改标题、Slug、摘要或 Tags",
      systemImage: "tag",
      risk: .contentChange,
      arguments: [.draftID, .metadataField, .value, .values],
      required: [.draftID, .metadataField],
      semanticRule: .metadataValue
    ),
    entry(
      .appendToBody,
      title: "追加正文",
      detail: "预览后把 Markdown 追加到文章末尾",
      systemImage: "text.append",
      risk: .contentChange,
      arguments: [.draftID, .content],
      required: [.draftID, .content]
    ),
    entry(
      .replaceBody,
      title: "替换正文",
      detail: "预览后替换整篇 Markdown 正文",
      systemImage: "arrow.left.arrow.right",
      risk: .contentChange,
      arguments: [.draftID, .content],
      required: [.draftID, .content]
    ),
    entry(
      .deleteDraft,
      title: "移到回收站",
      detail: "把文章移到回收站，不立即删除仓库文件",
      systemImage: "trash",
      risk: .externalEffect,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .writeLocalRepository,
      title: "写入本地仓库",
      detail: "把当前文章的发布文件写入已授权仓库",
      systemImage: "externaldrive",
      risk: .externalEffect,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .publishOnline,
      title: "发布所有变更",
      detail: "按当前发布策略提交并推送站点中所有通过检查的待发布变更",
      systemImage: "paperplane",
      risk: .externalEffect
    ),
    entry(
      .draftRead,
      title: "读取文章",
      detail: "按大纲、全文或指定段落读取当前文章内容与字数统计",
      systemImage: "doc.text.magnifyingglass",
      risk: .readOnly,
      arguments: [.draftID, .mode, .paragraphIndices],
      required: [.draftID]
    ),
    entry(
      .searchDrafts,
      title: "搜索文章",
      detail: "在允许读取的本地公开文章中搜索，并返回有界摘要与稳定文章 ID",
      systemImage: "text.magnifyingglass",
      risk: .readOnly,
      arguments: [.query],
      required: [.query]
    ),
    entry(
      .knowledgeSearch,
      title: "搜索资料库",
      detail: "仅搜索明确允许远程 AI 使用的本地资料，并返回有界摘要与稳定资料 ID",
      systemImage: "books.vertical",
      risk: .readOnly,
      arguments: [.query],
      required: [.query]
    ),
    entry(
      .knowledgeRead,
      title: "读取资料库文档",
      detail: "按稳定资料 ID 读取明确允许远程 AI 使用的文档，内容有长度上限",
      systemImage: "doc.text.magnifyingglass",
      risk: .readOnly,
      arguments: [.documentID],
      required: [.documentID]
    ),
    entry(
      .auditContent,
      title: "审计文章内容",
      detail: "对指定文章运行本地 SEO 与内容结构检查，不访问网络",
      systemImage: "checklist",
      risk: .readOnly,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .applyDiff,
      title: "应用局部修改",
      detail: "预览后对文章指定片段进行精确替换",
      systemImage: "text.badge.checkmark",
      risk: .contentChange,
      arguments: [.draftID, .originalText, .replacementText],
      required: [.draftID, .originalText, .replacementText]
    ),
    entry(
      .generateFrontmatter,
      title: "设置文章标签",
      detail: "根据明确传入的值更新文章标签；不会自动推断标题、分类或其他 Frontmatter 字段",
      systemImage: "newspaper",
      risk: .contentChange,
      arguments: [.draftID, .value, .values],
      required: [.draftID],
      semanticRule: .valueOrValues
    ),
    entry(
      .webFetch,
      title: "抓取网页内容",
      detail: "安全提取指定 URL 网页的纯文本与 Markdown 内容",
      systemImage: "globe",
      risk: .readOnly,
      arguments: [.url],
      required: [.url]
    ),
    entry(
      .webSearch,
      title: "联网搜索",
      detail: "在线检索与文章主题相关的资料与技术规范",
      systemImage: "magnifyingglass",
      risk: .readOnly,
      arguments: [.query],
      required: [.query],
      isAgentExposed: false
    ),
    entry(
      .siteCheckLinks,
      title: "静态检查文章链接",
      detail: "在本地解析 Markdown 链接并报告格式与目标类型；不验证网络可用性",
      systemImage: "link.badge.plus",
      risk: .readOnly,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .siteOptimizeImages,
      title: "检查图片资源",
      detail: "巡检文章中引用的图片体积大小与 alt 描述完整性",
      systemImage: "photo.badge.checkmark",
      risk: .readOnly,
      arguments: [.draftID],
      required: [.draftID]
    ),
    entry(
      .siteDeployStatus,
      title: "查看部署状态",
      detail: "查看站点最新构建与线上发布健康状态",
      systemImage: "antenna.radiowaves.left.and.right",
      risk: .readOnly
    ),
  ]

  public static let descriptors = entries.map(\.descriptor)
  private static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.descriptor.id, $0) })

  public static func descriptor(
    for command: WorkbenchAutomationCommandID
  ) -> WorkbenchAutomationCommandDescriptor? {
    byID[command]?.descriptor
  }

  static func specification(
    for command: WorkbenchAutomationCommandID
  ) -> WorkbenchAutomationCommandSpecification? {
    byID[command]?.specification
  }

  /// The same command entries drive model declarations, prompt text, parsing,
  /// and runtime validation. A declaration never grants execution authority.
  public static var agentToolDefinitions: [AIToolDefinition] {
    entries.compactMap { entry in
      guard entry.isAgentExposed else { return nil }
      return entry.specification.definition(descriptor: entry.descriptor)
    }
  }

  public static func agentToolDefinitions(
    allowing commands: Set<WorkbenchAutomationCommandID>
  ) -> [AIToolDefinition] {
    entries.compactMap { entry in
      guard entry.isAgentExposed, commands.contains(entry.descriptor.id) else { return nil }
      return entry.specification.definition(descriptor: entry.descriptor)
    }
  }

  /// Converts the persisted fine-grained policy into the command allowlist
  /// declared to the model. Execution still validates the same allowlist.
  public static func agentCommands(
    allowedBy policy: AIAgentPermissionPolicy,
    masterEnabled: Bool
  ) -> Set<WorkbenchAutomationCommandID> {
    guard masterEnabled else { return [] }
    return Set(entries.compactMap { entry in
      guard entry.isAgentExposed,
        policy.allows(requiredPermission(for: entry.descriptor.id))
      else { return nil }
      return entry.descriptor.id
    })
  }

  static func agentInvocation(
    for toolCall: AIToolCall,
    draftVersions: [UUID: Date]
  ) throws -> WorkbenchAIAgentToolInvocation {
    guard let command = WorkbenchAutomationCommandID(rawValue: toolCall.function.name),
      let entry = byID[command], entry.isAgentExposed
    else {
      throw WorkbenchAutomationAgentToolError.unknownTool(toolCall.function.name)
    }
    let specification = entry.specification
    guard let data = toolCall.function.arguments.data(using: .utf8) else {
      throw WorkbenchAutomationAgentToolError.invalidJSON
    }

    let json: AIStructuredOutputJSONValue
    do {
      json = try JSONDecoder().decode(AIStructuredOutputJSONValue.self, from: data)
    } catch {
      throw WorkbenchAutomationAgentToolError.invalidJSON
    }
    guard case .object(let object) = json else {
      throw WorkbenchAutomationAgentToolError.argumentMismatch
    }

    do {
      let arguments = try specification.arguments(
        from: object,
        draftVersions: draftVersions
      )
      let step = WorkbenchAutomationStep(command: command, arguments: arguments)
      try specification.validate(arguments)
      return WorkbenchAIAgentToolInvocation(toolCallID: toolCall.id, step: step)
    } catch {
      throw WorkbenchAutomationAgentToolError.argumentMismatch
    }
  }

  public static var promptCatalog: String {
    entries.compactMap { entry in
      guard entry.isAgentExposed else { return nil }
      let descriptor = entry.descriptor
      return
        "- \(descriptor.id.rawValue): \(descriptor.title)；risk=\(descriptor.risk.rawValue)；arguments=\(entry.specification.promptCatalog)"
    }
    .joined(separator: "\n")
  }

  private static func entry(
    _ id: WorkbenchAutomationCommandID,
    title: String,
    detail: String,
    systemImage: String,
    risk: WorkbenchAutomationRisk,
    arguments: [WorkbenchAutomationArgumentKey] = [],
    required: Set<WorkbenchAutomationArgumentKey> = [],
    semanticRule: WorkbenchAutomationSemanticRule = .none,
    allowsAgentAutomaticExecution: Bool? = nil,
    isAgentExposed: Bool = true
  ) -> WorkbenchAutomationRegistryEntry {
    let specification = WorkbenchAutomationCommandSpecification(
      allowedArguments: arguments,
      requiredArguments: required,
      semanticRule: semanticRule
    )
    return WorkbenchAutomationRegistryEntry(
      descriptor: WorkbenchAutomationCommandDescriptor(
        id: id,
        title: CoreL10n.text(title),
        detail: CoreL10n.text(detail),
        systemImage: systemImage,
        risk: risk,
        requiresDraft: required.contains(.draftID),
        allowsAgentAutomaticExecution: allowsAgentAutomaticExecution
      ),
      specification: specification,
      isAgentExposed: isAgentExposed
    )
  }

  private static func requiredPermission(
    for command: WorkbenchAutomationCommandID
  ) -> AIAgentPermissionScope {
    switch command {
    case .openSection, .selectDraft, .focusEditor, .showInspector, .runPreflight,
      .refreshPublishPreview, .draftRead, .searchDrafts, .knowledgeSearch,
      .knowledgeRead, .auditContent,
      .siteCheckLinks, .siteOptimizeImages:
      return .localRead
    case .createDraft:
      return .draftCreation
    case .saveWorkbench, .updateMetadata, .appendToBody, .replaceBody, .deleteDraft,
      .applyDiff, .generateFrontmatter:
      return .contentModification
    case .webFetch, .webSearch, .siteDeployStatus:
      return .networkAccess
    case .writeLocalRepository:
      return .repositoryWrite
    case .publishOnline:
      return .publishing
    }
  }
}

extension WorkbenchAutomationPlan {
  public func requiresConfirmation(for step: WorkbenchAutomationStep) -> Bool {
    guard let risk = WorkbenchAutomationRegistry.descriptor(for: step.command)?.risk else {
      return true
    }
    return source == .agentLoop
      ? !(WorkbenchAutomationRegistry.descriptor(for: step.command)?.allowsAgentAutomaticExecution ?? false)
      : risk.requiresExplicitConfirmation
  }
}

enum WorkbenchAutomationAgentToolError: Error, Equatable, Sendable {
  case unknownTool(String)
  case invalidJSON
  case argumentMismatch
}

private struct WorkbenchAutomationRegistryEntry: Sendable {
  var descriptor: WorkbenchAutomationCommandDescriptor
  var specification: WorkbenchAutomationCommandSpecification
  var isAgentExposed: Bool
}

enum WorkbenchAutomationArgumentKey: String, CaseIterable, Hashable, Sendable {
  case section
  case draftID
  case editorField
  case metadataField
  case value
  case values
  case content
  case mode
  case paragraphIndices
  case url
  case query
  case documentID
  case originalText
  case replacementText

  var allowedStringValues: [String] {
    switch self {
    case .section:
      return WorkspaceVisibilityPolicy.commandPaletteSections.map(\.rawValue)
    case .editorField:
      return ["body", "title", "summary", "slug"]
    case .metadataField:
      return AIPublishingMetadataField.allCases.map(\.rawValue)
    case .mode:
      return ["outline", "full", "paragraph_range"]
    case .draftID, .documentID, .value, .values, .content, .paragraphIndices, .url, .query,
      .originalText, .replacementText:
      return []
    }
  }

  var schema: AIStructuredOutputJSONValue {
    switch self {
    case .section, .editorField, .metadataField, .mode:
      return .object([
        "type": .string("string"),
        "enum": .array(allowedStringValues.map(AIStructuredOutputJSONValue.string)),
      ])
    case .draftID:
      return .object([
        "type": .string("string"),
        "description": .string("Stable draft UUID from the supplied workbench context."),
      ])
    case .documentID:
      return .object([
        "type": .string("string"),
        "description": .string("Stable knowledge document UUID returned by knowledgeSearch."),
      ])
    case .value:
      return .object(["type": .string("string")])
    case .values:
      return .object([
        "type": .string("array"),
        "items": .object(["type": .string("string"), "minLength": .number(1)]),
      ])
    case .content:
      return .object([
        "type": .string("string"),
        "description": .string("Markdown content."),
      ])
    case .paragraphIndices:
      return .object([
        "type": .string("array"),
        "items": .object(["type": .string("integer"), "minimum": .number(0)]),
        "description": .string("0-indexed paragraph indices to read."),
      ])
    case .url:
      return .object([
        "type": .string("string"),
        "description": .string("Web page URL to fetch."),
      ])
    case .query:
      return .object([
        "type": .string("string"),
        "description": .string("Search query."),
      ])
    case .originalText:
      return .object([
        "type": .string("string"),
        "description": .string("Original text to match and replace."),
      ])
    case .replacementText:
      return .object([
        "type": .string("string"),
        "description": .string("New replacement text."),
      ])
    }
  }

  var promptCatalog: String {
    switch self {
    case .section:
      return "section: \(allowedStringValues.joined(separator: "|"))"
    case .draftID:
      return "draftID: UUID"
    case .editorField:
      return "editorField: \(allowedStringValues.joined(separator: "|"))"
    case .metadataField:
      return "metadataField: \(allowedStringValues.joined(separator: "|"))"
    case .value:
      return "value: string"
    case .values:
      return "values: [string]"
    case .content:
      return "content: Markdown"
    case .mode:
      return "mode: \(allowedStringValues.joined(separator: "|"))"
    case .paragraphIndices:
      return "paragraphIndices: [int]"
    case .url:
      return "url: string"
    case .query:
      return "query: string"
    case .documentID:
      return "documentID: UUID"
    case .originalText:
      return "originalText: string"
    case .replacementText:
      return "replacementText: string"
    }
  }
}

enum WorkbenchAutomationSemanticRule: Equatable, Sendable {
  case none
  case metadataValue
  case valueOrValues
}

struct WorkbenchAutomationCommandSpecification: Sendable {
  var allowedArguments: [WorkbenchAutomationArgumentKey]
  var requiredArguments: Set<WorkbenchAutomationArgumentKey>
  var semanticRule: WorkbenchAutomationSemanticRule

  var promptCatalog: String {
    guard !allowedArguments.isEmpty else { return "none" }
    let arguments = allowedArguments.map { key in
      let required = requiredArguments.contains(key) ? "required" : "optional"
      return "\(key.promptCatalog) (\(required))"
    }
    .joined(separator: ", ")
    switch semanticRule {
    case .none:
      return arguments
    case .metadataValue:
      return arguments
        + "; tags requires a non-empty value or values; other metadata fields require a non-empty value"
    case .valueOrValues:
      return arguments + "; requires a non-empty value or values"
    }
  }

  func definition(
    descriptor: WorkbenchAutomationCommandDescriptor
  ) -> AIToolDefinition {
    let properties = Dictionary(
      uniqueKeysWithValues: allowedArguments.map { ($0.rawValue, $0.schema) }
    )
    var schema: [String: AIStructuredOutputJSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "required": .array(requiredArguments.map { .string($0.rawValue) }.sortedJSONStrings),
      "additionalProperties": .bool(false),
    ]
    if semanticRule == .metadataValue {
      schema["allOf"] = Self.metadataConditionalSchema
    } else if semanticRule == .valueOrValues {
      schema["anyOf"] = Self.valueOrValuesSchema
    }
    return AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: descriptor.id.rawValue,
        description: "\(descriptor.detail) Risk: \(descriptor.risk.rawValue).",
        parameters: .object(schema)
      )
    )
  }

  func arguments(
    from object: [String: AIStructuredOutputJSONValue],
    draftVersions: [UUID: Date]
  ) throws -> WorkbenchAutomationArguments {
    let allowed = Set(allowedArguments.map(\.rawValue))
    guard Set(object.keys).isSubset(of: allowed),
      requiredArguments.allSatisfy({ object[$0.rawValue] != nil })
    else {
      throw WorkbenchAutomationAgentToolError.argumentMismatch
    }

    var arguments = WorkbenchAutomationArguments()
    for (rawKey, value) in object {
      guard let key = WorkbenchAutomationArgumentKey(rawValue: rawKey) else {
        throw WorkbenchAutomationAgentToolError.argumentMismatch
      }
      switch (key, value) {
      case (.section, .string(let raw)):
        guard let section = WorkspaceSection(rawValue: raw),
          WorkspaceVisibilityPolicy.commandPaletteSections.contains(section)
        else {
          throw WorkbenchAutomationAgentToolError.argumentMismatch
        }
        arguments.section = section
      case (.draftID, .string(let raw)):
        guard let draftID = UUID(uuidString: raw),
          let version = draftVersions[draftID]
        else {
          throw WorkbenchAutomationAgentToolError.argumentMismatch
        }
        arguments.draftID = draftID
        arguments.expectedDraftUpdatedAt = version
      case (.editorField, .string(let raw)):
        guard key.allowedStringValues.contains(raw) else {
          throw WorkbenchAutomationAgentToolError.argumentMismatch
        }
        arguments.editorField = raw
      case (.metadataField, .string(let raw)):
        guard let field = AIPublishingMetadataField(rawValue: raw) else {
          throw WorkbenchAutomationAgentToolError.argumentMismatch
        }
        arguments.metadataField = field
      case (.value, .string(let raw)):
        arguments.value = raw
      case (.values, .array(let rawValues)):
        arguments.values = try rawValues.map { value in
          guard case .string(let raw) = value else {
            throw WorkbenchAutomationAgentToolError.argumentMismatch
          }
          return raw
        }
      case (.content, .string(let raw)):
        arguments.content = raw
      case (.mode, .string(let raw)):
        guard key.allowedStringValues.contains(raw) else {
          throw WorkbenchAutomationAgentToolError.argumentMismatch
        }
        arguments.mode = raw
      case (.paragraphIndices, .array(let rawValues)):
        arguments.paragraphIndices = try rawValues.map { value in
          guard case .number(let num) = value else {
            throw WorkbenchAutomationAgentToolError.argumentMismatch
          }
          return Int(num)
        }
      case (.url, .string(let raw)):
        arguments.url = raw
      case (.query, .string(let raw)):
        arguments.query = raw
      case (.documentID, .string(let raw)):
        guard let documentID = UUID(uuidString: raw) else {
          throw WorkbenchAutomationAgentToolError.argumentMismatch
        }
        arguments.documentID = documentID
      case (.originalText, .string(let raw)):
        arguments.originalText = raw
      case (.replacementText, .string(let raw)):
        arguments.replacementText = raw
      default:
        throw WorkbenchAutomationAgentToolError.argumentMismatch
      }
    }
    return arguments
  }

  func validate(_ arguments: WorkbenchAutomationArguments) throws {
    let providedArguments = Set(
      WorkbenchAutomationArgumentKey.allCases.filter { hasProvidedValue($0, in: arguments) }
    )
    guard providedArguments.isSubset(of: Set(allowedArguments)) else {
      throw WorkbenchAutomationValidationError.unsupportedCommand
    }
    for key in requiredArguments where !hasValue(key, in: arguments) {
      throw WorkbenchAutomationValidationError.missingArgument(key.rawValue)
    }
    if let section = arguments.section,
      !WorkspaceVisibilityPolicy.commandPaletteSections.contains(section)
    {
      throw WorkbenchAutomationValidationError.missingArgument("section")
    }
    if let editorField = arguments.editorField,
      !WorkbenchAutomationArgumentKey.editorField.allowedStringValues.contains(editorField)
    {
      throw WorkbenchAutomationValidationError.missingArgument("editorField")
    }
    if let mode = arguments.mode,
      !WorkbenchAutomationArgumentKey.mode.allowedStringValues.contains(mode)
    {
      throw WorkbenchAutomationValidationError.missingArgument("mode")
    }
    if semanticRule == .metadataValue {
      guard let field = arguments.metadataField else {
        throw WorkbenchAutomationValidationError.missingArgument("metadataField")
      }
      if field == .tags {
        guard
          arguments.value?.nilIfEmpty != nil
            || arguments.values.contains(where: { $0.nilIfEmpty != nil })
        else {
          throw WorkbenchAutomationValidationError.missingArgument("value|values")
        }
      } else if arguments.value?.nilIfEmpty == nil {
        throw WorkbenchAutomationValidationError.missingArgument("value")
      }
    } else if semanticRule == .valueOrValues,
      arguments.value?.nilIfEmpty == nil,
      !arguments.values.contains(where: { $0.nilIfEmpty != nil })
    {
      throw WorkbenchAutomationValidationError.missingArgument("value|values")
    }
  }

  private func hasValue(
    _ key: WorkbenchAutomationArgumentKey,
    in arguments: WorkbenchAutomationArguments
  ) -> Bool {
    switch key {
    case .section:
      return arguments.section != nil
    case .draftID:
      return arguments.draftID != nil
    case .editorField:
      return arguments.editorField?.nilIfEmpty != nil
    case .metadataField:
      return arguments.metadataField != nil
    case .value:
      return arguments.value?.nilIfEmpty != nil
    case .values:
      return arguments.values.contains(where: { $0.nilIfEmpty != nil })
    case .content:
      return arguments.content?.nilIfEmpty != nil
    case .mode:
      return arguments.mode?.nilIfEmpty != nil
    case .paragraphIndices:
      return !arguments.paragraphIndices.isEmpty
    case .url:
      return arguments.url?.nilIfEmpty != nil
    case .query:
      return arguments.query?.nilIfEmpty != nil
    case .documentID:
      return arguments.documentID != nil
    case .originalText:
      return arguments.originalText?.nilIfEmpty != nil
    case .replacementText:
      return arguments.replacementText != nil
    }
  }

  private func hasProvidedValue(
    _ key: WorkbenchAutomationArgumentKey,
    in arguments: WorkbenchAutomationArguments
  ) -> Bool {
    switch key {
    case .section:
      return arguments.section != nil
    case .draftID:
      return arguments.draftID != nil
    case .editorField:
      return arguments.editorField != nil
    case .metadataField:
      return arguments.metadataField != nil
    case .value:
      return arguments.value != nil
    case .values:
      return !arguments.values.isEmpty
    case .content:
      return arguments.content != nil
    case .mode:
      return arguments.mode != nil
    case .paragraphIndices:
      return !arguments.paragraphIndices.isEmpty
    case .url:
      return arguments.url != nil
    case .query:
      return arguments.query != nil
    case .documentID:
      return arguments.documentID != nil
    case .originalText:
      return arguments.originalText != nil
    case .replacementText:
      return arguments.replacementText != nil
    }
  }

  private static let metadataConditionalSchema: AIStructuredOutputJSONValue = .array([
    .object([
      "if": .object([
        "properties": .object([
          "metadataField": .object(["const": .string("tags")])
        ]),
        "required": .array([.string("metadataField")]),
      ]),
      "then": .object([
        "anyOf": .array([
          .object([
            "required": .array([.string("value")]),
            "properties": .object([
              "value": .object(["minLength": .number(1)])
            ]),
          ]),
          .object([
            "required": .array([.string("values")]),
            "properties": .object([
              "values": .object(["minItems": .number(1)])
            ]),
          ]),
        ])
      ]),
      "else": .object([
        "required": .array([.string("value")]),
        "properties": .object([
          "value": .object(["minLength": .number(1)])
        ]),
      ]),
    ])
  ])

  private static let valueOrValuesSchema: AIStructuredOutputJSONValue = .array([
    .object([
      "required": .array([.string("value")]),
      "properties": .object([
        "value": .object(["minLength": .number(1)])
      ]),
    ]),
    .object([
      "required": .array([.string("values")]),
      "properties": .object([
        "values": .object(["minItems": .number(1)])
      ]),
    ]),
  ])
}

extension Array where Element == AIStructuredOutputJSONValue {
  fileprivate var sortedJSONStrings: [AIStructuredOutputJSONValue] {
    sorted { lhs, rhs in
      guard case .string(let left) = lhs, case .string(let right) = rhs else { return false }
      return left < right
    }
  }
}

public enum WorkbenchAutomationPlanValidator {
  public static func validateStructure(_ plan: WorkbenchAutomationPlan) throws {
    guard !plan.steps.isEmpty else {
      throw WorkbenchAutomationValidationError.emptyPlan
    }
    guard plan.steps.count <= WorkbenchAutomationPlan.maximumStepCount else {
      throw WorkbenchAutomationValidationError.tooManySteps(plan.steps.count)
    }
    for step in plan.steps {
      try validateArguments(step)
    }
  }

  public static func validateArguments(_ step: WorkbenchAutomationStep) throws {
    guard let specification = WorkbenchAutomationRegistry.specification(for: step.command) else {
      throw WorkbenchAutomationValidationError.unsupportedCommand
    }
    try specification.validate(step.arguments)
  }
}

public enum WorkbenchAutomationDraftMutationService {
  public static func preview(
    step: WorkbenchAutomationStep,
    draft: ArticleDraft
  ) throws -> WorkbenchAutomationDraftPreview {
    guard step.arguments.draftID == draft.id else {
      throw WorkbenchAutomationValidationError.draftNotFound
    }
    if let expected = step.arguments.expectedDraftUpdatedAt,
      expected != draft.updatedAt
    {
      throw WorkbenchAutomationValidationError.staleDraft
    }

    var updated = draft
    switch step.command {
    case .updateMetadata:
      guard let field = step.arguments.metadataField else {
        throw WorkbenchAutomationValidationError.missingArgument("metadataField")
      }
      switch field {
      case .title:
        updated.title = step.arguments.value?.trimmedForPublishing ?? ""
      case .slug:
        updated.slug = step.arguments.value?.trimmedForPublishing ?? ""
      case .summary:
        updated.summary = step.arguments.value?.trimmedForPublishing ?? ""
      case .tags:
        let values =
          step.arguments.values.isEmpty
          ? (step.arguments.value ?? "").components(separatedBy: CharacterSet(charactersIn: ",，"))
          : step.arguments.values
        updated.tags = stableUniqueStrings(values)
      }
    case .appendToBody:
      let addition = step.arguments.content?.trimmedForPublishing ?? ""
      updated.bodyMarkdown = [draft.bodyMarkdown.trimmedForPublishing, addition]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    case .replaceBody:
      updated.bodyMarkdown = step.arguments.content?.trimmedForPublishing ?? ""
    case .applyDiff:
      guard let original = step.arguments.originalText?.nilIfEmpty,
        let replacement = step.arguments.replacementText
      else {
        throw WorkbenchAutomationValidationError.missingArgument("originalText/replacementText")
      }
      guard let match = uniqueMatch(of: original, in: draft.bodyMarkdown) else {
        throw WorkbenchAutomationValidationError.missingArgument(
          "originalText (must match exactly once)"
        )
      }
      updated.bodyMarkdown = draft.bodyMarkdown.replacingCharacters(
        in: match,
        with: replacement
      )
    case .generateFrontmatter:
      if !step.arguments.values.isEmpty {
        updated.tags = stableUniqueStrings(step.arguments.values)
      } else if let val = step.arguments.value?.nilIfEmpty {
        let components = val.components(separatedBy: CharacterSet(charactersIn: ",，"))
        updated.tags = stableUniqueStrings(components)
      }
    default:
      throw WorkbenchAutomationValidationError.unsupportedCommand
    }
    updated.updatedAt = Date()
    return WorkbenchAutomationDraftPreview(
      stepID: step.id,
      originalDraft: draft,
      updatedDraft: updated
    )
  }

  private static func stableUniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      let trimmed = value.trimmedForPublishing
      guard !trimmed.isEmpty else { return nil }
      let normalized = trimmed.lowercased()
      guard seen.insert(normalized).inserted else { return nil }
      return trimmed
    }
  }

  /// Returns the only exact, Unicode-safe match in `text`.
  ///
  /// Advancing from the match's lower bound (rather than its upper bound)
  /// also detects overlapping matches such as `aa` in `aaa`, so an ambiguous
  /// local edit fails closed instead of replacing an arbitrary set of bytes.
  private static func uniqueMatch(of needle: String, in text: String) -> Range<String.Index>? {
    guard !needle.isEmpty else { return nil }
    var searchStart = text.startIndex
    var match: Range<String.Index>?
    var matchCount = 0

    while searchStart < text.endIndex,
          let range = text.range(of: needle, range: searchStart..<text.endIndex)
    {
      matchCount += 1
      guard matchCount <= 1 else { return nil }
      match = range
      searchStart = text.index(after: range.lowerBound)
    }

    return matchCount == 1 ? match : nil
  }
}

public struct WorkbenchAutomationParsedResponse: Hashable, Sendable {
  public var displayContent: String
  public var plan: WorkbenchAutomationPlan?

  public init(displayContent: String, plan: WorkbenchAutomationPlan?) {
    self.displayContent = displayContent
    self.plan = plan
  }
}

public enum WorkbenchAutomationPlanParser {
  public static let openingMarker = "<workbench_automation_plan>"
  public static let closingMarker = "</workbench_automation_plan>"

  public static func parse(
    _ response: String,
    currentDraft: ArticleDraft,
    draftVersions: [UUID: Date] = [:]
  ) -> WorkbenchAutomationParsedResponse {
    guard let openingRange = response.range(of: openingMarker),
      let closingRange = response.range(
        of: closingMarker,
        range: openingRange.upperBound..<response.endIndex
      )
    else {
      return WorkbenchAutomationParsedResponse(
        displayContent: response.trimmedForPublishing,
        plan: nil
      )
    }

    let json = String(response[openingRange.upperBound..<closingRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .removingMarkdownJSONFence
    let visible =
      (String(response[..<openingRange.lowerBound])
      + String(response[closingRange.upperBound...]))
      .trimmedForPublishing

    guard let data = json.data(using: .utf8),
      let envelope = try? JSONDecoder().decode(PlanEnvelope.self, from: data),
      let plan = makePlan(
        envelope,
        currentDraft: currentDraft,
        draftVersions: draftVersions
      ),
      (try? WorkbenchAutomationPlanValidator.validateStructure(plan)) != nil
    else {
      return WorkbenchAutomationParsedResponse(
        displayContent: response.trimmedForPublishing,
        plan: nil
      )
    }

    return WorkbenchAutomationParsedResponse(
      displayContent: visible.nilIfEmpty
        ?? CoreL10n.text("已准备一份应用内操作计划，请审阅后执行。"),
      plan: plan
    )
  }

  private static func makePlan(
    _ envelope: PlanEnvelope,
    currentDraft: ArticleDraft,
    draftVersions: [UUID: Date]
  ) -> WorkbenchAutomationPlan? {
    let goal = envelope.goal.trimmedForPublishing
    guard !goal.isEmpty,
      !envelope.steps.isEmpty,
      envelope.steps.count <= WorkbenchAutomationPlan.maximumStepCount
    else {
      return nil
    }

    var resolvedDraftVersions = draftVersions
    resolvedDraftVersions[currentDraft.id] = currentDraft.updatedAt
    var steps: [WorkbenchAutomationStep] = []
    for raw in envelope.steps {
      guard let command = WorkbenchAutomationCommandID(rawValue: raw.command),
        let specification = WorkbenchAutomationRegistry.specification(for: command)
      else {
        return nil
      }
      let rawArguments: [String: AIStructuredOutputJSONValue]
      if let arguments = raw.arguments {
        guard case .object(let object) = arguments else { return nil }
        rawArguments = object
      } else {
        rawArguments = [:]
      }
      var resolvedArguments = rawArguments
      if specification.requiredArguments.contains(.draftID),
        resolvedArguments[WorkbenchAutomationArgumentKey.draftID.rawValue] == nil
      {
        resolvedArguments[WorkbenchAutomationArgumentKey.draftID.rawValue] = .string(
          currentDraft.id.uuidString
        )
      }
      guard
        let arguments = try? specification.arguments(
          from: resolvedArguments,
          draftVersions: resolvedDraftVersions
        )
      else {
        return nil
      }
      steps.append(WorkbenchAutomationStep(command: command, arguments: arguments))
    }
    return WorkbenchAutomationPlan(goal: goal, steps: steps)
  }

  private struct PlanEnvelope: Decodable {
    var goal: String
    var steps: [StepEnvelope]
  }

  private struct StepEnvelope: Decodable {
    var command: String
    var arguments: AIStructuredOutputJSONValue?
  }
}

extension String {
  fileprivate var removingMarkdownJSONFence: String {
    var value = trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("```json") {
      value.removeFirst("```json".count)
    } else if value.hasPrefix("```") {
      value.removeFirst(3)
    }
    if value.hasSuffix("```") {
      value.removeLast(3)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
