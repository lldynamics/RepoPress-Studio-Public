import Combine
import Foundation

enum AIChatSurfaceOperationLifecycleEvent: Equatable {
  case transientSurfaceDisappearance
  case explicitStop(ownerToken: UUID)
  case ownerTeardown
}

/// Owns one AI chat operation for the lifetime of a workbench window.
///
/// The Inspector is intentionally replaceable: workspace navigation, focus
/// mode, and responsive layout can all remove and recreate its SwiftUI view.
/// Keeping the Task and owner token here lets the operation continue across
/// those presentation changes while preserving token-scoped explicit stop.
@MainActor
final class AIChatSurfaceOperationSession: ObservableObject {
  @Published private(set) var activeOwnerToken: UUID?
  private var task: Task<Void, Never>?

  var hasActiveTask: Bool {
    task != nil && activeOwnerToken != nil
  }

  @discardableResult
  func start(
    ownerToken: UUID,
    operation: @escaping @MainActor () async -> Void
  ) -> Bool {
    guard task == nil, activeOwnerToken == nil else { return false }
    activeOwnerToken = ownerToken
    task = Task { [weak self] in
      await operation()
      self?.finish(ownerToken: ownerToken)
    }
    return true
  }

  @discardableResult
  func handle(
    _ event: AIChatSurfaceOperationLifecycleEvent,
    forwardingTo cancellationHandler: (UUID) -> Void
  ) -> Bool {
    switch event {
    case .transientSurfaceDisappearance:
      return false
    case .explicitStop(let expectedOwnerToken):
      return cancel(
        expectedOwnerToken: expectedOwnerToken,
        forwardingTo: cancellationHandler
      )
    case .ownerTeardown:
      guard let ownerToken = activeOwnerToken, let task else { return false }
      // A window teardown must break the session -> task -> operation capture
      // chain even when the underlying transport does not cooperate with
      // cancellation. Explicit Stop intentionally keeps ownership until the
      // operation acknowledges cancellation and finishes.
      self.task = nil
      activeOwnerToken = nil
      task.cancel()
      cancellationHandler(ownerToken)
      return true
    }
  }

  private func cancel(
    expectedOwnerToken: UUID,
    forwardingTo cancellationHandler: (UUID) -> Void
  ) -> Bool {
    guard activeOwnerToken == expectedOwnerToken, let task else { return false }
    task.cancel()
    cancellationHandler(expectedOwnerToken)
    return true
  }

  func finish(ownerToken: UUID) {
    guard activeOwnerToken == ownerToken else { return }
    task = nil
    activeOwnerToken = nil
  }
}
