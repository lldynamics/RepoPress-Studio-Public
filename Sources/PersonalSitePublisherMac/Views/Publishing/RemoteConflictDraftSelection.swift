import PublishingMarkdownCore
import PublishingWorkbenchCore

enum RemoteConflictMergeMode: String, Hashable, Sendable {
  case semantic
  case source
}

enum RemoteConflictSemanticMergeUnavailableReason: Equatable, Sendable {
  case missingTextVersion
  case unsupported(MarkdownThreeWayMergeUnsupportedReason)
}

struct RemoteConflictMergeDraft {
  private(set) var mode: RemoteConflictMergeMode
  let semanticPlan: MarkdownThreeWayMergePlan?
  let semanticUnavailableReason: RemoteConflictSemanticMergeUnavailableReason?
  private(set) var frontMatterChoices: [String: MarkdownThreeWayMergeFieldChoice] = [:]
  private(set) var bodyChoices: [Int: MarkdownThreeWayMergeBodyChoice] = [:]
  private(set) var sourceDraft: String
  private(set) var sourceReviewed = false

  init(base: String?, local: String?, remote: String?) {
    sourceDraft = local ?? ""
    guard let base, let local, let remote else {
      mode = .source
      semanticPlan = nil
      semanticUnavailableReason = .missingTextVersion
      return
    }
    switch MarkdownThreeWayMergeService().analyze(base: base, local: local, remote: remote) {
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

  var unresolvedSemanticCount: Int {
    unresolvedFrontMatterCount + unresolvedBodyCount
  }

  var semanticResolvedDocument: String? {
    semanticPlan?.resolvedDocument(
      frontMatterChoices: frontMatterChoices,
      bodyChoices: bodyChoices
    )
  }

  var resolvedDocument: String? {
    switch mode {
    case .semantic:
      return semanticResolvedDocument
    case .source:
      return sourceReviewed ? sourceDraft : nil
    }
  }

  mutating func selectMode(_ requestedMode: RemoteConflictMergeMode) {
    guard requestedMode != .semantic || canUseSemanticMode else { return }
    mode = requestedMode
  }

  mutating func selectFrontMatterChoice(
    _ choice: MarkdownThreeWayMergeFieldChoice,
    conflictID: String
  ) {
    guard semanticPlan?.frontMatterConflicts.contains(where: { $0.id == conflictID }) == true
    else { return }
    frontMatterChoices[conflictID] = choice
  }

  mutating func selectBodyChoice(
    _ choice: MarkdownThreeWayMergeBodyChoice,
    conflictID: Int
  ) {
    guard semanticPlan?.bodyConflicts.contains(where: { $0.id == conflictID }) == true
    else { return }
    bodyChoices[conflictID] = choice
  }

  mutating func updateSourceDraft(_ text: String) {
    guard mode == .source else { return }
    sourceDraft = text
    sourceReviewed = true
  }

  mutating func confirmSourceDraft() {
    guard mode == .source else { return }
    sourceReviewed = true
  }

  mutating func copySemanticResultToSource() {
    guard let semanticResolvedDocument else { return }
    sourceDraft = semanticResolvedDocument
    sourceReviewed = true
    mode = .source
  }
}

struct RemoteConflictDraftSelection {
  private(set) var choices: [String: RemoteRepositoryConflictResolutionChoice] = [:]
  private(set) var mergeStates: [String: RemoteConflictMergeDraft] = [:]

  mutating func select(
    path: String,
    choice: RemoteRepositoryConflictResolutionChoice,
    base: String? = nil,
    local: String?,
    remote: String?
  ) {
    choices[path] = choice
    guard choice == .merge, mergeStates[path] == nil else { return }
    mergeStates[path] = RemoteConflictMergeDraft(base: base, local: local, remote: remote)
  }

  func choice(for path: String) -> RemoteRepositoryConflictResolutionChoice? {
    choices[path]
  }

  func mergeDraft(for path: String) -> String {
    guard let state = mergeStates[path] else { return "" }
    return state.resolvedDocument ?? state.sourceDraft
  }

  func mergeState(for path: String) -> RemoteConflictMergeDraft? {
    mergeStates[path]
  }

  func displayedDocument(for path: String, local: String?, remote: String?) -> String {
    switch choices[path] {
    case .useRemote: return remote ?? ""
    case .merge: return mergeDraft(for: path)
    case .keepLocal, nil: return local ?? ""
    }
  }

  mutating func updateMergeDraft(_ text: String, for path: String) {
    guard choices[path] == .merge, var state = mergeStates[path] else { return }
    state.updateSourceDraft(text)
    mergeStates[path] = state
  }

  mutating func selectMergeMode(_ mode: RemoteConflictMergeMode, for path: String) {
    guard choices[path] == .merge, var state = mergeStates[path] else { return }
    state.selectMode(mode)
    mergeStates[path] = state
  }

  mutating func selectFrontMatterChoice(
    _ choice: MarkdownThreeWayMergeFieldChoice,
    conflictID: String,
    path: String
  ) {
    guard choices[path] == .merge, var state = mergeStates[path] else { return }
    state.selectFrontMatterChoice(choice, conflictID: conflictID)
    mergeStates[path] = state
  }

  mutating func selectBodyChoice(
    _ choice: MarkdownThreeWayMergeBodyChoice,
    conflictID: Int,
    path: String
  ) {
    guard choices[path] == .merge, var state = mergeStates[path] else { return }
    state.selectBodyChoice(choice, conflictID: conflictID)
    mergeStates[path] = state
  }

  mutating func copySemanticResultToSource(for path: String) {
    guard choices[path] == .merge, var state = mergeStates[path] else { return }
    state.copySemanticResultToSource()
    mergeStates[path] = state
  }

  mutating func confirmSourceDraft(for path: String) {
    guard choices[path] == .merge, var state = mergeStates[path] else { return }
    state.confirmSourceDraft()
    mergeStates[path] = state
  }

  func isResolved(_ item: RemoteRepositoryConflictItem) -> Bool {
    guard let choice = choices[item.repositoryPath] else { return false }
    let decision = RemoteRepositoryConflictResolutionDecision(
      repositoryPath: item.repositoryPath,
      choice: choice,
      mergedDocument: choice == .merge ? mergeStates[item.repositoryPath]?.resolvedDocument : nil
    )
    return decision.isValid(for: item)
  }

  func resolvedCount(in session: RemoteRepositoryConflictSession) -> Int {
    session.conflicts.reduce(into: 0) { count, item in
      if isResolved(item) {
        count += 1
      }
    }
  }

  func unresolvedPaths(in session: RemoteRepositoryConflictSession) -> [String] {
    session.conflicts.compactMap { item in
      choices[item.repositoryPath] == nil ? item.repositoryPath : nil
    }
  }

  func invalidPaths(in session: RemoteRepositoryConflictSession) -> [String] {
    session.conflicts.compactMap { item in
      guard let choice = choices[item.repositoryPath] else { return nil }
      let decision = RemoteRepositoryConflictResolutionDecision(
        repositoryPath: item.repositoryPath,
        choice: choice,
        mergedDocument: choice == .merge ? mergeStates[item.repositoryPath]?.resolvedDocument : nil
      )
      return decision.isValid(for: item) ? nil : item.repositoryPath
    }
  }

  func resolutionPlan(
    for session: RemoteRepositoryConflictSession
  ) -> RemoteRepositoryConflictResolutionPlan? {
    let decisions = session.conflicts.compactMap {
      item -> RemoteRepositoryConflictResolutionDecision? in
      guard let choice = choices[item.repositoryPath] else { return nil }
      return RemoteRepositoryConflictResolutionDecision(
        repositoryPath: item.repositoryPath,
        choice: choice,
        mergedDocument: choice == .merge ? mergeStates[item.repositoryPath]?.resolvedDocument : nil
      )
    }
    let plan = RemoteRepositoryConflictResolutionPlan(
      sessionID: session.id,
      decisions: decisions
    )
    return plan.isComplete(for: session) ? plan : nil
  }
}
