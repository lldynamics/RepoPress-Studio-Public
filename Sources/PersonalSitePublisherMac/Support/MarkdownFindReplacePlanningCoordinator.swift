import Combine
import Foundation
import PublishingMarkdownCore

/// Runs potentially expensive replacement planning away from the main actor.
/// The editor owns freshness checks because only it can decide whether a
/// completed plan still belongs to its draft, revision, query, and scope.
@MainActor
final class MarkdownFindReplacePlanningCoordinator: ObservableObject {
  typealias Planner = @Sendable (Request) -> Result
  enum Kind: Sendable {
    case current(selectedRange: NSRange)
    case all(draftID: UUID, bodyRevision: UInt64, scope: MarkdownFindScope)
  }

  struct Request: Sendable {
    let kind: Kind
    let body: String
    let scopeRange: NSRange
    let query: String
    let replacement: String
    let options: MarkdownFindOptions
  }

  enum Result: Sendable {
    case current(MarkdownFindReplaceScopedEdit?)
    case preview(MarkdownFindReplacePreview)
    case failure(String)
  }

  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private let planner: Planner
  @Published private(set) var isPending = false

  init(planner: @escaping Planner = { MarkdownFindReplacePlanningCoordinator.plan($0) }) {
    self.planner = planner
  }

  func schedule(
    _ request: Request,
    apply: @escaping @MainActor @Sendable (Result) -> Void
  ) {
    generation &+= 1
    let requestGeneration = generation
    task?.cancel()
    isPending = true
    let planner = self.planner
    task = Task.detached(priority: .userInitiated) { [weak self] in
      guard !Task.isCancelled else { return }
      let result = planner(request)
      guard !Task.isCancelled else { return }
      await self?.finish(result, generation: requestGeneration, apply: apply)
    }
  }

  func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    isPending = false
  }

  func waitUntilIdle() async {
    await task?.value
  }

  private func finish(
    _ result: Result,
    generation requestGeneration: UInt64,
    apply: @escaping @MainActor @Sendable (Result) -> Void
  ) {
    guard generation == requestGeneration else { return }
    task = nil
    isPending = false
    apply(result)
  }

  private nonisolated static func plan(_ request: Request) -> Result {
    do {
      let service = MarkdownFindReplaceService()
      switch request.kind {
      case .current(let selectedRange):
        return .current(
          try MarkdownFindReplaceScopePlanner.replaceCurrentOrNext(
            in: request.body, scopeRange: request.scopeRange, query: request.query,
            replacement: request.replacement, selectedRange: selectedRange,
            options: request.options, service: service
          ))
      case .all(let draftID, let bodyRevision, let scope):
        return .preview(
          try MarkdownFindReplaceScopePlanner.previewReplaceAll(
            in: request.body, draftID: draftID, bodyRevision: bodyRevision,
            scope: scope, scopeRange: request.scopeRange, query: request.query,
            replacement: request.replacement, options: request.options, service: service
          ))
      }
    } catch {
      return .failure(error.localizedDescription)
    }
  }

}
