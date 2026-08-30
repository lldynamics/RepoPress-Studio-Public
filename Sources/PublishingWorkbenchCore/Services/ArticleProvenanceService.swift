import Foundation

public enum ArticleProvenance: String, CaseIterable, Identifiable, Sendable {
  case humanOriginal
  case aiAssisted
  case aiAuthored
  case hybrid

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .humanOriginal:
      return "真人原稿"
    case .aiAssisted:
      return "AI 辅助"
    case .aiAuthored:
      return "AI 主笔"
    case .hybrid:
      return "人机混合"
    }
  }

  public var systemImage: String {
    switch self {
    case .humanOriginal:
      return "person.fill"
    case .aiAssisted:
      return "wand.and.sparkles"
    case .aiAuthored:
      return "cpu"
    case .hybrid:
      return "person.2.fill"
    }
  }

  public var tag: String? {
    switch self {
    case .humanOriginal:
      return nil
    case .aiAssisted:
      return "AI辅助"
    case .aiAuthored:
      return "AI主笔"
    case .hybrid:
      return "人机混合"
    }
  }

  public var disclosureText: String? {
    switch self {
    case .humanOriginal:
      return nil
    case .aiAssisted:
      return "本文在资料整理、结构优化或文字润色过程中使用了 AI 辅助，内容由作者审核。"
    case .aiAuthored:
      return "本文主要由 AI 生成，作者可能进行了整理或编辑，请读者自行核验关键信息。"
    case .hybrid:
      return "本文由作者与 AI 共同完成，选题、判断与最终内容由作者负责。"
    }
  }
}

public enum ArticleProvenanceEditingIssue: Error, Equatable, Sendable {
  case malformedManagedDisclosure
}

public struct ArticleProvenanceEditingResult: Equatable, Sendable {
  public var draft: ArticleDraft
  public var issue: ArticleProvenanceEditingIssue?

  public init(
    draft: ArticleDraft,
    issue: ArticleProvenanceEditingIssue? = nil
  ) {
    self.draft = draft
    self.issue = issue
  }

  public var isValid: Bool {
    issue == nil
  }
}

/// Keeps the user-facing provenance tag and the visible Markdown disclosure in sync.
/// The markers make repeated edits idempotent and ensure that removing a provenance
/// never deletes an unrelated blockquote written by the author.
public struct ArticleProvenanceService: Sendable {
  public static let managedDisclosureStart = "<!-- repopress:provenance:start -->"
  public static let managedDisclosureEnd = "<!-- repopress:provenance:end -->"

  private static let legacyDisclosurePrefix = "> 创作说明："

  public init() {}

  public func provenance(for draft: ArticleDraft) -> ArticleProvenance {
    for tag in draft.tags {
      if let provenance = ArticleProvenance.allCases.first(where: { $0.tag == tag }) {
        return provenance
      }
    }

    let hasManagedBoundary =
      draft.bodyMarkdown.contains(Self.managedDisclosureStart)
      && draft.bodyMarkdown.contains(Self.managedDisclosureEnd)
    if hasManagedBoundary {
      for provenance in ArticleProvenance.allCases {
        guard let disclosureText = provenance.disclosureText else { continue }
        if draft.bodyMarkdown.contains("> 创作说明：\(disclosureText)") {
          return provenance
        }
      }
    }
    return .humanOriginal
  }

  public func applying(
    _ provenance: ArticleProvenance,
    to draft: ArticleDraft
  ) -> ArticleProvenanceEditingResult {
    let managedRange: Range<String.Index>?
    switch managedDisclosureRange(in: draft.bodyMarkdown) {
    case .none:
      managedRange = nil
    case .range(let range):
      managedRange = range
    case .malformed:
      return ArticleProvenanceEditingResult(
        draft: draft,
        issue: .malformedManagedDisclosure
      )
    }

    let previousProvenance = self.provenance(for: draft)
    var updated = draft
    updated.tags = normalizedTags(draft.tags, adding: provenance.tag)

    let replacement = managedDisclosure(for: provenance)
    if let managedRange {
      updated.bodyMarkdown = replacingDisclosure(
        in: draft.bodyMarkdown,
        range: managedRange,
        with: replacement
      )
    } else if previousProvenance != .humanOriginal,
      let legacyRange = legacyDisclosureRange(in: draft.bodyMarkdown)
    {
      updated.bodyMarkdown = replacingDisclosure(
        in: draft.bodyMarkdown,
        range: legacyRange,
        with: replacement
      )
    } else if let replacement {
      updated.bodyMarkdown = prependingDisclosure(replacement, to: draft.bodyMarkdown)
    }

    return ArticleProvenanceEditingResult(draft: updated)
  }

  private func normalizedTags(_ tags: [String], adding provenanceTag: String?) -> [String] {
    let provenanceTags = Set(ArticleProvenance.allCases.compactMap(\.tag))
    var normalized = tags.filter { !provenanceTags.contains($0) }
    if let provenanceTag {
      normalized.append(provenanceTag)
    }
    return normalized
  }

  private func managedDisclosure(for provenance: ArticleProvenance) -> String? {
    guard let disclosureText = provenance.disclosureText else { return nil }
    return [
      Self.managedDisclosureStart,
      "> 创作说明：\(disclosureText)",
      Self.managedDisclosureEnd,
    ].joined(separator: "\n")
  }

  private enum ManagedDisclosureRange {
    case none
    case range(Range<String.Index>)
    case malformed
  }

  private func managedDisclosureRange(in source: String) -> ManagedDisclosureRange {
    let startRange = source.range(of: Self.managedDisclosureStart)
    let endRange = source.range(of: Self.managedDisclosureEnd)

    guard startRange != nil || endRange != nil else { return .none }
    guard let startRange, let endRange,
      startRange.lowerBound < endRange.lowerBound,
      source.range(
        of: Self.managedDisclosureStart,
        range: startRange.upperBound..<source.endIndex
      ) == nil,
      source.range(
        of: Self.managedDisclosureEnd,
        range: endRange.upperBound..<source.endIndex
      ) == nil
    else {
      return .malformed
    }

    return .range(startRange.lowerBound..<endRange.upperBound)
  }

  private func legacyDisclosureRange(in source: String) -> Range<String.Index>? {
    var firstContentIndex = source.startIndex
    while firstContentIndex < source.endIndex,
      source[firstContentIndex].isNewline
    {
      firstContentIndex = source.index(after: firstContentIndex)
    }

    guard source[firstContentIndex...].hasPrefix(Self.legacyDisclosurePrefix) else {
      return nil
    }
    let lineEnd = source[firstContentIndex...].firstIndex(of: "\n") ?? source.endIndex
    return source.startIndex..<lineEnd
  }

  private func prependingDisclosure(_ disclosure: String, to source: String) -> String {
    let body = droppingLeadingNewlines(from: source)
    return body.isEmpty ? disclosure : disclosure + "\n\n" + body
  }

  private func replacingDisclosure(
    in source: String,
    range: Range<String.Index>,
    with replacement: String?
  ) -> String {
    let prefix = String(source[..<range.lowerBound])
    let suffix = String(source[range.upperBound...])
    let rangeIsAtTop = prefix.allSatisfy { $0 == " " || $0 == "\t" || $0.isNewline }

    if rangeIsAtTop {
      let body = droppingLeadingNewlines(from: suffix)
      guard let replacement else { return body }
      return body.isEmpty ? replacement : replacement + "\n\n" + body
    }

    return prefix + (replacement ?? "") + suffix
  }

  private func droppingLeadingNewlines(from source: String) -> String {
    var firstContentIndex = source.startIndex
    while firstContentIndex < source.endIndex,
      source[firstContentIndex].isNewline
    {
      firstContentIndex = source.index(after: firstContentIndex)
    }
    return String(source[firstContentIndex...])
  }
}
