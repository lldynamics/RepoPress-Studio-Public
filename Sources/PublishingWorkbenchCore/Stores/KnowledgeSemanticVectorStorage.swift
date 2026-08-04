import Foundation
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
    var dot: Float = 0
    var lhsMagnitude: Float = 0
    var rhsMagnitude: Float = 0
    for index in lhs.indices {
      dot += lhs[index] * rhs[index]
      lhsMagnitude += lhs[index] * lhs[index]
      rhsMagnitude += rhs[index] * rhs[index]
    }
    guard lhsMagnitude > 0, rhsMagnitude > 0 else { return -1 }
    return Double(dot / sqrt(lhsMagnitude * rhsMagnitude))
  }
}
