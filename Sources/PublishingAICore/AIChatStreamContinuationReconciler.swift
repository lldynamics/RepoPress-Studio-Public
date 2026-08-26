import Foundation

/// Builds a bounded paragraph checkpoint and removes text that a provider
/// repeats at the beginning of a continuation response.
///
/// The reconciler deliberately buffers the first continuation prefix. A
/// repeated overlap can arrive over several SSE deltas; yielding the first
/// delta before the overlap is known would make duplicate text visible.
public struct AIChatStreamContinuationReconciler: Sendable {
  private let existingText: [Character]
  private let overlapProbeCharacterCount: Int
  private var pendingPrefix: [Character] = []
  private var didResolve = false

  public init(
    alreadyYieldedText: String,
    overlapProbeCharacterCount: Int = 8_192
  ) {
    let probeLimit = max(1, overlapProbeCharacterCount)
    self.existingText = Array(alreadyYieldedText.suffix(probeLimit))
    self.overlapProbeCharacterCount = probeLimit
  }

  /// Returns only the newly visible portion of a continuation delta.
  public mutating func reconcile(_ delta: String) -> String {
    guard !delta.isEmpty else { return "" }
    guard !didResolve else { return delta }

    pendingPrefix.append(contentsOf: delta)
    guard shouldResolvePending() else { return "" }
    return resolvePending(force: false)
  }

  /// Flushes a buffered prefix when the continuation stream completes.
  /// Prefixes that still match an existing suffix are treated as overlap, so a
  /// truncated repeated prefix cannot leak duplicate visible text.
  public mutating func finish() -> String {
    guard !didResolve else { return "" }
    return resolvePending(force: true)
  }

  /// Returns a bounded suffix that keeps the latest complete paragraph and the
  /// current incomplete paragraph. Short text is preserved byte-for-byte.
  public static func checkpointText(
    from text: String,
    maximumCharacterCount: Int = 8_192
  ) -> String {
    let maximum = max(1, maximumCharacterCount)
    let characters = Array(text)
    guard characters.count > maximum else { return text }

    let suffix = String(characters.suffix(maximum))
    if let boundary = suffix.range(of: "\n\n") {
      return "…\n\n" + suffix[boundary.upperBound...]
    }
    if let boundary = suffix.lastIndex(of: "\n") {
      return "…\n" + suffix[boundary...]
    }
    return "…" + suffix
  }

  private func shouldResolvePending() -> Bool {
    if pendingPrefix.count >= overlapProbeCharacterCount {
      return true
    }
    // A paragraph boundary is a useful checkpoint: providers generally repeat
    // complete paragraphs before continuing into the next one.
    if pendingPrefix.count >= 2 {
      for index in pendingPrefix.indices.dropFirst() {
        guard pendingPrefix[index] == "\n" else { continue }
        let previous = pendingPrefix.index(before: index)
        if pendingPrefix[previous] == "\n" {
          return true
        }
      }
    }
    return !hasPotentialOverlapPrefix(pendingPrefix)
  }

  private mutating func resolvePending(force: Bool) -> String {
    didResolve = true
    if force {
      let result = String(pendingPrefix)
      pendingPrefix.removeAll(keepingCapacity: false)
      return result
    }
    let overlap = largestCompletedOverlap()
    // A short prefix that merely occurs before the existing suffix is not
    // proof of duplication. If the stream ends before a complete suffix/prefix
    // overlap is observed, keep the text; only a completed overlap is stripped.
    let start = min(overlap, pendingPrefix.count)
    let result = String(pendingPrefix.dropFirst(start))
    pendingPrefix.removeAll(keepingCapacity: false)
    return result
  }

  private func hasPotentialOverlapPrefix(_ candidate: [Character]) -> Bool {
    guard !candidate.isEmpty else { return true }
    guard candidate.count <= existingText.count else { return false }
    let maximumStart = existingText.count - candidate.count
    guard maximumStart >= 0 else { return false }
    for start in 0...maximumStart {
      if existingText[start..<(start + candidate.count)].elementsEqual(candidate) {
        return true
      }
    }
    return false
  }

  private func largestCompletedOverlap() -> Int {
    let maximum = min(existingText.count, pendingPrefix.count)
    guard maximum > 0 else { return 0 }
    for length in stride(from: maximum, through: 1, by: -1) {
      let existingStart = existingText.count - length
      if existingText[existingStart..<existingText.count]
        .elementsEqual(pendingPrefix[0..<length])
      {
        return length
      }
    }
    return 0
  }
}
