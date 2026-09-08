import Combine
import Foundation

/// Owns only the latest immutable recommendation presentation. The Inspector
/// can redraw freely while this coordinator performs grouping and snippets on a
/// utility task, then publishes only the newest input generation.
@MainActor
final class KnowledgeContextPresentationCoordinator: ObservableObject {
  @Published private(set) var snapshot: KnowledgeContextRecommendationPresentationSnapshot?

  private let calculateSnapshot: @Sendable (
    KnowledgeContextRecommendationPresentationInput
  ) async -> KnowledgeContextRecommendationPresentationSnapshot?
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var currentInput: KnowledgeContextRecommendationPresentationInput?

  init(
    calculateSnapshot: @escaping @Sendable (
      KnowledgeContextRecommendationPresentationInput
    ) async -> KnowledgeContextRecommendationPresentationSnapshot? = { input in
      let worker = Task.detached(priority: .utility) {
        KnowledgeContextRecommendationPresentationPolicy.snapshot(for: input)
      }
      return await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
    }
  ) {
    self.calculateSnapshot = calculateSnapshot
  }

  deinit {
    task?.cancel()
  }

  func update(with input: KnowledgeContextRecommendationPresentationInput) {
    guard currentInput != input else { return }
    currentInput = input
    snapshot = nil
    task?.cancel()
    generation &+= 1
    let expectedGeneration = generation
    let calculateSnapshot = calculateSnapshot

    task = Task { @MainActor [weak self] in
      let calculatedSnapshot = await calculateSnapshot(input)

      guard let self,
        !Task.isCancelled,
        self.generation == expectedGeneration,
        self.currentInput == input,
        let calculatedSnapshot
      else {
        return
      }
      self.snapshot = calculatedSnapshot
    }
  }
}
