import Foundation

/// A range in the source Markdown, measured in UTF-16 code units.
///
/// UTF-16 deliberately matches `NSRange`, `NSString`, and the AppKit editor.
public struct AIStructuredEditSourceRange: Codable, Hashable, Sendable {
  public let location: Int
  public let length: Int

  public init(location: Int, length: Int) {
    self.location = location
    self.length = length
  }

  public init(_ range: NSRange) {
    self.init(location: range.location, length: range.length)
  }

  public var nsRange: NSRange {
    NSRange(location: location, length: length)
  }
}

public struct AIStructuredEditProposal: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public let range: AIStructuredEditSourceRange
  public let originalText: String
  public let replacementText: String
  public let reason: String
  public let category: AIStructuredEditCategory
  public let confidence: Double

  public init(
    id: String,
    range: AIStructuredEditSourceRange,
    originalText: String,
    replacementText: String,
    reason: String,
    category: AIStructuredEditCategory,
    confidence: Double
  ) {
    self.id = id
    self.range = range
    self.originalText = originalText
    self.replacementText = replacementText
    self.reason = reason
    self.category = category
    self.confidence = confidence
  }
}

/// Versioned top-level response expected from a structured edit AI request.
public struct AIStructuredEditDocument: Codable, Hashable, Sendable {
  public let schemaVersion: Int
  public let changes: [AIStructuredEditProposal]

  public init(schemaVersion: Int = 1, changes: [AIStructuredEditProposal]) {
    self.schemaVersion = schemaVersion
    self.changes = changes
  }
}

public enum AIStructuredEditValidationError: LocalizedError, Equatable, Sendable {
  case emptyResponse
  case responseIsNotStrictJSON
  case invalidJSONContract
  case unsupportedSchemaVersion(Int)
  case tooManyChanges(maximum: Int)
  case duplicateIdentifier(String)
  case emptyIdentifier
  case emptyReason(String)
  case invalidConfidence(String)
  case invalidRange(String)
  case originalLengthMismatch(String)
  case originalTextChanged(String)
  case overlappingChanges(String, String)

  public var errorDescription: String? {
    switch self {
    case .emptyResponse:
      return "AI 返回内容为空。"
    case .responseIsNotStrictJSON:
      return "AI 返回内容必须是完整 JSON，或仅包含一个 JSON 代码围栏。"
    case .invalidJSONContract:
      return "AI 返回的 JSON 不符合结构化修改协议。"
    case .unsupportedSchemaVersion(let version):
      return "不支持结构化修改协议版本 \(version)。"
    case .tooManyChanges(let maximum):
      return "AI 返回的修改项过多，单次最多允许 \(maximum) 项。"
    case .duplicateIdentifier(let identifier):
      return "AI 返回了重复的修改编号：\(identifier)。"
    case .emptyIdentifier:
      return "AI 返回了缺少编号的修改项。"
    case .emptyReason(let identifier):
      return "修改项 \(identifier) 缺少修改原因。"
    case .invalidConfidence(let identifier):
      return "修改项 \(identifier) 的置信度必须位于 0 到 1 之间。"
    case .invalidRange(let identifier):
      return "修改项 \(identifier) 的原文范围无效。"
    case .originalLengthMismatch(let identifier):
      return "修改项 \(identifier) 的原文字数与范围长度不一致。"
    case .originalTextChanged(let identifier):
      return "修改项 \(identifier) 对应的原文已经变化，请重新校对。"
    case .overlappingChanges(let first, let second):
      return "修改项 \(first) 与 \(second) 的原文范围重叠。"
    }
  }
}

public enum AIStructuredEditParser {
  public static let currentSchemaVersion = 1
  public static let maximumChangeCount = 500

  /// Parses either a bare JSON object or one `json` fenced block.
  ///
  /// Prose before/after the JSON, multiple fences, unknown keys, and partially
  /// extracted JSON are rejected so an explanatory AI response can never be
  /// mistaken for executable edits.
  public static func parse(
    _ response: String,
    sourceBody: String
  ) throws -> AIStructuredEditDocument {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AIStructuredEditValidationError.emptyResponse
    }

    let jsonText = try strictJSONText(from: trimmed)
    guard let data = jsonText.data(using: .utf8) else {
      throw AIStructuredEditValidationError.invalidJSONContract
    }
    try validateExactKeys(in: data)

    let document: AIStructuredEditDocument
    do {
      document = try JSONDecoder().decode(AIStructuredEditDocument.self, from: data)
    } catch {
      throw AIStructuredEditValidationError.invalidJSONContract
    }
    try AIStructuredEditValidator.validate(document, against: sourceBody)
    return document
  }

  private static func strictJSONText(from response: String) throws -> String {
    guard response.hasPrefix("```") else {
      guard response.hasPrefix("{"), response.hasSuffix("}") else {
        throw AIStructuredEditValidationError.responseIsNotStrictJSON
      }
      return response
    }

    guard
      let expression = try? NSRegularExpression(
        pattern: #"\A```json[ \t]*\r?\n([\s\S]*?)\r?\n```\z"#,
        options: [.caseInsensitive]
      )
    else {
      throw AIStructuredEditValidationError.responseIsNotStrictJSON
    }
    let source = response as NSString
    let fullRange = NSRange(location: 0, length: source.length)
    guard
      let match = expression.firstMatch(in: response, range: fullRange),
      match.range == fullRange,
      match.range(at: 1).location != NSNotFound
    else {
      throw AIStructuredEditValidationError.responseIsNotStrictJSON
    }
    return source.substring(with: match.range(at: 1))
  }

  private static func validateExactKeys(in data: Data) throws {
    let root: Any
    do {
      root = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw AIStructuredEditValidationError.invalidJSONContract
    }

    guard
      let object = root as? [String: Any],
      Set(object.keys) == Set(["schemaVersion", "changes"]),
      object["schemaVersion"] is NSNumber,
      let changes = object["changes"] as? [[String: Any]]
    else {
      throw AIStructuredEditValidationError.invalidJSONContract
    }

    let proposalKeys = Set([
      "id",
      "range",
      "originalText",
      "replacementText",
      "reason",
      "category",
      "confidence",
    ])
    let rangeKeys = Set(["location", "length"])
    for change in changes {
      guard
        Set(change.keys) == proposalKeys,
        let range = change["range"] as? [String: Any],
        Set(range.keys) == rangeKeys
      else {
        throw AIStructuredEditValidationError.invalidJSONContract
      }
    }
  }
}

public enum AIStructuredEditValidator {
  public static func validate(
    _ document: AIStructuredEditDocument,
    against sourceBody: String
  ) throws {
    guard document.schemaVersion == AIStructuredEditParser.currentSchemaVersion else {
      throw AIStructuredEditValidationError.unsupportedSchemaVersion(document.schemaVersion)
    }
    guard document.changes.count <= AIStructuredEditParser.maximumChangeCount else {
      throw AIStructuredEditValidationError.tooManyChanges(
        maximum: AIStructuredEditParser.maximumChangeCount
      )
    }

    let source = sourceBody as NSString
    var identifiers = Set<String>()
    for proposal in document.changes {
      let identifier = proposal.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !identifier.isEmpty else {
        throw AIStructuredEditValidationError.emptyIdentifier
      }
      guard identifiers.insert(identifier).inserted else {
        throw AIStructuredEditValidationError.duplicateIdentifier(identifier)
      }
      guard !proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIStructuredEditValidationError.emptyReason(identifier)
      }
      guard proposal.confidence.isFinite, (0...1).contains(proposal.confidence) else {
        throw AIStructuredEditValidationError.invalidConfidence(identifier)
      }

      let location = proposal.range.location
      let length = proposal.range.length
      guard
        location >= 0,
        length >= 0,
        location <= source.length,
        length <= source.length - location
      else {
        throw AIStructuredEditValidationError.invalidRange(identifier)
      }
      guard (proposal.originalText as NSString).length == length else {
        throw AIStructuredEditValidationError.originalLengthMismatch(identifier)
      }
      guard source.substring(with: proposal.range.nsRange) == proposal.originalText else {
        throw AIStructuredEditValidationError.originalTextChanged(identifier)
      }
    }

    let ordered = document.changes.sorted(by: proposalOrder)
    for index in 1..<ordered.count {
      let previous = ordered[index - 1]
      let current = ordered[index]
      let previousEnd = previous.range.location + previous.range.length
      let sameInsertionPoint = previous.range.location == current.range.location
      if sameInsertionPoint || previousEnd > current.range.location {
        throw AIStructuredEditValidationError.overlappingChanges(previous.id, current.id)
      }
    }
  }

  fileprivate static func proposalOrder(
    _ lhs: AIStructuredEditProposal,
    _ rhs: AIStructuredEditProposal
  ) -> Bool {
    if lhs.range.location == rhs.range.location {
      if lhs.range.length == rhs.range.length {
        return lhs.id < rhs.id
      }
      return lhs.range.length < rhs.range.length
    }
    return lhs.range.location < rhs.range.location
  }
}

public enum AIStructuredEditDecision: String, Codable, Hashable, Sendable {
  case pending
  case accepted
  case rejected
}

public struct AIStructuredEditReview: Codable, Hashable, Sendable {
  public let document: AIStructuredEditDocument
  public let decisions: [String: AIStructuredEditDecision]

  public init(
    document: AIStructuredEditDocument,
    decisions: [String: AIStructuredEditDecision] = [:]
  ) {
    self.document = document
    self.decisions = decisions
  }

  public func decision(for proposalID: String) -> AIStructuredEditDecision {
    decisions[proposalID] ?? .pending
  }
}

public struct AIStructuredEditDiffHunk: Identifiable, Hashable, Sendable {
  public let id: String
  public let decision: AIStructuredEditDecision
  public let originalRange: AIStructuredEditSourceRange
  public let resultingRange: AIStructuredEditSourceRange?
  public let originalText: String
  public let replacementText: String
  public let reason: String
  public let category: AIStructuredEditCategory
  public let confidence: Double

  public init(
    id: String,
    decision: AIStructuredEditDecision,
    originalRange: AIStructuredEditSourceRange,
    resultingRange: AIStructuredEditSourceRange?,
    originalText: String,
    replacementText: String,
    reason: String,
    category: AIStructuredEditCategory,
    confidence: Double
  ) {
    self.id = id
    self.decision = decision
    self.originalRange = originalRange
    self.resultingRange = resultingRange
    self.originalText = originalText
    self.replacementText = replacementText
    self.reason = reason
    self.category = category
    self.confidence = confidence
  }
}

public struct AIStructuredEditApplicationResult: Hashable, Sendable {
  public let sourceBody: String
  public let finalBody: String
  public let hunks: [AIStructuredEditDiffHunk]
  public let acceptedIDs: [String]
  public let rejectedIDs: [String]
  public let pendingIDs: [String]

  public init(
    sourceBody: String,
    finalBody: String,
    hunks: [AIStructuredEditDiffHunk],
    acceptedIDs: [String],
    rejectedIDs: [String],
    pendingIDs: [String]
  ) {
    self.sourceBody = sourceBody
    self.finalBody = finalBody
    self.hunks = hunks
    self.acceptedIDs = acceptedIDs
    self.rejectedIDs = rejectedIDs
    self.pendingIDs = pendingIDs
  }

  public var hasAppliedChanges: Bool {
    !acceptedIDs.isEmpty
  }
}

public enum AIStructuredEditReviewError: LocalizedError, Equatable, Sendable {
  case unknownProposal(String)

  public var errorDescription: String? {
    switch self {
    case .unknownProposal(let identifier):
      return "找不到修改项 \(identifier)。"
    }
  }
}

public enum AIStructuredEditReviewService {
  public static func initialReview(
    for document: AIStructuredEditDocument
  ) -> AIStructuredEditReview {
    AIStructuredEditReview(document: document)
  }

  public static func accepting(
    _ proposalID: String,
    in review: AIStructuredEditReview
  ) throws -> AIStructuredEditReview {
    try setting(.accepted, for: proposalID, in: review)
  }

  public static func rejecting(
    _ proposalID: String,
    in review: AIStructuredEditReview
  ) throws -> AIStructuredEditReview {
    try setting(.rejected, for: proposalID, in: review)
  }

  public static func resetting(
    _ proposalID: String,
    in review: AIStructuredEditReview
  ) throws -> AIStructuredEditReview {
    try setting(.pending, for: proposalID, in: review)
  }

  public static func acceptingAll(
    in review: AIStructuredEditReview
  ) -> AIStructuredEditReview {
    settingAll(.accepted, in: review)
  }

  public static func rejectingAll(
    in review: AIStructuredEditReview
  ) -> AIStructuredEditReview {
    settingAll(.rejected, in: review)
  }

  public static func apply(
    _ review: AIStructuredEditReview,
    to sourceBody: String
  ) throws -> AIStructuredEditApplicationResult {
    try AIStructuredEditValidator.validate(review.document, against: sourceBody)

    let ordered = review.document.changes.sorted(by: AIStructuredEditValidator.proposalOrder)
    let accepted = ordered.filter { review.decision(for: $0.id) == .accepted }
    var finalBody = sourceBody
    for proposal in accepted.reversed() {
      finalBody = (finalBody as NSString).replacingCharacters(
        in: proposal.range.nsRange,
        with: proposal.replacementText
      )
    }

    var acceptedOffset = 0
    var hunks: [AIStructuredEditDiffHunk] = []
    for proposal in ordered {
      let decision = review.decision(for: proposal.id)
      let resultingRange: AIStructuredEditSourceRange?
      if decision == .accepted {
        resultingRange = AIStructuredEditSourceRange(
          location: proposal.range.location + acceptedOffset,
          length: (proposal.replacementText as NSString).length
        )
        acceptedOffset +=
          (proposal.replacementText as NSString).length - proposal.range.length
      } else {
        resultingRange = nil
      }
      hunks.append(
        AIStructuredEditDiffHunk(
          id: proposal.id,
          decision: decision,
          originalRange: proposal.range,
          resultingRange: resultingRange,
          originalText: proposal.originalText,
          replacementText: proposal.replacementText,
          reason: proposal.reason,
          category: proposal.category,
          confidence: proposal.confidence
        ))
    }

    return AIStructuredEditApplicationResult(
      sourceBody: sourceBody,
      finalBody: finalBody,
      hunks: hunks,
      acceptedIDs: ordered.filter { review.decision(for: $0.id) == .accepted }.map(\.id),
      rejectedIDs: ordered.filter { review.decision(for: $0.id) == .rejected }.map(\.id),
      pendingIDs: ordered.filter { review.decision(for: $0.id) == .pending }.map(\.id)
    )
  }

  private static func setting(
    _ decision: AIStructuredEditDecision,
    for proposalID: String,
    in review: AIStructuredEditReview
  ) throws -> AIStructuredEditReview {
    guard review.document.changes.contains(where: { $0.id == proposalID }) else {
      throw AIStructuredEditReviewError.unknownProposal(proposalID)
    }
    var decisions = review.decisions
    if decision == .pending {
      decisions.removeValue(forKey: proposalID)
    } else {
      decisions[proposalID] = decision
    }
    return AIStructuredEditReview(document: review.document, decisions: decisions)
  }

  private static func settingAll(
    _ decision: AIStructuredEditDecision,
    in review: AIStructuredEditReview
  ) -> AIStructuredEditReview {
    AIStructuredEditReview(
      document: review.document,
      decisions: Dictionary(
        uniqueKeysWithValues: review.document.changes.map { ($0.id, decision) }
      )
    )
  }
}
