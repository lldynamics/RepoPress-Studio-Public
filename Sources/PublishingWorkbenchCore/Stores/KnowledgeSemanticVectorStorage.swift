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
        guard let lhsBase = lhsBuffer.baseAddress,
              let rhsBase = rhsBuffer.baseAddress else {
          return
        }
        vDSP_dotpr(lhsBase, 1, rhsBase, 1, &dot, vDSP_Length(lhs.count))
      }
    }
    guard dot.isFinite else { return -1 }
    return Double(dot)
  }
}

/// The key for a contiguous semantic-vector snapshot.  Dimensions are part of
/// the key because NaturalLanguage can expose multiple models with different
/// vector widths, and a malformed/legacy row must never be compared against a
/// query from another width.
struct KnowledgeSemanticVectorIndexKey: Hashable, Sendable {
  let modelIdentifier: String
  let dimension: Int
}

/// Metadata kept beside a row in the flat vector buffer.  Keeping this small
/// lets the search path apply authorization and deterministic tie-breakers
/// without decoding a complete document or chunk for every candidate.
struct KnowledgeSemanticVectorIndexEntry: Sendable {
  let chunkID: UUID
  let revisionID: UUID
  let documentID: UUID
  let updatedAt: Double
  let ordinal: Int
  let allowsRemoteAIUse: Bool
  let allowsLocalSemanticIndex: Bool
  let isArchived: Bool
}

/// Immutable, per-model contiguous vector storage.  `vectors` contains
/// `entries.count * key.dimension` floats in row-major order.  The value is
/// safe to share after construction because neither the backing arrays nor the
/// metadata are mutated by retrieval.
struct KnowledgeSemanticVectorFlatIndex: Sendable {
  let key: KnowledgeSemanticVectorIndexKey
  let vectors: [Float]
  let entries: [KnowledgeSemanticVectorIndexEntry]

  var count: Int { entries.count }

  /// A conservative accounting value for cache admission.  It includes the
  /// contiguous float payload and the fixed-width metadata value type; Array
  /// header/slack overhead is intentionally covered by the budget margin.
  var estimatedByteCount: Int {
    vectors.count * MemoryLayout<Float>.stride
      + entries.count * MemoryLayout<KnowledgeSemanticVectorIndexEntry>.stride
  }

  func similarity(to query: [Float], row: Int) -> Double {
    guard key.dimension > 0,
          query.count == key.dimension,
          row >= 0,
          row < entries.count,
          vectors.count >= (row + 1) * key.dimension else {
      return -1
    }

    var dot: Float = 0
    query.withUnsafeBufferPointer { queryBuffer in
      vectors.withUnsafeBufferPointer { vectorBuffer in
        guard let queryBase = queryBuffer.baseAddress,
              let vectorBase = vectorBuffer.baseAddress else {
          return
        }
        vDSP_dotpr(
          queryBase,
          1,
          vectorBase.advanced(by: row * key.dimension),
          1,
          &dot,
          vDSP_Length(key.dimension)
        )
      }
    }
    guard dot.isFinite else { return -1 }
    return Double(dot)
  }
}

/// A small LRU for immutable flat snapshots.  The byte budget prevents a
/// library with many model/dimension combinations from retaining an
/// unbounded amount of vector memory. An individual snapshot larger than the
/// budget is returned to its current caller but is not retained by the cache.
final class KnowledgeSemanticVectorFlatIndexCache {
  static let defaultByteBudget = 256 * 1024 * 1024

  private let lock = NSLock()
  private let byteBudget: Int
  private var values: [KnowledgeSemanticVectorIndexKey: KnowledgeSemanticVectorFlatIndex] = [:]
  private var recency: [KnowledgeSemanticVectorIndexKey] = []
  private var retainedByteCount = 0

  init(byteBudget: Int = KnowledgeSemanticVectorFlatIndexCache.defaultByteBudget) {
    self.byteBudget = max(1, byteBudget)
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return values.count
  }

  var estimatedByteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return retainedByteCount
  }

  func value(for key: KnowledgeSemanticVectorIndexKey) -> KnowledgeSemanticVectorFlatIndex? {
    lock.lock()
    defer { lock.unlock() }
    guard let value = values[key] else { return nil }
    touch(key)
    return value
  }

  func insert(_ value: KnowledgeSemanticVectorFlatIndex) {
    lock.lock()
    defer { lock.unlock() }

    removeValue(for: value.key)
    let byteCount = value.estimatedByteCount
    if byteCount > byteBudget {
      return
    }

    while retainedByteCount + byteCount > byteBudget, let evictedKey = recency.first {
      removeValue(for: evictedKey)
    }
    values[value.key] = value
    recency.append(value.key)
    retainedByteCount += byteCount
  }

  func removeAll() {
    lock.lock()
    values.removeAll(keepingCapacity: true)
    recency.removeAll(keepingCapacity: true)
    retainedByteCount = 0
    lock.unlock()
  }

  private func touch(_ key: KnowledgeSemanticVectorIndexKey) {
    recency.removeAll { $0 == key }
    recency.append(key)
  }

  private func removeValue(for key: KnowledgeSemanticVectorIndexKey) {
    guard let value = values.removeValue(forKey: key) else { return }
    retainedByteCount = max(0, retainedByteCount - value.estimatedByteCount)
    recency.removeAll { $0 == key }
  }
}
