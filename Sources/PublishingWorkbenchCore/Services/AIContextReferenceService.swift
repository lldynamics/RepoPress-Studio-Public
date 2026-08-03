import Foundation

public enum AIContextReferenceKind: String, Codable, CaseIterable, Hashable, Sendable {
  case currentSelection
  case currentArticle
  case specifiedArticle
  case siteProfile
  case knowledgeEntry
  case publishCheck

  public var displayName: String {
    switch self {
    case .currentSelection:
      return "当前选区"
    case .currentArticle:
      return "当前文章"
    case .specifiedArticle:
      return "指定文章"
    case .siteProfile:
      return "站点配置"
    case .knowledgeEntry:
      return "资料条目"
    case .publishCheck:
      return "发布检查"
    }
  }
}

/// Describes context selected for an AI request without storing its body.
///
/// The actual request builder remains responsible for resolving `resourceID`
/// into content at send time. Keeping this model content-free makes the
/// confirmation summary safe to persist and log.
public struct AIContextReference: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let kind: AIContextReferenceKind
  public let resourceID: String?
  public let displayName: String
  public let sourceRange: AIStructuredEditSourceRange?
  public let characterCount: Int

  public init(
    id: UUID = UUID(),
    kind: AIContextReferenceKind,
    resourceID: String? = nil,
    displayName: String = "",
    sourceRange: AIStructuredEditSourceRange? = nil,
    characterCount: Int
  ) {
    self.id = id
    self.kind = kind
    self.resourceID = resourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.sourceRange = sourceRange
    self.characterCount = max(0, characterCount)
  }

  public static func currentSelection(
    draftID: ArticleDraft.ID,
    range: NSRange,
    characterCount: Int
  ) -> AIContextReference {
    AIContextReference(
      kind: .currentSelection,
      resourceID: draftID.uuidString,
      sourceRange: AIStructuredEditSourceRange(range),
      characterCount: characterCount
    )
  }

  public static func currentArticle(
    draftID: ArticleDraft.ID,
    title: String,
    characterCount: Int
  ) -> AIContextReference {
    AIContextReference(
      kind: .currentArticle,
      resourceID: draftID.uuidString,
      displayName: title,
      characterCount: characterCount
    )
  }

  public static func specifiedArticle(
    draftID: ArticleDraft.ID,
    title: String,
    characterCount: Int
  ) -> AIContextReference {
    AIContextReference(
      kind: .specifiedArticle,
      resourceID: draftID.uuidString,
      displayName: title,
      characterCount: characterCount
    )
  }

  public static func siteProfile(
    profileID: SiteProfile.ID,
    name: String,
    characterCount: Int
  ) -> AIContextReference {
    AIContextReference(
      kind: .siteProfile,
      resourceID: profileID.uuidString,
      displayName: name,
      characterCount: characterCount
    )
  }

  public static func knowledgeEntry(
    documentID: UUID,
    title: String,
    characterCount: Int
  ) -> AIContextReference {
    AIContextReference(
      kind: .knowledgeEntry,
      resourceID: documentID.uuidString,
      displayName: title,
      characterCount: characterCount
    )
  }

  public static func publishCheck(
    draftID: ArticleDraft.ID,
    issueCount: Int,
    characterCount: Int
  ) -> AIContextReference {
    AIContextReference(
      kind: .publishCheck,
      resourceID: draftID.uuidString,
      displayName: "\(max(0, issueCount)) 项",
      characterCount: characterCount
    )
  }
}

public struct AIContextTransmissionItem: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let kind: AIContextReferenceKind
  public let label: String
  public let characterCount: Int

  public init(
    id: UUID,
    kind: AIContextReferenceKind,
    label: String,
    characterCount: Int
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.characterCount = characterCount
  }
}

public struct AIContextTransmissionSummary: Hashable, Sendable {
  public let items: [AIContextTransmissionItem]
  public let totalCharacterCount: Int
  public let displayText: String

  public init(
    items: [AIContextTransmissionItem],
    totalCharacterCount: Int,
    displayText: String
  ) {
    self.items = items
    self.totalCharacterCount = totalCharacterCount
    self.displayText = displayText
  }
}

public enum AIContextTransmissionSummaryService {
  public static func make(
    references: [AIContextReference]
  ) -> AIContextTransmissionSummary {
    var seen = Set<UUID>()
    let uniqueReferences = references.filter { seen.insert($0.id).inserted }
    let items = uniqueReferences.map { reference in
      let name =
        reference.displayName.isEmpty
        ? reference.kind.displayName
        : "\(reference.kind.displayName)：\(reference.displayName)"
      return AIContextTransmissionItem(
        id: reference.id,
        kind: reference.kind,
        label: name,
        characterCount: reference.characterCount
      )
    }
    let total = items.reduce(into: 0) { partialResult, item in
      let (sum, overflow) = partialResult.addingReportingOverflow(item.characterCount)
      partialResult = overflow ? Int.max : sum
    }
    let detail =
      items
      .map { "\($0.label)（约 \($0.characterCount) 字）" }
      .joined(separator: "、")
    let displayText: String
    if items.isEmpty {
      displayText = "本次不发送额外上下文。"
    } else {
      displayText = "将发送 \(items.count) 项上下文，共约 \(total) 字：\(detail)"
    }
    return AIContextTransmissionSummary(
      items: items,
      totalCharacterCount: total,
      displayText: displayText
    )
  }
}
