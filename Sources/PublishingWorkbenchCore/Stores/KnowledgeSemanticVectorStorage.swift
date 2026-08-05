import Foundation
import Accelerate
import SQLite3

enum KnowledgeSemanticVectorStorage {
  static func vectorData(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  static func decodeVector(
    _ statement: OpaquePointer?,
    index: Int32,
    dimension: Int
  ) -> [Float] {
    guard dimension > 0,
          sqlite3_column_bytes(statement, index) == dimension * MemoryLayout<Float>.size,
          let pointer = sqlite3_column_blob(statement, index) else {
      return []
    }
    var output = [Float](repeating: 0, count: dimension)
    output.withUnsafeMutableBytes { destination in
      destination.copyMemory(
        from: UnsafeRawBufferPointer(
          start: pointer,
          count: dimension * MemoryLayout<Float>.size
        )
      )
    }
    return output
  }

  static func isValidStoredSemanticVector(
    _ values: [Float],
    expectedDimension: Int
  ) -> Bool {
    guard values.count == expectedDimension, !values.isEmpty else { return false }
    var squaredMagnitude: Double = 0
    for value in values {
      guard value.isFinite else { return false }
      squaredMagnitude += Double(value * value)
    }
    // Every vector written by KnowledgeSemanticVector is normalized. A broad
    // tolerance catches zero/truncated/corrupt blobs without rejecting harmless
    // floating-point drift between OS releases.
    return squaredMagnitude.isFinite && (0.5...1.5).contains(squaredMagnitude)
  }

  static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
    // `KnowledgeSemanticVector` normalizes vectors before persistence and
    // decode validation rejects zero/corrupt payloads. The hot retrieval path
    // therefore only needs the dot product; vDSP uses the available SIMD
    // instructions instead of repeating three scalar passes and two square
    // roots for every candidate.
    var dot: Float = 0
    lhs.withUnsafeBufferPointer { lhsBuffer in
      rhs.withUnsafeBufferPointer { rhsBuffer in
        vDSP_dotpr(
          lhsBuffer.baseAddress!,
          1,
          rhsBuffer.baseAddress!,
          1,
          &dot,
          vDSP_Length(lhs.count)
        )
      }
    }
    guard dot.isFinite else { return -1 }
    return Double(dot)
  }
}

struct KnowledgeSemanticVectorCacheKey: Hashable, Sendable {
  let modelIdentifier: String
  let chunkID: UUID
  let revisionID: UUID
  let dimension: Int
}

/// A small lock-protected LRU for decoded SQLite BLOBs. Semantic search is a
/// synchronous hot path, so an actor would add suspension overhead here; the
/// cache instead stays independent from the database lock and is safe for the
/// detached search/repair tasks that share a database connection.
final class KnowledgeSemanticVectorLRUCache: @unchecked Sendable {
  private let lock = NSLock()
  private let capacity: Int
  private var values: [KnowledgeSemanticVectorCacheKey: [Float]] = [:]
  private var recency: [KnowledgeSemanticVectorCacheKey] = []

  init(capacity: Int = 512) {
    self.capacity = max(1, capacity)
  }

  func value(for key: KnowledgeSemanticVectorCacheKey) -> [Float]? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values[key] else { return nil }
    touch(key)
    return value
  }

  func insert(_ value: [Float], for key: KnowledgeSemanticVectorCacheKey) {
    guard !value.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    values[key] = value
    touch(key)
    while recency.count > capacity {
      let evictedKey = recency.removeFirst()
      values[evictedKey] = nil
    }
  }

  func removeAll() {
    lock.lock()
    values.removeAll(keepingCapacity: true)
    recency.removeAll(keepingCapacity: true)
    lock.unlock()
  }

  private func touch(_ key: KnowledgeSemanticVectorCacheKey) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }
}
