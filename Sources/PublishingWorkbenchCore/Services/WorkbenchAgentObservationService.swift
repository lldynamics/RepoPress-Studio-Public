import Foundation

// MARK: - Draft search

/// A bounded, one-row-per-draft projection of the existing full-text search
/// service.  Agent tools should receive this projection rather than the full
/// ``ArticleDraft`` value so that private repository metadata and large body
/// contents are not accidentally copied into a tool response.
public struct WorkbenchAgentDraftSearchHit: Codable, Equatable, Hashable, Identifiable, Sendable {
  public var id: UUID { draftID }

  public let draftID: UUID
  public let title: String
  public let field: String
  public let snippet: String
  public let updatedAt: Date

  public init(
    draftID: UUID,
    title: String,
    field: String,
    snippet: String,
    updatedAt: Date
  ) {
    self.draftID = draftID
    self.title = title
    self.field = field
    self.snippet = snippet
    self.updatedAt = updatedAt
  }
}

/// Local-only search for an already-authorized set of drafts.
///
/// The caller owns scope and visibility filtering.  This service only
/// searches the values it receives and never opens a repository or performs a
/// network request.
public struct WorkbenchAgentDraftSearchService: Sendable {
  public static let maximumResultLimit = 20
  public static let maximumQueryLength = 512
  public static let maximumIndexedTextLength = 16_000
  public static let maximumOutputTextLength = 480
  public static let maximumDraftCount = 2_000

  private let searchService: DraftFullTextSearchService

  public init(searchService: DraftFullTextSearchService = DraftFullTextSearchService()) {
    self.searchService = searchService
  }

  /// Returns at most one stable hit per draft.  Invalid limits are clamped to
  /// the tool contract's 1...20 range; an empty query still returns no rows.
  public func search(
    query: String,
    drafts: [ArticleDraft],
    limit: Int = 10
  ) -> [WorkbenchAgentDraftSearchHit] {
    guard !Task.isCancelled else { return [] }

    let boundedQuery = bounded(query, maximumLength: Self.maximumQueryLength)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !boundedQuery.isEmpty else { return [] }

    let uniqueDrafts = uniqueDrafts(from: drafts)
    guard !uniqueDrafts.isEmpty, !Task.isCancelled else { return [] }

    let normalizedLimit = min(Self.maximumResultLimit, max(1, limit))
    let indexedDrafts = uniqueDrafts.prefix(Self.maximumDraftCount).map(boundedDraft)
    let hits = searchService.search(
      query: boundedQuery,
      drafts: Array(indexedDrafts),
      limit: normalizedLimit,
      matchesPerDraft: 1
    )

    guard !Task.isCancelled else { return [] }
    var seenDraftIDs = Set<UUID>()
    return hits.compactMap { hit in
      guard !Task.isCancelled,
        seenDraftIDs.insert(hit.draftID).inserted
      else {
        return nil
      }
      return WorkbenchAgentDraftSearchHit(
        draftID: hit.draftID,
        title: bounded(hit.draftTitle, maximumLength: Self.maximumOutputTextLength),
        field: hit.field.rawValue,
        snippet: bounded(hit.snippet, maximumLength: Self.maximumOutputTextLength),
        updatedAt: hit.updatedAt
      )
    }
  }

  private func uniqueDrafts(from drafts: [ArticleDraft]) -> [ArticleDraft] {
    var byID: [UUID: ArticleDraft] = [:]
    byID.reserveCapacity(min(drafts.count, Self.maximumDraftCount))

    for draft in drafts {
      guard !Task.isCancelled else { return [] }
      if let current = byID[draft.id] {
        if prefers(draft, over: current) {
          byID[draft.id] = draft
        }
      } else {
        byID[draft.id] = draft
      }
    }

    // Sorting by identity makes results independent of the caller's array
    // order when a filtered source is assembled concurrently.
    return byID.values.sorted { lhs, rhs in
      lhs.id.uuidString < rhs.id.uuidString
    }
  }

  private func prefers(_ candidate: ArticleDraft, over current: ArticleDraft) -> Bool {
    if candidate.updatedAt != current.updatedAt {
      return candidate.updatedAt > current.updatedAt
    }
    let titleOrder = candidate.title.localizedStandardCompare(current.title)
    if titleOrder != .orderedSame {
      return titleOrder == .orderedAscending
    }
    return bounded(candidate.bodyMarkdown, maximumLength: Self.maximumIndexedTextLength)
      < bounded(current.bodyMarkdown, maximumLength: Self.maximumIndexedTextLength)
  }

  private func boundedDraft(_ draft: ArticleDraft) -> ArticleDraft {
    var copy = draft
    copy.title = bounded(draft.title, maximumLength: Self.maximumIndexedTextLength)
    copy.summary = bounded(draft.summary, maximumLength: Self.maximumIndexedTextLength)
    copy.bodyMarkdown = bounded(draft.bodyMarkdown, maximumLength: Self.maximumIndexedTextLength)
    copy.slug = bounded(draft.slug, maximumLength: Self.maximumIndexedTextLength)
    copy.tags = bounded(draft.tags)
    copy.categories = bounded(draft.categories)
    copy.authors = bounded(draft.authors)
    copy.repositoryPath = draft.repositoryPath.map {
      bounded($0, maximumLength: Self.maximumIndexedTextLength)
    }
    return copy
  }

  private func bounded(_ values: [String]) -> [String] {
    values.prefix(64).map {
      bounded($0, maximumLength: Self.maximumIndexedTextLength)
    }
  }

  private func bounded(_ value: String, maximumLength: Int) -> String {
    String(value.prefix(maximumLength))
  }
}

// MARK: - Content audit

public enum WorkbenchAgentContentAuditStatus: String, Codable, Hashable, Sendable {
  case error
  case warning
  case informational
}

public enum WorkbenchAgentRepairStatus: String, Codable, Hashable, Sendable {
  case notPerformed
}

public struct WorkbenchAgentContentAuditFinding: Codable, Equatable, Hashable, Sendable {
  public let severity: PreflightSeverity
  public let title: String
  public let message: String
  public let field: String?

  public init(
    severity: PreflightSeverity,
    title: String,
    message: String,
    field: String?
  ) {
    self.severity = severity
    self.title = title
    self.message = message
    self.field = field
  }
}

/// A truthful, bounded projection of ``SEOAuditReport`` for an Agent tool.
/// `repairStatus` is deliberately not inferred from the report: this service
/// never changes the draft and never claims to have fixed a finding.
public struct WorkbenchAgentContentAuditSummary: Codable, Equatable, Hashable, Sendable {
  public let draftID: UUID
  public let title: String
  public let status: WorkbenchAgentContentAuditStatus
  public let titleCharacterCount: Int
  public let summaryCharacterCount: Int
  public let bodyCharacterCount: Int
  public let h1Count: Int
  public let hasPublishableCoverImage: Bool
  public let markdownPath: String
  public let frontMatterPreview: String
  public let findings: [WorkbenchAgentContentAuditFinding]
  public let errorCount: Int
  public let warningCount: Int
  public let informationalCount: Int
  public let isPartial: Bool
  public let repairStatus: WorkbenchAgentRepairStatus
  public let observationNote: String

  public init(
    draftID: UUID,
    title: String,
    status: WorkbenchAgentContentAuditStatus,
    titleCharacterCount: Int,
    summaryCharacterCount: Int,
    bodyCharacterCount: Int,
    h1Count: Int,
    hasPublishableCoverImage: Bool,
    markdownPath: String,
    frontMatterPreview: String,
    findings: [WorkbenchAgentContentAuditFinding],
    errorCount: Int,
    warningCount: Int,
    informationalCount: Int,
    isPartial: Bool,
    repairStatus: WorkbenchAgentRepairStatus = .notPerformed,
    observationNote: String = "仅检查当前本地文章快照，未执行修改或修复。"
  ) {
    self.draftID = draftID
    self.title = title
    self.status = status
    self.titleCharacterCount = titleCharacterCount
    self.summaryCharacterCount = summaryCharacterCount
    self.bodyCharacterCount = bodyCharacterCount
    self.h1Count = h1Count
    self.hasPublishableCoverImage = hasPublishableCoverImage
    self.markdownPath = markdownPath
    self.frontMatterPreview = frontMatterPreview
    self.findings = findings
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.informationalCount = informationalCount
    self.isPartial = isPartial
    self.repairStatus = repairStatus
    self.observationNote = observationNote
  }
}

public struct WorkbenchAgentContentAuditService: Sendable {
  public static let maximumArticleTextLength = 32_000
  public static let maximumOutputTextLength = 1_200
  public static let maximumFindingCount = 24

  public init() {}

  /// Audits only the supplied in-memory draft and profile.  `nil` means the
  /// caller cancelled the observation before a complete snapshot was made.
  public func audit(
    draft: ArticleDraft,
    profile: SiteProfile
  ) -> WorkbenchAgentContentAuditSummary? {
    guard !Task.isCancelled else { return nil }
    let boundedDraftResult = boundedDraft(draft)
    let boundedProfile = boundedProfile(profile)
    guard !Task.isCancelled else { return nil }

    let report = SEOAuditService().report(
      draft: boundedDraftResult.value,
      profile: boundedProfile
    )
    guard !Task.isCancelled else { return nil }

    let findings = report.findings.prefix(Self.maximumFindingCount).map { finding in
      WorkbenchAgentContentAuditFinding(
        severity: finding.severity,
        title: bounded(finding.title, maximumLength: Self.maximumOutputTextLength),
        message: bounded(finding.message, maximumLength: Self.maximumOutputTextLength),
        field: finding.field.map {
          bounded($0, maximumLength: Self.maximumOutputTextLength)
        }
      )
    }
    let status: WorkbenchAgentContentAuditStatus
    if report.errorCount > 0 {
      status = .error
    } else if report.warningCount > 0 {
      status = .warning
    } else {
      status = .informational
    }

    return WorkbenchAgentContentAuditSummary(
      draftID: draft.id,
      title: bounded(draft.title, maximumLength: Self.maximumOutputTextLength),
      status: status,
      titleCharacterCount: report.titleCharacterCount,
      summaryCharacterCount: report.summaryCharacterCount,
      bodyCharacterCount: report.bodyCharacterCount,
      h1Count: report.h1Count,
      hasPublishableCoverImage: report.hasPublishableCoverImage,
      markdownPath: bounded(report.markdownPath, maximumLength: Self.maximumOutputTextLength),
      frontMatterPreview: bounded(
        report.frontMatterPreview,
        maximumLength: Self.maximumOutputTextLength
      ),
      findings: Array(findings),
      errorCount: report.errorCount,
      warningCount: report.warningCount,
      informationalCount: report.findings.filter { $0.severity == .info }.count,
      isPartial: boundedDraftResult.wasTruncated,
      repairStatus: .notPerformed
    )
  }

  private func boundedDraft(_ draft: ArticleDraft) -> (value: ArticleDraft, wasTruncated: Bool) {
    var copy = draft
    let title = boundedResult(draft.title, maximumLength: Self.maximumArticleTextLength)
    let summary = boundedResult(draft.summary, maximumLength: Self.maximumArticleTextLength)
    let body = boundedResult(draft.bodyMarkdown, maximumLength: Self.maximumArticleTextLength)
    copy.title = title.value
    copy.summary = summary.value
    copy.bodyMarkdown = body.value
    copy.slug = bounded(draft.slug, maximumLength: Self.maximumArticleTextLength)
    copy.tags = draft.tags.prefix(64).map {
      bounded($0, maximumLength: Self.maximumArticleTextLength)
    }
    copy.categories = draft.categories.prefix(64).map {
      bounded($0, maximumLength: Self.maximumArticleTextLength)
    }
    copy.authors = draft.authors.prefix(64).map {
      bounded($0, maximumLength: Self.maximumArticleTextLength)
    }
    return (copy, title.wasTruncated || summary.wasTruncated || body.wasTruncated)
  }

  private func boundedProfile(_ profile: SiteProfile) -> SiteProfile {
    var copy = profile
    copy.name = bounded(profile.name, maximumLength: Self.maximumArticleTextLength)
    copy.repositoryBaseURL = bounded(
      profile.repositoryBaseURL, maximumLength: Self.maximumArticleTextLength)
    copy.localRepositoryRootPath = bounded(
      profile.localRepositoryRootPath,
      maximumLength: Self.maximumArticleTextLength
    )
    copy.repoOwner = bounded(profile.repoOwner, maximumLength: Self.maximumArticleTextLength)
    copy.repoName = bounded(profile.repoName, maximumLength: Self.maximumArticleTextLength)
    copy.branch = bounded(profile.branch, maximumLength: Self.maximumArticleTextLength)
    copy.contentRoot = bounded(profile.contentRoot, maximumLength: Self.maximumArticleTextLength)
    copy.assetRoot = bounded(profile.assetRoot, maximumLength: Self.maximumArticleTextLength)
    copy.markdownPathPattern = bounded(
      profile.markdownPathPattern,
      maximumLength: Self.maximumArticleTextLength
    )
    copy.imagePathPattern = bounded(
      profile.imagePathPattern, maximumLength: Self.maximumArticleTextLength)
    copy.publicImagePathPattern = bounded(
      profile.publicImagePathPattern,
      maximumLength: Self.maximumArticleTextLength
    )
    copy.defaultAuthor = bounded(
      profile.defaultAuthor, maximumLength: Self.maximumArticleTextLength)
    copy.defaultTags = profile.defaultTags.prefix(64).map {
      bounded($0, maximumLength: Self.maximumArticleTextLength)
    }
    copy.defaultCategories = profile.defaultCategories.prefix(64).map {
      bounded($0, maximumLength: Self.maximumArticleTextLength)
    }
    return copy
  }

  private func boundedResult(_ value: String, maximumLength: Int) -> (
    value: String, wasTruncated: Bool
  ) {
    let limitedEnd =
      value.index(
        value.startIndex,
        offsetBy: maximumLength,
        limitedBy: value.endIndex
      ) ?? value.endIndex
    guard limitedEnd != value.endIndex else { return (value, false) }
    return (String(value[..<limitedEnd]), true)
  }

  private func bounded(_ value: String, maximumLength: Int) -> String {
    String(value.prefix(maximumLength))
  }
}

// MARK: - Static Markdown links

public enum WorkbenchAgentStaticLinkKind: String, Codable, Hashable, Sendable {
  case link
  case image
}

public enum WorkbenchAgentStaticLinkDiagnosticKind: String, Codable, Hashable, Sendable {
  case emptyLabel
  case emptyDestination
  case unclosedLabel
  case unclosedDestination
}

public struct WorkbenchAgentStaticLinkReference: Codable, Equatable, Hashable, Identifiable,
  Sendable
{
  public var id: String {
    "\(kind.rawValue):\(sourceOffset)"
  }

  public let kind: WorkbenchAgentStaticLinkKind
  public let label: String
  public let destination: String
  /// Character offset in the bounded Markdown input, not a byte or UTF-16 offset.
  public let sourceOffset: Int

  public init(
    kind: WorkbenchAgentStaticLinkKind,
    label: String,
    destination: String,
    sourceOffset: Int
  ) {
    self.kind = kind
    self.label = label
    self.destination = destination
    self.sourceOffset = sourceOffset
  }
}

public struct WorkbenchAgentStaticLinkDiagnostic: Codable, Equatable, Hashable, Identifiable,
  Sendable
{
  public var id: String {
    "\(kind.rawValue):\(sourceOffset)"
  }

  public let kind: WorkbenchAgentStaticLinkDiagnosticKind
  public let message: String
  public let sourceOffset: Int
  public let referenceKind: WorkbenchAgentStaticLinkKind

  public init(
    kind: WorkbenchAgentStaticLinkDiagnosticKind,
    message: String,
    sourceOffset: Int,
    referenceKind: WorkbenchAgentStaticLinkKind
  ) {
    self.kind = kind
    self.message = message
    self.sourceOffset = sourceOffset
    self.referenceKind = referenceKind
  }
}

public enum WorkbenchAgentLinkReachabilityStatus: String, Codable, Hashable, Sendable {
  case notVerified
}

public struct WorkbenchAgentStaticLinkInspection: Codable, Equatable, Hashable, Sendable {
  public let references: [WorkbenchAgentStaticLinkReference]
  public let diagnostics: [WorkbenchAgentStaticLinkDiagnostic]
  public let reachability: WorkbenchAgentLinkReachabilityStatus
  public let inputWasTruncated: Bool
  public let scannedCharacterCount: Int

  public init(
    references: [WorkbenchAgentStaticLinkReference],
    diagnostics: [WorkbenchAgentStaticLinkDiagnostic],
    reachability: WorkbenchAgentLinkReachabilityStatus = .notVerified,
    inputWasTruncated: Bool,
    scannedCharacterCount: Int
  ) {
    self.references = references
    self.diagnostics = diagnostics
    self.reachability = reachability
    self.inputWasTruncated = inputWasTruncated
    self.scannedCharacterCount = scannedCharacterCount
  }

  public var discoveredLinkCount: Int {
    references.filter { $0.kind == .link }.count
  }

  public var discoveredImageCount: Int {
    references.filter { $0.kind == .image }.count
  }

  public var formatDiagnosticCount: Int {
    diagnostics.count
  }

  public var networkWasVerified: Bool {
    false
  }
}

/// A Markdown syntax inspection that deliberately does not perform URL
/// requests.  It reports what was found and what is malformed, while its
/// reachability status remains `.notVerified`.
public struct WorkbenchAgentStaticLinkInspectionService: Sendable {
  public static let maximumInputLength = 64_000
  public static let maximumReferenceCount = 200
  public static let maximumDiagnosticCount = 200
  public static let maximumOutputTextLength = 1_200

  public init() {}

  public func inspect(markdown: String) -> WorkbenchAgentStaticLinkInspection? {
    guard !Task.isCancelled else { return nil }
    let boundedResult = boundedInput(markdown)
    let characters = Array(boundedResult.value)
    var parser = Parser(characters: characters)
    let parsed = parser.parse()
    guard !Task.isCancelled else { return nil }
    return WorkbenchAgentStaticLinkInspection(
      references: parsed.references,
      diagnostics: parsed.diagnostics,
      reachability: .notVerified,
      inputWasTruncated: boundedResult.wasTruncated,
      scannedCharacterCount: characters.count
    )
  }

  private func boundedInput(_ value: String) -> (value: String, wasTruncated: Bool) {
    let limitedEnd =
      value.index(
        value.startIndex,
        offsetBy: Self.maximumInputLength,
        limitedBy: value.endIndex
      ) ?? value.endIndex
    guard limitedEnd != value.endIndex else { return (value, false) }
    return (String(value[..<limitedEnd]), true)
  }

  private struct ParsedInspection {
    var references: [WorkbenchAgentStaticLinkReference] = []
    var diagnostics: [WorkbenchAgentStaticLinkDiagnostic] = []
  }

  private struct ParsedDestination {
    var destination: String
    var closingIndex: Int?
    var hadContent: Bool
  }

  private struct Parser {
    let characters: [Character]

    mutating func parse() -> ParsedInspection {
      var result = ParsedInspection()
      var index = 0
      var insideFence = false
      var isLineStart = true

      while index < characters.count {
        if index.isMultiple(of: 256), Task.isCancelled {
          return ParsedInspection()
        }

        if isLineStart, isFenceStart(at: index) {
          insideFence.toggle()
          while index < characters.count, characters[index] != "\n" {
            index += 1
          }
          isLineStart = true
          continue
        }

        if insideFence {
          isLineStart = characters[index] == "\n"
          index += 1
          continue
        }

        if characters[index] == "<",
          let end = closingAngleBracket(from: index + 1),
          end > index + 1
        {
          let value = String(characters[(index + 1)..<end])
          if isAutolink(value),
            result.references.count
              < WorkbenchAgentStaticLinkInspectionService.maximumReferenceCount
          {
            result.references.append(
              WorkbenchAgentStaticLinkReference(
                kind: .link,
                label: value,
                destination: value,
                sourceOffset: index
              )
            )
          }
          index = end + 1
          isLineStart = false
          continue
        }

        let isImage =
          characters[index] == "!"
          && index + 1 < characters.count
          && characters[index + 1] == "["
        let isLink = characters[index] == "["
        guard isImage || isLink else {
          isLineStart = characters[index] == "\n"
          index += 1
          continue
        }

        let kind: WorkbenchAgentStaticLinkKind = isImage ? .image : .link
        let openingBracket = isImage ? index + 1 : index
        guard let labelEnd = closingBracket(from: openingBracket + 1) else {
          appendDiagnostic(
            .init(
              kind: .unclosedLabel,
              message: "发现未闭合的 Markdown \(kind == .image ? "图片" : "链接")标签。",
              sourceOffset: index,
              referenceKind: kind
            ),
            to: &result.diagnostics
          )
          index = openingBracket + 1
          isLineStart = false
          continue
        }

        let label = String(characters[(openingBracket + 1)..<labelEnd])
        var afterLabel = labelEnd + 1
        if afterLabel < characters.count, characters[afterLabel] == "(" {
          let destinationResult = parseDestination(from: afterLabel + 1)
          let reference = WorkbenchAgentStaticLinkReference(
            kind: kind,
            label: bounded(label),
            destination: bounded(destinationResult.destination),
            sourceOffset: index
          )
          if result.references.count
            < WorkbenchAgentStaticLinkInspectionService.maximumReferenceCount
          {
            result.references.append(reference)
          }

          if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendDiagnostic(
              .init(
                kind: .emptyLabel,
                message: "Markdown \(kind == .image ? "图片" : "链接")标签文本为空。",
                sourceOffset: index,
                referenceKind: kind
              ),
              to: &result.diagnostics
            )
          }
          if !destinationResult.hadContent {
            appendDiagnostic(
              .init(
                kind: .emptyDestination,
                message: "Markdown \(kind == .image ? "图片" : "链接")目标为空。",
                sourceOffset: index,
                referenceKind: kind
              ),
              to: &result.diagnostics
            )
          }
          if let closingIndex = destinationResult.closingIndex {
            afterLabel = closingIndex + 1
          } else {
            appendDiagnostic(
              .init(
                kind: .unclosedDestination,
                message: "Markdown \(kind == .image ? "图片" : "链接")目标缺少右括号。",
                sourceOffset: index,
                referenceKind: kind
              ),
              to: &result.diagnostics
            )
            afterLabel = characters.count
          }
        } else if afterLabel < characters.count, characters[afterLabel] == "[",
          let referenceEnd = closingBracket(from: afterLabel + 1)
        {
          // Reference-style links are discovered without pretending that the
          // reference definition has been resolved.
          let referenceLabel = String(characters[(afterLabel + 1)..<referenceEnd])
          let reference = WorkbenchAgentStaticLinkReference(
            kind: kind,
            label: bounded(label),
            destination: bounded("[\(referenceLabel)]"),
            sourceOffset: index
          )
          if result.references.count
            < WorkbenchAgentStaticLinkInspectionService.maximumReferenceCount
          {
            result.references.append(reference)
          }
          afterLabel = referenceEnd + 1
        }

        index = max(index + 1, afterLabel)
        isLineStart = false
      }

      return result
    }

    private func isFenceStart(at index: Int) -> Bool {
      guard index + 2 < characters.count else { return false }
      return characters[index] == "`"
        && characters[index + 1] == "`"
        && characters[index + 2] == "`"
    }

    private func closingBracket(from start: Int) -> Int? {
      var depth = 0
      var index = start
      while index < characters.count {
        if characters[index] == "\\" {
          index += min(2, characters.count - index)
          continue
        }
        if characters[index] == "[" {
          depth += 1
        } else if characters[index] == "]" {
          if depth == 0 { return index }
          depth -= 1
        }
        index += 1
      }
      return nil
    }

    private func closingAngleBracket(from start: Int) -> Int? {
      characters[start...].firstIndex(of: ">")
    }

    private func isAutolink(_ value: String) -> Bool {
      let lowercased = value.lowercased()
      return lowercased.hasPrefix("http://")
        || lowercased.hasPrefix("https://")
        || lowercased.hasPrefix("mailto:")
        || lowercased.hasPrefix("tel:")
    }

    private mutating func parseDestination(from start: Int) -> ParsedDestination {
      guard start < characters.count else {
        return ParsedDestination(destination: "", closingIndex: nil, hadContent: false)
      }

      var cursor = start
      while cursor < characters.count, characters[cursor].isWhitespace {
        cursor += 1
      }
      guard cursor < characters.count else {
        return ParsedDestination(destination: "", closingIndex: nil, hadContent: false)
      }

      var nestedParentheses = 0
      var quote: Character?
      var closingIndex: Int?
      while cursor < characters.count {
        if cursor.isMultiple(of: 256), Task.isCancelled {
          return ParsedDestination(destination: "", closingIndex: nil, hadContent: false)
        }
        let character = characters[cursor]
        if character == "\\" {
          cursor += min(2, characters.count - cursor)
          continue
        }
        if let activeQuote = quote {
          if character == activeQuote { quote = nil }
          cursor += 1
          continue
        }
        if character == "\n", nestedParentheses == 0 {
          // A normal inline destination cannot continue onto the next
          // Markdown line.  Stop here so a later closing parenthesis cannot
          // accidentally make a malformed link look valid.
          break
        }
        if character == "\"" || character == "'" {
          quote = character
          cursor += 1
          continue
        }
        if character == "(" {
          nestedParentheses += 1
        } else if character == ")" {
          if nestedParentheses == 0 {
            closingIndex = cursor
            break
          }
          nestedParentheses -= 1
        }
        cursor += 1
      }

      let end = closingIndex ?? characters.count
      let rawDestination = String(characters[start..<end])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let destination = extractDestination(from: rawDestination)
      return ParsedDestination(
        destination: destination,
        closingIndex: closingIndex,
        hadContent: !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
    }

    private func extractDestination(from rawValue: String) -> String {
      guard !rawValue.isEmpty else { return "" }
      if rawValue.first == "<" {
        guard let closing = rawValue.firstIndex(of: ">") else {
          return String(rawValue.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(rawValue[rawValue.index(after: rawValue.startIndex)..<closing])
      }
      return rawValue.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    private func bounded(_ value: String) -> String {
      String(value.prefix(WorkbenchAgentStaticLinkInspectionService.maximumOutputTextLength))
    }

    private func appendDiagnostic(
      _ diagnostic: WorkbenchAgentStaticLinkDiagnostic,
      to diagnostics: inout [WorkbenchAgentStaticLinkDiagnostic]
    ) {
      guard diagnostics.count < WorkbenchAgentStaticLinkInspectionService.maximumDiagnosticCount
      else {
        return
      }
      diagnostics.append(diagnostic)
    }
  }
}

// MARK: - Image report formatter

public enum WorkbenchAgentImageReportAvailability: String, Codable, Hashable, Sendable {
  case available
  case unavailable
}

public struct WorkbenchAgentImageReportIssue: Codable, Equatable, Hashable, Sendable {
  public let severity: PreflightSeverity
  public let kind: ImageWorkbenchIssueKind
  public let title: String
  public let message: String
  public let attachmentID: UUID?

  public init(
    severity: PreflightSeverity,
    kind: ImageWorkbenchIssueKind,
    title: String,
    message: String,
    attachmentID: UUID?
  ) {
    self.severity = severity
    self.kind = kind
    self.title = title
    self.message = message
    self.attachmentID = attachmentID
  }
}

public struct WorkbenchAgentImageReportSummary: Codable, Equatable, Hashable, Sendable {
  public let availability: WorkbenchAgentImageReportAvailability
  public let draftID: UUID?
  public let generatedAt: Date?
  public let imageCount: Int
  public let issueCount: Int
  public let errorCount: Int
  public let warningCount: Int
  public let missingAltTextCount: Int
  public let missingCaptionCount: Int
  public let missingSourceCount: Int
  public let optimizableJPEGCount: Int
  public let webPConvertibleCount: Int
  public let optimizableSVGCount: Int
  public let resizableImageCount: Int
  public let duplicateImageCount: Int
  public let coverState: String?
  public let issues: [WorkbenchAgentImageReportIssue]
  public let omittedIssueCount: Int
  public let unavailableReason: String?
  public let repairStatus: WorkbenchAgentRepairStatus

  public init(
    availability: WorkbenchAgentImageReportAvailability,
    draftID: UUID?,
    generatedAt: Date?,
    imageCount: Int,
    issueCount: Int,
    errorCount: Int,
    warningCount: Int,
    missingAltTextCount: Int,
    missingCaptionCount: Int,
    missingSourceCount: Int,
    optimizableJPEGCount: Int,
    webPConvertibleCount: Int,
    optimizableSVGCount: Int,
    resizableImageCount: Int,
    duplicateImageCount: Int,
    coverState: String?,
    issues: [WorkbenchAgentImageReportIssue],
    omittedIssueCount: Int,
    unavailableReason: String?,
    repairStatus: WorkbenchAgentRepairStatus = .notPerformed
  ) {
    self.availability = availability
    self.draftID = draftID
    self.generatedAt = generatedAt
    self.imageCount = imageCount
    self.issueCount = issueCount
    self.errorCount = errorCount
    self.warningCount = warningCount
    self.missingAltTextCount = missingAltTextCount
    self.missingCaptionCount = missingCaptionCount
    self.missingSourceCount = missingSourceCount
    self.optimizableJPEGCount = optimizableJPEGCount
    self.webPConvertibleCount = webPConvertibleCount
    self.optimizableSVGCount = optimizableSVGCount
    self.resizableImageCount = resizableImageCount
    self.duplicateImageCount = duplicateImageCount
    self.coverState = coverState
    self.issues = issues
    self.omittedIssueCount = omittedIssueCount
    self.unavailableReason = unavailableReason
    self.repairStatus = repairStatus
  }
}

public struct WorkbenchAgentImageReportFormatter: Sendable {
  public static let maximumIssueCount = 20
  public static let maximumOutputTextLength = 1_200

  public init() {}

  public func summary(
    for report: ImageWorkbenchReport?,
    maximumIssues: Int = Self.maximumIssueCount
  ) -> WorkbenchAgentImageReportSummary {
    guard let report else {
      return WorkbenchAgentImageReportSummary(
        availability: .unavailable,
        draftID: nil,
        generatedAt: nil,
        imageCount: 0,
        issueCount: 0,
        errorCount: 0,
        warningCount: 0,
        missingAltTextCount: 0,
        missingCaptionCount: 0,
        missingSourceCount: 0,
        optimizableJPEGCount: 0,
        webPConvertibleCount: 0,
        optimizableSVGCount: 0,
        resizableImageCount: 0,
        duplicateImageCount: 0,
        coverState: nil,
        issues: [],
        omittedIssueCount: 0,
        unavailableReason: "当前没有真实的图片检查报告；未执行图片检查。"
      )
    }

    guard !Task.isCancelled else {
      return WorkbenchAgentImageReportSummary(
        availability: .unavailable,
        draftID: report.draftID,
        generatedAt: report.generatedAt,
        imageCount: 0,
        issueCount: 0,
        errorCount: 0,
        warningCount: 0,
        missingAltTextCount: 0,
        missingCaptionCount: 0,
        missingSourceCount: 0,
        optimizableJPEGCount: 0,
        webPConvertibleCount: 0,
        optimizableSVGCount: 0,
        resizableImageCount: 0,
        duplicateImageCount: 0,
        coverState: nil,
        issues: [],
        omittedIssueCount: 0,
        unavailableReason: "图片报告读取已取消；未返回部分结果。"
      )
    }

    let sortedIssues = report.issues.sorted { lhs, rhs in
      if lhs.severity.sortRank != rhs.severity.sortRank {
        return lhs.severity.sortRank < rhs.severity.sortRank
      }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      if lhs.message != rhs.message { return lhs.message < rhs.message }
      return (lhs.attachmentID?.uuidString ?? "") < (rhs.attachmentID?.uuidString ?? "")
    }
    let normalizedLimit = min(Self.maximumIssueCount, max(1, maximumIssues))
    let issues = sortedIssues.prefix(normalizedLimit).map {
      WorkbenchAgentImageReportIssue(
        severity: $0.severity,
        kind: $0.kind,
        title: bounded($0.title),
        message: bounded($0.message),
        attachmentID: $0.attachmentID
      )
    }

    return WorkbenchAgentImageReportSummary(
      availability: .available,
      draftID: report.draftID,
      generatedAt: report.generatedAt,
      imageCount: report.items.count,
      issueCount: report.issues.count,
      errorCount: report.issues.filter { $0.severity == .error }.count,
      warningCount: report.issues.filter { $0.severity == .warning }.count,
      missingAltTextCount: report.missingAltTextCount,
      missingCaptionCount: report.missingCaptionCount,
      missingSourceCount: report.missingSourceCount,
      optimizableJPEGCount: report.optimizableJPEGCount,
      webPConvertibleCount: report.webPConvertibleCount,
      optimizableSVGCount: report.optimizableSVGCount,
      resizableImageCount: report.resizableImageCount,
      duplicateImageCount: report.duplicateImageCount,
      coverState: report.coverStatus.state.rawValue,
      issues: Array(issues),
      omittedIssueCount: max(0, report.issues.count - issues.count),
      unavailableReason: nil
    )
  }

  public static func summary(
    for report: ImageWorkbenchReport?,
    maximumIssues: Int = Self.maximumIssueCount
  ) -> WorkbenchAgentImageReportSummary {
    WorkbenchAgentImageReportFormatter().summary(
      for: report,
      maximumIssues: maximumIssues
    )
  }

  private func bounded(_ value: String) -> String {
    String(value.prefix(Self.maximumOutputTextLength))
  }
}
