import CryptoKit
import Foundation

public struct MarkdownBatchReplaceDocument: Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var markdown: String

  public init(id: UUID, title: String, markdown: String) {
    self.id = id
    self.title = title
    self.markdown = markdown
  }
}

public struct MarkdownBatchReplaceOriginalSnapshot: Equatable, Sendable {
  public var documentID: UUID
  public var title: String
  public var markdown: String
  public var contentDigest: String

  public init(documentID: UUID, title: String, markdown: String) {
    self.documentID = documentID
    self.title = title
    self.markdown = markdown
    contentDigest = Self.digest(markdown)
  }

  public func matches(_ currentMarkdown: String) -> Bool {
    contentDigest == Self.digest(currentMarkdown)
  }

  private static func digest(_ markdown: String) -> String {
    SHA256.hash(data: Data(markdown.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

public enum MarkdownBatchReplaceConflictReason: Equatable, Sendable {
  case duplicateDocumentIdentifier
  case duplicateBaselineSnapshot
  case sourceChangedSincePreview
}

public enum MarkdownBatchReplaceItemStatus: Equatable, Sendable {
  case ready
  case noMatches
  case noChange
  case conflict(MarkdownBatchReplaceConflictReason)
}

public struct MarkdownBatchReplacePreview: Equatable, Sendable {
  public var documentID: UUID
  public var title: String
  public var status: MarkdownBatchReplaceItemStatus
  public var matchRanges: [NSRange]
  public var originalSnapshot: MarkdownBatchReplaceOriginalSnapshot
  public var proposedMarkdown: String
  public var edit: MarkdownSmartEdit?

  public init(
    documentID: UUID,
    title: String,
    status: MarkdownBatchReplaceItemStatus,
    matchRanges: [NSRange],
    originalSnapshot: MarkdownBatchReplaceOriginalSnapshot,
    proposedMarkdown: String,
    edit: MarkdownSmartEdit?
  ) {
    self.documentID = documentID
    self.title = title
    self.status = status
    self.matchRanges = matchRanges
    self.originalSnapshot = originalSnapshot
    self.proposedMarkdown = proposedMarkdown
    self.edit = edit
  }

  public var matchCount: Int {
    matchRanges.count
  }

  public var canApply: Bool {
    status == .ready
  }
}

public struct MarkdownBatchReplacePlan: Equatable, Sendable {
  public var query: String
  public var replacement: String
  public var options: MarkdownFindOptions
  public var previews: [MarkdownBatchReplacePreview]

  public init(
    query: String,
    replacement: String,
    options: MarkdownFindOptions,
    previews: [MarkdownBatchReplacePreview]
  ) {
    self.query = query
    self.replacement = replacement
    self.options = options
    self.previews = previews
  }

  public var applicablePreviews: [MarkdownBatchReplacePreview] {
    previews.filter(\.canApply)
  }

  public var totalMatchCount: Int {
    applicablePreviews.reduce(0) { $0 + $1.matchCount }
  }

  public var hasConflicts: Bool {
    previews.contains { preview in
      if case .conflict = preview.status { return true }
      return false
    }
  }
}

public enum MarkdownBatchRollbackConflictReason: Equatable, Sendable {
  case duplicateCurrentDocumentIdentifier
  case documentMissing
  case documentChangedAfterReplacement
}

public enum MarkdownBatchRollbackItemStatus: Equatable, Sendable {
  case ready
  case alreadyRestored
  case conflict(MarkdownBatchRollbackConflictReason)
}

public struct MarkdownBatchRollbackPreview: Equatable, Sendable {
  public var documentID: UUID
  public var title: String
  public var status: MarkdownBatchRollbackItemStatus
  public var currentMarkdown: String?
  public var restoredMarkdown: String
  public var edit: MarkdownSmartEdit?

  public init(
    documentID: UUID,
    title: String,
    status: MarkdownBatchRollbackItemStatus,
    currentMarkdown: String?,
    restoredMarkdown: String,
    edit: MarkdownSmartEdit?
  ) {
    self.documentID = documentID
    self.title = title
    self.status = status
    self.currentMarkdown = currentMarkdown
    self.restoredMarkdown = restoredMarkdown
    self.edit = edit
  }

  public var canApply: Bool {
    status == .ready
  }
}

public struct MarkdownBatchRollbackPlan: Equatable, Sendable {
  public var previews: [MarkdownBatchRollbackPreview]

  public init(previews: [MarkdownBatchRollbackPreview]) {
    self.previews = previews
  }

  public var applicablePreviews: [MarkdownBatchRollbackPreview] {
    previews.filter(\.canApply)
  }

  public var hasConflicts: Bool {
    previews.contains { preview in
      if case .conflict = preview.status { return true }
      return false
    }
  }
}

/// Builds conflict-aware batch replacement and rollback plans without mutating documents.
public struct MarkdownBatchFindReplacePlanningService: Sendable {
  private let findReplaceService: MarkdownFindReplaceService

  public init(findReplaceService: MarkdownFindReplaceService = MarkdownFindReplaceService()) {
    self.findReplaceService = findReplaceService
  }

  public func plan(
    documents: [MarkdownBatchReplaceDocument],
    query: String,
    replacement: String,
    options: MarkdownFindOptions = MarkdownFindOptions(),
    expectedOriginals: [MarkdownBatchReplaceOriginalSnapshot] = [],
    cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
  ) throws -> MarkdownBatchReplacePlan {
    try cancellationCheck()
    let documentCounts = occurrenceCounts(documents.map(\.id))
    let expectedCounts = occurrenceCounts(expectedOriginals.map(\.documentID))
    let expectedByID: [UUID: MarkdownBatchReplaceOriginalSnapshot] =
      expectedOriginals.reduce(into: [:]) { partialResult, snapshot in
        if partialResult[snapshot.documentID] == nil {
          partialResult[snapshot.documentID] = snapshot
        }
      }

    let previews = try documents.map { document in
      try cancellationCheck()
      let snapshot = MarkdownBatchReplaceOriginalSnapshot(
        documentID: document.id,
        title: document.title,
        markdown: document.markdown
      )

      if documentCounts[document.id, default: 0] > 1 {
        return conflictPreview(
          document: document,
          snapshot: snapshot,
          reason: .duplicateDocumentIdentifier
        )
      }
      if expectedCounts[document.id, default: 0] > 1 {
        return conflictPreview(
          document: document,
          snapshot: snapshot,
          reason: .duplicateBaselineSnapshot
        )
      }
      if let expected = expectedByID[document.id],
        !expected.matches(document.markdown)
      {
        return conflictPreview(
          document: document,
          snapshot: snapshot,
          reason: .sourceChangedSincePreview
        )
      }

      let matches = try findReplaceService.matches(
        in: document.markdown,
        query: query,
        options: options
      )
      try cancellationCheck()
      guard !matches.isEmpty else {
        return MarkdownBatchReplacePreview(
          documentID: document.id,
          title: document.title,
          status: .noMatches,
          matchRanges: [],
          originalSnapshot: snapshot,
          proposedMarkdown: document.markdown,
          edit: nil
        )
      }

      let mutation = try findReplaceService.replaceAll(
        in: document.markdown,
        query: query,
        replacement: replacement,
        options: options
      )
      try cancellationCheck()
      guard mutation.text != document.markdown else {
        return MarkdownBatchReplacePreview(
          documentID: document.id,
          title: document.title,
          status: .noChange,
          matchRanges: matches,
          originalSnapshot: snapshot,
          proposedMarkdown: document.markdown,
          edit: nil
        )
      }

      return MarkdownBatchReplacePreview(
        documentID: document.id,
        title: document.title,
        status: .ready,
        matchRanges: matches,
        originalSnapshot: snapshot,
        proposedMarkdown: mutation.text,
        edit: mutation.edit
      )
    }

    return MarkdownBatchReplacePlan(
      query: query,
      replacement: replacement,
      options: options,
      previews: previews
    )
  }

  public func rollbackPlan(
    currentDocuments: [MarkdownBatchReplaceDocument],
    appliedPlan: MarkdownBatchReplacePlan
  ) -> MarkdownBatchRollbackPlan {
    let counts = occurrenceCounts(currentDocuments.map(\.id))
    let currentByID: [UUID: MarkdownBatchReplaceDocument] =
      currentDocuments.reduce(into: [:]) { partialResult, document in
        if partialResult[document.id] == nil {
          partialResult[document.id] = document
        }
      }

    let previews = appliedPlan.applicablePreviews.map { applied in
      guard counts[applied.documentID, default: 0] <= 1 else {
        return rollbackConflictPreview(
          applied: applied,
          currentMarkdown: currentByID[applied.documentID]?.markdown,
          reason: .duplicateCurrentDocumentIdentifier
        )
      }
      guard let current = currentByID[applied.documentID] else {
        return rollbackConflictPreview(
          applied: applied,
          currentMarkdown: nil,
          reason: .documentMissing
        )
      }
      if applied.originalSnapshot.matches(current.markdown) {
        return MarkdownBatchRollbackPreview(
          documentID: applied.documentID,
          title: applied.title,
          status: .alreadyRestored,
          currentMarkdown: current.markdown,
          restoredMarkdown: applied.originalSnapshot.markdown,
          edit: nil
        )
      }
      guard current.markdown == applied.proposedMarkdown else {
        return rollbackConflictPreview(
          applied: applied,
          currentMarkdown: current.markdown,
          reason: .documentChangedAfterReplacement
        )
      }

      let fullRange = NSRange(location: 0, length: (current.markdown as NSString).length)
      return MarkdownBatchRollbackPreview(
        documentID: applied.documentID,
        title: applied.title,
        status: .ready,
        currentMarkdown: current.markdown,
        restoredMarkdown: applied.originalSnapshot.markdown,
        edit: MarkdownSmartEdit(
          replacedRange: fullRange,
          replacement: applied.originalSnapshot.markdown,
          selectedRange: NSRange(location: 0, length: 0)
        )
      )
    }
    return MarkdownBatchRollbackPlan(previews: previews)
  }

  private func occurrenceCounts<Element: Hashable>(_ values: [Element]) -> [Element: Int] {
    values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }

  private func conflictPreview(
    document: MarkdownBatchReplaceDocument,
    snapshot: MarkdownBatchReplaceOriginalSnapshot,
    reason: MarkdownBatchReplaceConflictReason
  ) -> MarkdownBatchReplacePreview {
    MarkdownBatchReplacePreview(
      documentID: document.id,
      title: document.title,
      status: .conflict(reason),
      matchRanges: [],
      originalSnapshot: snapshot,
      proposedMarkdown: document.markdown,
      edit: nil
    )
  }

  private func rollbackConflictPreview(
    applied: MarkdownBatchReplacePreview,
    currentMarkdown: String?,
    reason: MarkdownBatchRollbackConflictReason
  ) -> MarkdownBatchRollbackPreview {
    MarkdownBatchRollbackPreview(
      documentID: applied.documentID,
      title: applied.title,
      status: .conflict(reason),
      currentMarkdown: currentMarkdown,
      restoredMarkdown: applied.originalSnapshot.markdown,
      edit: nil
    )
  }
}
