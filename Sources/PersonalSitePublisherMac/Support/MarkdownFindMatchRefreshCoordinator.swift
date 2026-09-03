import Combine
import Foundation
import PublishingMarkdownCore

struct MarkdownFindMatchRefreshResult: Equatable, Sendable {
  let ranges: [NSRange]
  let errorMessage: String?

  static let empty = MarkdownFindMatchRefreshResult(ranges: [], errorMessage: nil)
}

@MainActor
final class MarkdownFindMatchRefreshCoordinator: ObservableObject {
  typealias Scanner = @Sendable (
    _ text: String,
    _ query: String,
    _ options: MarkdownFindOptions
  ) -> MarkdownFindMatchRefreshResult?

  private struct Request: Sendable {
    let text: String
    let query: String
    let options: MarkdownFindOptions
  }

  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private let debounce: Duration
  private let scanner: Scanner

  @Published private(set) var isPending = false

  init(
    debounce: Duration = .milliseconds(120),
    scanner: @escaping Scanner = MarkdownFindMatchRefreshCoordinator.compute
  ) {
    self.debounce = debounce
    self.scanner = scanner
  }

  func schedule(
    text: String,
    query: String,
    options: MarkdownFindOptions,
    apply: @escaping @MainActor @Sendable (MarkdownFindMatchRefreshResult) -> Void
  ) {
    generation &+= 1
    let requestGeneration = generation
    task?.cancel()
    task = nil

    guard !query.isEmpty else {
      isPending = false
      apply(.empty)
      return
    }

    isPending = true
    let request = Request(text: text, query: query, options: options)
    let debounce = self.debounce
    let scanner = self.scanner
    task = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        try await Task.sleep(for: debounce)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }

      guard let result = scanner(request.text, request.query, request.options) else { return }
      guard !Task.isCancelled else { return }
      await self?.finish(
        result,
        generation: requestGeneration,
        apply: apply
      )
    }
  }

  func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    isPending = false
  }

  private func finish(
    _ result: MarkdownFindMatchRefreshResult,
    generation requestGeneration: UInt64,
    apply: @escaping @MainActor @Sendable (MarkdownFindMatchRefreshResult) -> Void
  ) {
    guard generation == requestGeneration else { return }
    isPending = false
    task = nil
    apply(result)
  }

  private nonisolated static func compute(
    text: String,
    query: String,
    options: MarkdownFindOptions
  ) -> MarkdownFindMatchRefreshResult? {
    do {
      return MarkdownFindMatchRefreshResult(
        ranges: try MarkdownFindReplaceService().matches(
          in: text,
          query: query,
          options: options,
          shouldCancel: { Task.isCancelled }
        ),
        errorMessage: nil
      )
    } catch is CancellationError {
      return nil
    } catch {
      return MarkdownFindMatchRefreshResult(
        ranges: [],
        errorMessage: error.localizedDescription
      )
    }
  }
}
