import Foundation

public enum AIChatFollowUpSuggestionService {
  public static let openingTag = "<follow_up_suggestions>"
  public static let closingTag = "</follow_up_suggestions>"

  public struct ExtractionResult: Sendable {
    public var displayContent: String
    public var suggestions: [AIChatFollowUpSuggestion]

    public init(displayContent: String, suggestions: [AIChatFollowUpSuggestion]) {
      self.displayContent = displayContent
      self.suggestions = suggestions
    }
  }

  /// Extracts explicit `<follow_up_suggestions>` JSON blocks from the response content.
  /// If not found, falls back to contextual inference.
  public static func extractOrInferSuggestions(
    content: String,
    draft: ArticleDraft? = nil,
    hasAutomationPlan: Bool = false
  ) -> ExtractionResult {
    let trimmed = content.trimmedForPublishing
    guard let openRange = trimmed.range(of: openingTag),
      let closeRange = trimmed.range(of: closingTag, range: openRange.upperBound..<trimmed.endIndex)
    else {
      let inferred = inferDefaultSuggestions(
        content: trimmed, draft: draft, hasAutomationPlan: hasAutomationPlan)
      return ExtractionResult(displayContent: trimmed, suggestions: inferred)
    }

    let jsonSubstring = trimmed[openRange.upperBound..<closeRange.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let visibleText =
      (String(trimmed[..<openRange.lowerBound]) + String(trimmed[closeRange.upperBound...]))
      .trimmedForPublishing

    guard let data = jsonSubstring.data(using: .utf8),
      let parsed = try? JSONDecoder().decode([AIChatFollowUpSuggestionEnvelope].self, from: data),
      !parsed.isEmpty
    else {
      let inferred = inferDefaultSuggestions(
        content: visibleText, draft: draft, hasAutomationPlan: hasAutomationPlan)
      return ExtractionResult(displayContent: visibleText, suggestions: inferred)
    }

    let suggestions = parsed.map { item in
      AIChatFollowUpSuggestion(
        title: item.title,
        prompt: item.prompt,
        kind: item.kind == "toolAction" ? .toolAction : .prompt,
        icon: item.icon,
        toolCommand: item.toolCommand.flatMap(WorkbenchAutomationCommandID.init(rawValue:))
      )
    }

    return ExtractionResult(
      displayContent: visibleText.nilIfEmpty ?? trimmed,
      suggestions: Array(suggestions.prefix(3))
    )
  }

  public static func inferDefaultSuggestions(
    content: String,
    draft: ArticleDraft?,
    hasAutomationPlan: Bool
  ) -> [AIChatFollowUpSuggestion] {
    if hasAutomationPlan {
      return [
        AIChatFollowUpSuggestion(
          title: "查看计划执行细节",
          prompt: "请详细解释这几个操作步骤的预期影响。",
          kind: .prompt,
          icon: "info.circle"
        ),
        AIChatFollowUpSuggestion(
          title: "检查发布就绪度",
          prompt: "请帮我检查当前文章是否满足发布上线的所有要求。",
          kind: .prompt,
          icon: "checkmark.seal"
        ),
      ]
    }

    let lower = content.lowercased()
    var suggestions: [AIChatFollowUpSuggestion] = []

    if lower.contains("```") {
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "解释代码实现",
          prompt: "请逐行解释上述代码实现的核心逻辑与边界情况。",
          kind: .prompt,
          icon: "curlybraces"
        )
      )
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "添加单元测试",
          prompt: "请为上述代码编写配套的单元测试用例。",
          kind: .prompt,
          icon: "checkmark.shield"
        )
      )
    } else if lower.contains("大纲") || lower.contains("outline") || lower.contains("目录") {
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "按大纲生成初稿",
          prompt: "请按照上述大纲的每一个章节，扩写成结构完整的文章初稿。",
          kind: .prompt,
          icon: "pencil.line"
        )
      )
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "细化各章节要点",
          prompt: "请为大纲中的每一个小节补充 2-3 个核心论点和案例支撑。",
          kind: .prompt,
          icon: "list.bullet.indent"
        )
      )
    } else if lower.contains("修改") || lower.contains("润色") || lower.contains("重构")
      || lower.contains("替换")
    {
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "检查语气与一致性",
          prompt: "请通读全文，检查当前修改与整篇文章的语气和术语是否保持一致。",
          kind: .prompt,
          icon: "text.magnifyingglass"
        )
      )
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "生成社交媒体推文",
          prompt: "请基于当前修改后的核心观点，生成适合社交平台的分享摘要文案。",
          kind: .prompt,
          icon: "bubble.left.and.bubble.right"
        )
      )
    } else {
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "检查错别字与语法",
          prompt: "请检查当前文章中是否存在错别字、标点误用或语病。",
          kind: .prompt,
          icon: "character.cursor.ibeam"
        )
      )
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "提取核心 TL;DR",
          prompt: "请用 3 句话为这篇文章提炼一份精炼的 TL;DR 摘要。",
          kind: .prompt,
          icon: "text.quote"
        )
      )
      suggestions.append(
        AIChatFollowUpSuggestion(
          title: "生成文章标签与元数据",
          prompt: "请为这篇文章推荐 3-5 个精准的 Tags 并生成一段 SEO 描述。",
          kind: .prompt,
          icon: "tag"
        )
      )
    }

    return Array(suggestions.prefix(3))
  }

  private struct AIChatFollowUpSuggestionEnvelope: Decodable {
    var title: String
    var prompt: String
    var kind: String?
    var icon: String?
    var toolCommand: String?
  }
}
