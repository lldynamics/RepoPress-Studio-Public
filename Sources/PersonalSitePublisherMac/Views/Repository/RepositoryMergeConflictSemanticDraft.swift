import PublishingGitCore
import PublishingMarkdownCore

enum RepositoryMergeConflictSemanticMode: String, Hashable, Sendable {
  case semantic
  case source
}

enum RepositoryMergeConflictSemanticUnavailableReason: Equatable, Sendable {
  case nonMarkdown
  case missingTextVersion
  case unsupported(MarkdownThreeWayMergeUnsupportedReason)
}

/// Immutable input identity for an in-memory conflict draft. A matching path
/// alone is insufficient: stages and every displayed side must still match.
struct RepositoryMergeConflictSemanticSnapshot: Equatable, Sendable {
  let conflict: RepositoryMergeConflict
}

/// Local-only state for the repository conflict surface. It deliberately has
/// no reference to the resolver action; picking a result cannot write or stage.
struct RepositoryMergeConflictSemanticDraft: Sendable {
  let snapshot: RepositoryMergeConflictSemanticSnapshot
  private(set) var mode: RepositoryMergeConflictSemanticMode
  let semanticPlan: MarkdownThreeWayMergePlan?
  let semanticUnavailableReason: RepositoryMergeConflictSemanticUnavailableReason?
  private(set) var frontMatterChoices: [String: MarkdownThreeWayMergeFieldChoice] = [:]
  private(set) var bodyChoices: [Int: MarkdownThreeWayMergeBodyChoice] = [:]
  private(set) var sourceDraft: String
  private(set) var sourceReviewed = false
  private(set) var isDeletionSelected = false

  init(conflict: RepositoryMergeConflict) {
    snapshot = RepositoryMergeConflictSemanticSnapshot(conflict: conflict)
    sourceDraft = RepositoryMergeConflictDraftPolicy.initialText(for: conflict)

    guard Self.isMarkdownPath(conflict.repositoryPath) else {
      mode = .source
      semanticPlan = nil
      semanticUnavailableReason = .nonMarkdown
      return
    }
    guard conflict.canResolve,
      let base = conflict.base.text, let ours = conflict.ours.text,
      let theirs = conflict.theirs.text,
      conflict.base.isText, conflict.ours.isText, conflict.theirs.isText
    else {
      mode = .source
      semanticPlan = nil
      semanticUnavailableReason = .missingTextVersion
      return
    }

    switch MarkdownThreeWayMergeService().analyze(base: base, local: ours, remote: theirs) {
    case .ready(let plan):
      mode = .semantic
      semanticPlan = plan
      semanticUnavailableReason = nil
    case .unsupported(let reason):
      mode = .source
      semanticPlan = nil
      semanticUnavailableReason = .unsupported(reason)
    }
  }

  var canUseSemanticMode: Bool { semanticPlan != nil }

  var unresolvedFrontMatterCount: Int {
    semanticPlan?.frontMatterConflicts.reduce(into: 0) { count, conflict in
      if frontMatterChoices[conflict.id] == nil { count += 1 }
    } ?? 0
  }

  var unresolvedBodyCount: Int {
    semanticPlan?.bodyConflicts.reduce(into: 0) { count, conflict in
      if bodyChoices[conflict.id] == nil { count += 1 }
    } ?? 0
  }

  var unresolvedSemanticCount: Int { unresolvedFrontMatterCount + unresolvedBodyCount }

  /// The merge service returns nil until every surfaced choice is explicit.
  var semanticResolvedDocument: String? {
    semanticPlan?.resolvedDocument(
      frontMatterChoices: frontMatterChoices,
      bodyChoices: bodyChoices
    )
  }

  /// The only document that the parent view may pass to `resolveAction`.
  var resolvedDocument: String? {
    guard snapshot.conflict.canResolve else { return nil }
    switch mode {
    case .semantic:
      return semanticResolvedDocument
    case .source:
      return sourceReviewed ? sourceDraft : nil
    }
  }

  var resolutionRequest: RepositoryMergeConflictResolutionRequest? {
    guard let expectation = snapshot.conflict.resolutionExpectation else { return nil }
    if isDeletionSelected {
      guard snapshot.conflict.canResolveByDeleting else { return nil }
      return RepositoryMergeConflictResolutionRequest(
        expectation: expectation,
        resolution: .delete
      )
    }
    guard let resolvedDocument,
      !RepositoryMergeConflictPolicy.containsConflictMarkers(resolvedDocument)
    else {
      return nil
    }
    return RepositoryMergeConflictResolutionRequest(
      expectation: expectation,
      resolution: .finalText(resolvedDocument)
    )
  }

  var canApply: Bool { resolutionRequest != nil }

  func matches(_ conflict: RepositoryMergeConflict) -> Bool {
    snapshot == RepositoryMergeConflictSemanticSnapshot(conflict: conflict)
  }

  mutating func selectMode(_ requestedMode: RepositoryMergeConflictSemanticMode) {
    guard requestedMode != .semantic || canUseSemanticMode else { return }
    isDeletionSelected = false
    mode = requestedMode
  }

  mutating func selectFrontMatterChoice(
    _ choice: MarkdownThreeWayMergeFieldChoice,
    conflictID: String
  ) {
    guard semanticPlan?.frontMatterConflicts.contains(where: { $0.id == conflictID }) == true
    else { return }
    isDeletionSelected = false
    frontMatterChoices[conflictID] = choice
  }

  mutating func selectBodyChoice(
    _ choice: MarkdownThreeWayMergeBodyChoice,
    conflictID: Int
  ) {
    guard semanticPlan?.bodyConflicts.contains(where: { $0.id == conflictID }) == true
    else { return }
    isDeletionSelected = false
    bodyChoices[conflictID] = choice
  }

  mutating func updateSourceDraft(_ text: String) {
    guard mode == .source else { return }
    isDeletionSelected = false
    sourceDraft = text
    sourceReviewed = true
  }

  mutating func confirmSourceDraft() {
    guard mode == .source else { return }
    isDeletionSelected = false
    sourceReviewed = true
  }

  mutating func copySemanticResultToSource() {
    guard let semanticResolvedDocument else { return }
    isDeletionSelected = false
    sourceDraft = semanticResolvedDocument
    sourceReviewed = true
    mode = .source
  }

  mutating func prepareQuickChoice(_ choice: RepositoryMergeConflictDraftChoice) {
    guard snapshot.conflict.canResolve,
      let text = RepositoryMergeConflictDraftPolicy.preparedText(
        for: choice,
        conflict: snapshot.conflict
      )
    else { return }
    isDeletionSelected = false
    sourceDraft = text
    sourceReviewed = true
    mode = .source
  }

  mutating func selectDeletion() {
    guard snapshot.conflict.canResolveByDeleting,
      snapshot.conflict.resolutionExpectation != nil
    else { return }
    isDeletionSelected = true
  }

  private static func isMarkdownPath(_ path: String) -> Bool {
    let lowercased = path.lowercased()
    return lowercased.hasSuffix(".md")
      || lowercased.hasSuffix(".markdown")
      || lowercased.hasSuffix(".mdx")
  }
}
