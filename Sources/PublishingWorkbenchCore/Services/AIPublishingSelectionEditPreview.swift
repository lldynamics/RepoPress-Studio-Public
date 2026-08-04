import Foundation

public enum AIPublishingSelectionEditApplication: String, Codable, Hashable, Sendable {
  case replaceRange
  case insertAfterRange
  case insertAtRange

  public var displayName: String {
    switch self {
    case .replaceRange:
      return "替换选区"
    case .insertAfterRange:
      return "插入到选区后"
    case .insertAtRange:
      return "插入到当前位置"
    }
  }
}

public struct AIPublishingSelectionEditPreview: Identifiable, Hashable, Sendable {
  public var id: UUID
  public var draftID: ArticleDraft.ID
  public var sourceBodyMarkdown: String
  public var kind: AIPublishingActionKind
  public var range: NSRange
  public var originalText: String
  public var replacementText: String
  public var application: AIPublishingSelectionEditApplication
  public var providerName: String
  public var model: String
  public var knowledgeCitations: [KnowledgeCitation]

  public init(
    id: UUID = UUID(),
    draftID: ArticleDraft.ID,
    sourceBodyMarkdown: String,
    kind: AIPublishingActionKind,
    range: NSRange,
    originalText: String,
    replacementText: String,
    application: AIPublishingSelectionEditApplication = .replaceRange,
    providerName: String = "",
    model: String = "",
    knowledgeCitations: [KnowledgeCitation] = []
  ) {
    self.id = id
    self.draftID = draftID
    self.sourceBodyMarkdown = sourceBodyMarkdown
    self.kind = kind
    self.range = range
    self.originalText = originalText
    self.replacementText = replacementText
    self.application = application
    self.providerName = providerName
    self.model = model
    self.knowledgeCitations = knowledgeCitations
  }

  public var trimmedReplacementText: String {
    replacementText.trimmedForPublishing
  }

  public var modelSummary: String? {
    let provider = providerName.trimmedForPublishing
    let resolvedModel = model.trimmedForPublishing
    if !provider.isEmpty && !resolvedModel.isEmpty {
      return "\(provider) · \(resolvedModel)"
    }
    return resolvedModel.nilIfEmpty ?? provider.nilIfEmpty
  }
}

public enum AIPublishingSelectionEditPreviewApplyError: LocalizedError, Equatable {
  case draftChanged
  case sourceBodyChanged
  case emptyReplacement
  case invalidRange
  case originalTextChanged

  public var errorDescription: String? {
    switch self {
    case .draftChanged:
      return "当前文章已切换，请重新生成 AI 预览。"
    case .sourceBodyChanged:
      return "文章正文已变化，请重新生成 AI 预览。"
    case .emptyReplacement:
      return "AI 预览内容为空，未应用。"
    case .invalidRange:
      return "原选区已经失效，请重新选择正文。"
    case .originalTextChanged:
      return "原选区内容已变化，请重新生成 AI 预览。"
    }
  }
}

public enum AIPublishingSelectionEditPreviewService {
  public static func apply(
    _ preview: AIPublishingSelectionEditPreview,
    to draft: ArticleDraft
  ) throws -> ArticleDraft {
    guard preview.draftID == draft.id else {
      throw AIPublishingSelectionEditPreviewApplyError.draftChanged
    }
    guard preview.sourceBodyMarkdown == draft.bodyMarkdown else {
      throw AIPublishingSelectionEditPreviewApplyError.sourceBodyChanged
    }

    let replacement = preview.trimmedReplacementText
    guard !replacement.isEmpty else {
      throw AIPublishingSelectionEditPreviewApplyError.emptyReplacement
    }

    let source = draft.bodyMarkdown as NSString
    guard preview.range.location >= 0,
          preview.range.length >= 0,
          preview.range.location + preview.range.length <= source.length
    else {
      throw AIPublishingSelectionEditPreviewApplyError.invalidRange
    }

    if preview.range.length > 0 {
      guard source.substring(with: preview.range) == preview.originalText else {
        throw AIPublishingSelectionEditPreviewApplyError.originalTextChanged
      }
    }

    var updated = draft
    switch preview.application {
    case .replaceRange:
      updated.bodyMarkdown = source.replacingCharacters(in: preview.range, with: replacement)
    case .insertAfterRange:
      let insertionLocation = preview.range.location + preview.range.length
      let insertion = formattedInsertion(
        replacement,
        in: source,
        at: insertionLocation,
        preferredLeadingBreaks: preview.range.length > 0 ? 2 : 0
      )
      updated.bodyMarkdown = source.replacingCharacters(
        in: NSRange(location: insertionLocation, length: 0),
        with: insertion
      )
    case .insertAtRange:
      let insertion = formattedInsertion(
        replacement,
        in: source,
        at: preview.range.location,
        preferredLeadingBreaks: 0
      )
      updated.bodyMarkdown = source.replacingCharacters(
        in: NSRange(location: preview.range.location, length: 0),
        with: insertion
      )
    }
    return updated
  }

  private static func formattedInsertion(
    _ text: String,
    in source: NSString,
    at location: Int,
    preferredLeadingBreaks: Int
  ) -> String {
    var insertion = text
    if location > 0 {
      let prefix = source.substring(to: location)
      if !prefix.hasSuffix("\n") {
        insertion = String(repeating: "\n", count: max(1, preferredLeadingBreaks)) + insertion
      }
    }
    if location < source.length {
      let suffix = source.substring(from: location)
      if !suffix.hasPrefix("\n") {
        insertion += "\n"
      }
    }
    return insertion
  }
}
