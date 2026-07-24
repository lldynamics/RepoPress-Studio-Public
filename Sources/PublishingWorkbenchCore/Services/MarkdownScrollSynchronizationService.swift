import Foundation

public struct MarkdownScrollSynchronizationService: Sendable {
  public init() {}

  public func progress(
    contentOffset: Double,
    viewportLength: Double,
    contentLength: Double
  ) -> Double {
    let scrollableLength = max(0, contentLength - viewportLength)
    guard scrollableLength > 0 else { return 0 }
    return clamped(contentOffset / scrollableLength)
  }

  public func contentOffset(
    progress: Double,
    viewportLength: Double,
    contentLength: Double
  ) -> Double {
    clamped(progress) * max(0, contentLength - viewportLength)
  }

  private func clamped(_ value: Double) -> Double {
    min(max(value.isFinite ? value : 0, 0), 1)
  }
}
