import Foundation
import PublishingCoreSupport

public struct AIPublishingImageTextTarget: Identifiable, Hashable, Sendable {
  public var id: String
  public var draftID: UUID
  public var attachmentID: UUID
  public var draftTitle: String
  public var markdownPath: String
  public var articleSummary: String
  public var articleExcerpt: String
  public var filename: String
  public var imagePath: String
  public var existingAlt: String
  public var existingCaption: String
  public var isCover: Bool
  public var isReferencedInMarkdown: Bool

  public init(
    id: String,
    draftID: UUID,
    attachmentID: UUID,
    draftTitle: String,
    markdownPath: String,
    articleSummary: String,
    articleExcerpt: String,
    filename: String,
    imagePath: String,
    existingAlt: String,
    existingCaption: String,
    isCover: Bool,
    isReferencedInMarkdown: Bool
  ) {
    self.id = id
    self.draftID = draftID
    self.attachmentID = attachmentID
    self.draftTitle = draftTitle
    self.markdownPath = markdownPath
    self.articleSummary = articleSummary
    self.articleExcerpt = articleExcerpt
    self.filename = filename
    self.imagePath = imagePath
    self.existingAlt = existingAlt
    self.existingCaption = existingCaption
    self.isCover = isCover
    self.isReferencedInMarkdown = isReferencedInMarkdown
  }
}

public struct AIPublishingImageTextVisionInput: Hashable, Sendable {
  public var targetID: String
  public var attachment: AIChatImageAttachment

  public init(targetID: String, attachment: AIChatImageAttachment) {
    self.targetID = targetID
    self.attachment = attachment
  }
}

public struct AIPublishingImageTextSuggestion: Identifiable, Hashable, Sendable {
  public var id: String
  public var draftID: UUID
  public var attachmentID: UUID
  public var filename: String
  public var imagePath: String
  public var altText: String
  public var caption: String
  public var reason: String

  public init(
    id: String,
    draftID: UUID,
    attachmentID: UUID,
    filename: String,
    imagePath: String,
    altText: String,
    caption: String,
    reason: String
  ) {
    self.id = id
    self.draftID = draftID
    self.attachmentID = attachmentID
    self.filename = filename
    self.imagePath = imagePath
    self.altText = altText
    self.caption = caption
    self.reason = reason
  }

  public var hasSuggestion: Bool {
    !altText.trimmedForPublishing.isEmpty || !caption.trimmedForPublishing.isEmpty
  }
}

public enum AIPublishingImageTextSuggestionParser {
  public static func parse(
    _ text: String,
    targets: [AIPublishingImageTextTarget]
  ) -> [AIPublishingImageTextSuggestion] {
    guard let data = cleanedJSON(from: text).data(using: .utf8) else {
      return []
    }

    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      return []
    }

    let targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    var seen: Set<String> = []
    var suggestions: [AIPublishingImageTextSuggestion] = []

    for item in payload.items {
      let id = item.id.trimmedForPublishing
      guard let target = targetsByID[id], !seen.contains(id) else {
        continue
      }
      seen.insert(id)

      let suggestion = AIPublishingImageTextSuggestion(
        id: id,
        draftID: target.draftID,
        attachmentID: target.attachmentID,
        filename: target.filename,
        imagePath: target.imagePath,
        altText: item.alt.trimmedForPublishing,
        caption: item.caption.trimmedForPublishing,
        reason: item.reason.trimmedForPublishing
      )
      if suggestion.hasSuggestion {
        suggestions.append(suggestion)
      }
    }

    return suggestions
  }

  private static func cleanedJSON(from text: String) -> String {
    var trimmed = text.trimmedForPublishing
    if trimmed.hasPrefix("```") {
      let lines = trimmed.components(separatedBy: .newlines)
      let bodyLines = lines.dropFirst().dropLast(lines.last?.trimmedForPublishing == "```" ? 1 : 0)
      trimmed = bodyLines.joined(separator: "\n").trimmedForPublishing
    }
    return trimmed
  }

  private struct Payload: Decodable {
    var items: [Item]

    enum CodingKeys: String, CodingKey {
      case items
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
    }
  }

  private struct Item: Decodable {
    var id: String
    var alt: String
    var caption: String
    var reason: String

    enum CodingKeys: String, CodingKey {
      case id
      case alt
      case altText = "alt_text"
      case caption
      case reason
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
      alt = try container.decodeIfPresent(String.self, forKey: .alt)
        ?? container.decodeIfPresent(String.self, forKey: .altText) ?? ""
      caption = try container.decodeIfPresent(String.self, forKey: .caption) ?? ""
      reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
  }
}
