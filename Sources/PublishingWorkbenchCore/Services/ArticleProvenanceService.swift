import Foundation
import PublishingDomainContracts

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
