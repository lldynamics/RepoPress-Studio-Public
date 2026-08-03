import Foundation

public enum WorkbenchAutomationRegistry {
  public static let descriptors: [WorkbenchAutomationCommandDescriptor] = [
    WorkbenchAutomationCommandDescriptor(
      id: .openSection,
      title: CoreL10n.text("打开工作区"),
      detail: CoreL10n.text("切换到写作、资料库、RSS、同步、图片或内容健康页面"),
      systemImage: "sidebar.left",
      risk: .readOnly
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .selectDraft,
      title: CoreL10n.text("打开文章"),
      detail: CoreL10n.text("按稳定文章 ID 选择并打开文章"),
      systemImage: "doc.text.magnifyingglass",
      risk: .readOnly,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .createDraft,
      title: CoreL10n.text("新建文章"),
      detail: CoreL10n.text("创建一篇可从回收站恢复的本地草稿"),
      systemImage: "square.and.pencil",
      risk: .reversible
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .focusEditor,
      title: CoreL10n.text("聚焦编辑器"),
      detail: CoreL10n.text("打开写作页并将焦点移到指定编辑字段"),
      systemImage: "cursorarrow.rays",
      risk: .readOnly,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .showInspector,
      title: CoreL10n.text("打开 Inspector"),
      detail: CoreL10n.text("显示当前工作区的检查面板"),
      systemImage: "sidebar.right",
      risk: .readOnly
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .runPreflight,
      title: CoreL10n.text("运行发布检查"),
      detail: CoreL10n.text("检查当前文章的元数据、正文和发布风险"),
      systemImage: "checkmark.seal",
      risk: .readOnly,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .refreshPublishPreview,
      title: CoreL10n.text("刷新发布预览"),
      detail: CoreL10n.text("重新生成当前文章的本地发布预览"),
      systemImage: "arrow.clockwise",
      risk: .readOnly,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .saveWorkbench,
      title: CoreL10n.text("保存工作台"),
      detail: CoreL10n.text("立即保存当前本地更改"),
      systemImage: "square.and.arrow.down",
      risk: .reversible
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .updateMetadata,
      title: CoreL10n.text("修改文章元数据"),
      detail: CoreL10n.text("预览后修改标题、Slug、摘要或 Tags"),
      systemImage: "tag",
      risk: .contentChange,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .appendToBody,
      title: CoreL10n.text("追加正文"),
      detail: CoreL10n.text("预览后把 Markdown 追加到文章末尾"),
      systemImage: "text.append",
      risk: .contentChange,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .replaceBody,
      title: CoreL10n.text("替换正文"),
      detail: CoreL10n.text("预览后替换整篇 Markdown 正文"),
      systemImage: "arrow.left.arrow.right",
      risk: .contentChange,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .deleteDraft,
      title: CoreL10n.text("移到回收站"),
      detail: CoreL10n.text("把文章移到回收站，不立即删除仓库文件"),
      systemImage: "trash",
      risk: .externalEffect,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .writeLocalRepository,
      title: CoreL10n.text("写入本地仓库"),
      detail: CoreL10n.text("把当前文章的发布文件写入已授权仓库"),
      systemImage: "externaldrive",
      risk: .externalEffect,
      requiresDraft: true
    ),
    WorkbenchAutomationCommandDescriptor(
      id: .publishOnline,
      title: CoreL10n.text("发布所有变更"),
      detail: CoreL10n.text("按当前发布策略提交并推送站点中所有通过检查的待发布变更"),
      systemImage: "paperplane",
      risk: .externalEffect
    ),
  ]

  private static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

  public static func descriptor(
    for command: WorkbenchAutomationCommandID
  ) -> WorkbenchAutomationCommandDescriptor? {
    byID[command]
  }

  public static var promptCatalog: String {
    descriptors.map { descriptor in
      let arguments = argumentPrompt(for: descriptor.id)
      return "- \(descriptor.id.rawValue): \(descriptor.title)；risk=\(descriptor.risk.rawValue)；arguments=\(arguments)"
    }
    .joined(separator: "\n")
  }

  private static func argumentPrompt(for command: WorkbenchAutomationCommandID) -> String {
    switch command {
    case .openSection:
      return #"section: writing|library|rss|sync|images|contentHealth|siteStarter"#
    case .selectDraft:
      return "draftID: UUID"
    case .createDraft:
      return "value: optional initial title"
    case .focusEditor:
      return "draftID: UUID, editorField: body|title|summary|slug"
    case .showInspector, .saveWorkbench:
      return "none"
    case .runPreflight, .refreshPublishPreview, .deleteDraft, .writeLocalRepository:
      return "draftID: UUID"
    case .publishOnline:
      return "none; publishes all reviewed pending changes in the current site"
    case .updateMetadata:
      return "draftID: UUID, metadataField: title|slug|summary|tags, value: string or values: [string]"
    case .appendToBody, .replaceBody:
      return "draftID: UUID, content: Markdown"
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
    guard let descriptor = WorkbenchAutomationRegistry.descriptor(for: step.command) else {
      throw WorkbenchAutomationValidationError.unsupportedCommand
    }
    if descriptor.requiresDraft, step.arguments.draftID == nil {
      throw WorkbenchAutomationValidationError.missingArgument("draftID")
    }

    switch step.command {
    case .openSection:
      guard step.arguments.section != nil else {
        throw WorkbenchAutomationValidationError.missingArgument("section")
      }
    case .focusEditor:
      guard step.arguments.editorField?.nilIfEmpty != nil else {
        throw WorkbenchAutomationValidationError.missingArgument("editorField")
      }
    case .updateMetadata:
      guard let field = step.arguments.metadataField else {
        throw WorkbenchAutomationValidationError.missingArgument("metadataField")
      }
      if field == .tags {
        guard !step.arguments.values.isEmpty || step.arguments.value?.nilIfEmpty != nil else {
          throw WorkbenchAutomationValidationError.missingArgument("values")
        }
      } else {
        guard step.arguments.value?.nilIfEmpty != nil else {
          throw WorkbenchAutomationValidationError.missingArgument("value")
        }
      }
    case .appendToBody, .replaceBody:
      guard step.arguments.content?.nilIfEmpty != nil else {
        throw WorkbenchAutomationValidationError.missingArgument("content")
      }
    case .selectDraft, .runPreflight, .refreshPublishPreview, .deleteDraft,
      .writeLocalRepository, .publishOnline, .createDraft, .showInspector, .saveWorkbench:
      break
    }
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
       expected != draft.updatedAt {
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
        let values = step.arguments.values.isEmpty
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
          ) else {
      return WorkbenchAutomationParsedResponse(
        displayContent: response.trimmedForPublishing,
        plan: nil
      )
    }

    let json = String(response[openingRange.upperBound..<closingRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .removingMarkdownJSONFence
    let visible = (String(response[..<openingRange.lowerBound])
      + String(response[closingRange.upperBound...]))
      .trimmedForPublishing

    guard let data = json.data(using: .utf8),
          let envelope = try? JSONDecoder().decode(PlanEnvelope.self, from: data),
          let plan = makePlan(
            envelope,
            currentDraft: currentDraft,
            draftVersions: draftVersions
          ),
          (try? WorkbenchAutomationPlanValidator.validateStructure(plan)) != nil else {
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
          envelope.steps.count <= WorkbenchAutomationPlan.maximumStepCount else {
      return nil
    }

    var resolvedDraftVersions = draftVersions
    resolvedDraftVersions[currentDraft.id] = currentDraft.updatedAt
    var steps: [WorkbenchAutomationStep] = []
    for raw in envelope.steps {
      guard let command = WorkbenchAutomationCommandID(rawValue: raw.command),
            WorkbenchAutomationRegistry.descriptor(for: command) != nil else {
        return nil
      }
      let suppliedDraftID = raw.arguments?.draftID.flatMap(UUID.init(uuidString:))
      let descriptor = WorkbenchAutomationRegistry.descriptor(for: command)
      let targetDraftID = suppliedDraftID ?? (descriptor?.requiresDraft == true ? currentDraft.id : nil)
      let expectedDraftUpdatedAt = targetDraftID.flatMap { resolvedDraftVersions[$0] }
      if descriptor?.requiresDraft == true,
         expectedDraftUpdatedAt == nil {
        return nil
      }
      let section = raw.arguments?.section.flatMap(WorkspaceSection.init(rawValue:))
      let metadataField = raw.arguments?.metadataField.flatMap(AIPublishingMetadataField.init(rawValue:))
      let arguments = WorkbenchAutomationArguments(
        section: section,
        draftID: targetDraftID,
        expectedDraftUpdatedAt: expectedDraftUpdatedAt,
        editorField: raw.arguments?.editorField,
        metadataField: metadataField,
        value: raw.arguments?.value,
        values: raw.arguments?.values ?? [],
        content: raw.arguments?.content
      )
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
    var arguments: ArgumentsEnvelope?
  }

  private struct ArgumentsEnvelope: Decodable {
    var section: String?
    var draftID: String?
    var editorField: String?
    var metadataField: String?
    var value: String?
    var values: [String]?
    var content: String?
  }
}

private extension String {
  var removingMarkdownJSONFence: String {
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
