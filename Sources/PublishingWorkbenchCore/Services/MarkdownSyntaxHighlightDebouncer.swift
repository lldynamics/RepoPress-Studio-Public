import Foundation

public struct MarkdownSyntaxHighlightDebouncerMetrics: Equatable, Sendable {
  public let scheduledRequestCount: Int
  public let startedComputationCount: Int
  public let deliveredResultCount: Int

  public var coalescedBeforeComputationCount: Int {
    max(0, scheduledRequestCount - startedComputationCount)
  }
}

@MainActor
public final class MarkdownSyntaxHighlightDebouncer {
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var scheduledRequestCount = 0
  private var startedComputationCount = 0
  private var deliveredResultCount = 0

  public init() {}

  deinit {
    task?.cancel()
  }

  public var metrics: MarkdownSyntaxHighlightDebouncerMetrics {
    MarkdownSyntaxHighlightDebouncerMetrics(
      scheduledRequestCount: scheduledRequestCount,
      startedComputationCount: startedComputationCount,
      deliveredResultCount: deliveredResultCount
    )
  }

  public func schedule<Output: Sendable>(
    delay: TimeInterval,
    operation: @escaping @Sendable () async -> Output?,
    onValue: @escaping @MainActor @Sendable (Output) -> Void
  ) {
    task?.cancel()
    generation &+= 1
    scheduledRequestCount += 1
    let requestGeneration = generation
    let effectiveDelay = delay.isFinite ? max(0, delay) : 0

    task = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        try await Task.sleep(for: .seconds(effectiveDelay))
      } catch {
        return
      }
      guard !Task.isCancelled,
            await self?.beginComputation(for: requestGeneration) == true else {
        return
      }
      guard let output = await operation() else {
        await self?.finishWithoutValue(for: requestGeneration)
        return
      }
      guard !Task.isCancelled else { return }
      await self?.deliver(
        output,
        for: requestGeneration,
        onValue: onValue
      )
    }
  }

  public func cancel() {
    task?.cancel()
    task = nil
    generation &+= 1
  }

  public func waitUntilIdle() async {
    let currentTask = task
    await currentTask?.value
  }

  private func beginComputation(for requestGeneration: UInt64) -> Bool {
    guard requestGeneration == generation else { return false }
    startedComputationCount += 1
    return true
  }

  private func finishWithoutValue(for requestGeneration: UInt64) {
    guard requestGeneration == generation else { return }
    task = nil
  }

  private func deliver<Output: Sendable>(
    _ output: Output,
    for requestGeneration: UInt64,
    onValue: @MainActor @Sendable (Output) -> Void
  ) {
    guard requestGeneration == generation else { return }
    deliveredResultCount += 1
    task = nil
    onValue(output)
  }
}
