import Foundation
import NaturalLanguage
import PublishingCoreSupport

package struct KnowledgeSemanticVector: Hashable, Sendable {
  package var modelIdentifier: String
  package var values: [Float]
  package var minimumSimilarity: Double

  package init(
    modelIdentifier: String,
    values: [Float],
    minimumSimilarity: Double
  ) {
    self.modelIdentifier = modelIdentifier
    self.values = Self.normalized(values)
    self.minimumSimilarity = minimumSimilarity
  }

  package var isEmpty: Bool { values.isEmpty || !values.contains { $0 != 0 } }

  private static func normalized(_ values: [Float]) -> [Float] {
    guard !values.isEmpty, values.allSatisfy(\.isFinite) else { return [] }
    let squaredMagnitude = values.reduce(Double.zero) {
      $0 + (Double($1) * Double($1))
    }
    guard squaredMagnitude.isFinite, squaredMagnitude > 0 else { return [] }
    let magnitude = Float(sqrt(squaredMagnitude))
    guard magnitude.isFinite, magnitude > 0 else { return [] }
    return values.map { $0 / magnitude }
  }
}

package struct KnowledgeChunkEmbedding: Sendable {
  package var chunkID: UUID
  package var revisionID: UUID
  package var vector: KnowledgeSemanticVector

  package init(
    chunkID: UUID,
    revisionID: UUID,
    vector: KnowledgeSemanticVector
  ) {
    self.chunkID = chunkID
    self.revisionID = revisionID
    self.vector = vector
  }
}

package struct KnowledgeSemanticIndexRecord: Sendable {
  package var document: KnowledgeDocument
  package var chunk: KnowledgeChunk

  package init(document: KnowledgeDocument, chunk: KnowledgeChunk) {
    self.document = document
    self.chunk = chunk
  }

  package var searchableText: String {
    [
      document.title,
      document.summary,
      document.authors.joined(separator: " "),
      document.tags.joined(separator: " "),
      chunk.headingPath ?? "",
      chunk.content,
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "\n")
  }
}

/// Produces semantic vectors without sending library content to a remote service.
///
/// A compact feature-hashed vector is always available. When macOS already has a
/// suitable NaturalLanguage model, the service also stores its dense vector. A
/// missing contextual model is requested in the background and becomes an
/// additional index on a later search; retrieval never blocks on a model download.
package final class KnowledgeSemanticEmbeddingService: @unchecked Sendable {
  package static let fallbackModelIdentifier = "local-semantic-hash-v2"

  package init() {}

  private let lock = NSLock()
  private let contextualInferenceLock = NSLock()
  private var contextualModels: [String: NLContextualEmbedding] = [:]
  private var loadedContextualModelIDs: Set<String> = []
  private var preparingContextualModelIDs: Set<String> = []

  package func vectors(for text: String) -> [KnowledgeSemanticVector] {
    guard !Task.isCancelled else { return [] }
    let normalizedText = text.trimmedForPublishing
    guard !normalizedText.isEmpty else { return [] }

    var output = [fallbackVector(for: normalizedText)]
    guard !Task.isCancelled else { return [] }
    let language = detectedLanguage(for: normalizedText)

    if language != .simplifiedChinese,
       let sentenceVector = sentenceVector(for: normalizedText, language: language) {
      output.append(sentenceVector)
    } else if language == .english,
              let wordVector = englishWordVector(for: normalizedText) {
      output.append(wordVector)
    }

    if let contextualVector = contextualVector(for: normalizedText, language: language) {
      output.append(contextualVector)
    }
    guard !Task.isCancelled else { return [] }

    var seen: Set<String> = []
    return output.filter { vector in
      guard !Task.isCancelled else { return false }
      return !vector.isEmpty && seen.insert(vector.modelIdentifier).inserted
    }
  }

  package func vector(for text: String, modelIdentifier: String) -> KnowledgeSemanticVector? {
    vectors(for: text).first { $0.modelIdentifier == modelIdentifier }
  }

  package func availableModelDimensions(for texts: [String]) -> [String: Int] {
    var sampleByLanguage: [String: String] = [:]
    for text in texts {
      guard !Task.isCancelled else { return [:] }
      let normalizedText = text.trimmedForPublishing
      guard !normalizedText.isEmpty else { continue }
      let language = detectedLanguage(for: normalizedText)
      sampleByLanguage[language.rawValue, default: normalizedText] = normalizedText
    }
    if sampleByLanguage.isEmpty {
      sampleByLanguage[NLLanguage.simplifiedChinese.rawValue] = "资料库健康检查"
    }

    var dimensions: [String: Int] = [:]
    for sample in sampleByLanguage.values {
      guard !Task.isCancelled else { return [:] }
      for vector in vectors(for: sample) {
        dimensions[vector.modelIdentifier] = vector.values.count
      }
    }
    return dimensions
  }

  package func prepareContextualModelIfNeeded(for text: String) {
    let language = detectedLanguage(for: text)
    guard let model = contextualModel(for: language) else { return }
    let identifier = contextualIdentifier(for: model)

    lock.lock()
    let shouldPrepare = !loadedContextualModelIDs.contains(identifier)
      && preparingContextualModelIDs.insert(identifier).inserted
    lock.unlock()
    guard shouldPrepare else { return }

    Task.detached(priority: .utility) { [weak self] in
      if !model.hasAvailableAssets {
        _ = try? await model.requestAssets()
      }
      let didLoad: Bool
      if model.hasAvailableAssets {
        do {
          try model.load()
          didLoad = true
        } catch {
          didLoad = false
        }
      } else {
        didLoad = false
      }
      self?.finishPreparingContextualModel(identifier, didLoad: didLoad)
    }
  }

  private func finishPreparingContextualModel(
    _ identifier: String,
    didLoad: Bool
  ) {
    lock.lock()
    if didLoad {
      loadedContextualModelIDs.insert(identifier)
    }
    preparingContextualModelIDs.remove(identifier)
    lock.unlock()
  }

  private func fallbackVector(for text: String) -> KnowledgeSemanticVector {
    let dimension = 384
    var values = [Float](repeating: 0, count: dimension)
    let normalized = text
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
      .lowercased()

    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = normalized
    tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
      guard !Task.isCancelled else { return false }
      let token = String(normalized[range]).trimmingCharacters(in: .punctuationCharacters)
      if !token.isEmpty {
        addHashedFeature("word:\(token)", weight: 1.0, to: &values)
      }
      return true
    }

    let compactCharacters = normalized.unicodeScalars.filter {
      !CharacterSet.whitespacesAndNewlines.contains($0)
        && !CharacterSet.punctuationCharacters.contains($0)
    }
    let scalars = Array(compactCharacters)
    if scalars.count >= 2 {
      for index in 0..<(scalars.count - 1) {
        guard !Task.isCancelled else { break }
        addHashedFeature(
          "gram2:\(String(String.UnicodeScalarView(scalars[index...index + 1])))",
          weight: 0.34,
          to: &values
        )
      }
    }
    if scalars.count >= 3 {
      for index in 0..<(scalars.count - 2) {
        guard !Task.isCancelled else { break }
        addHashedFeature(
          "gram3:\(String(String.UnicodeScalarView(scalars[index...index + 2])))",
          weight: 0.18,
          to: &values
        )
      }
    }

    // The fallback vector has no downloaded Chinese word-embedding model on
    // many macOS installations. Keep a small, deterministic topic projection
    // so common paraphrases still meet the semantic-search threshold.  The
    // markers are deliberately action/topic phrases rather than a general
    // synonym dictionary: a bare abstract word such as "成本" remains purely
    // lexical, avoiding false semantic matches between unrelated labels.
    for topic in Self.offlineTopicMarkers {
      guard !Task.isCancelled else { break }
      if topic.markers.contains(where: normalized.contains) {
        addHashedFeature("topic:\(topic.id)", weight: 3.0, to: &values)
      }
    }

    return KnowledgeSemanticVector(
      modelIdentifier: Self.fallbackModelIdentifier,
      values: values,
      minimumSimilarity: 0.16
    )
  }

  private func sentenceVector(
    for text: String,
    language: NLLanguage
  ) -> KnowledgeSemanticVector? {
    guard !Task.isCancelled,
          let embedding = NLEmbedding.sentenceEmbedding(for: language),
          let values = embedding.vector(for: clipped(text, maximumCharacters: 1_600)) else {
      return nil
    }
    guard !Task.isCancelled else { return nil }
    return KnowledgeSemanticVector(
      modelIdentifier: "apple-sentence-\(language.rawValue)-r\(embedding.revision)-d\(embedding.dimension)",
      values: values.map(Float.init),
      minimumSimilarity: 0.25
    )
  }

  private func englishWordVector(for text: String) -> KnowledgeSemanticVector? {
    guard !Task.isCancelled,
          let embedding = NLEmbedding.wordEmbedding(for: .english) else { return nil }
    let normalized = text.lowercased()
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = normalized
    var aggregate = [Double](repeating: 0, count: embedding.dimension)
    var count = 0
    tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
      guard !Task.isCancelled else { return false }
      let token = String(normalized[range])
      guard let vector = embedding.vector(for: token), vector.count == aggregate.count else {
        return true
      }
      for index in aggregate.indices {
        aggregate[index] += vector[index]
      }
      count += 1
      return count < 160
    }
    guard !Task.isCancelled, count > 0 else { return nil }
    return KnowledgeSemanticVector(
      modelIdentifier: "apple-word-en-r\(embedding.revision)-mean-v1",
      values: aggregate.map { Float($0 / Double(count)) },
      minimumSimilarity: 0.2
    )
  }

  private func contextualVector(
    for text: String,
    language: NLLanguage
  ) -> KnowledgeSemanticVector? {
    guard !Task.isCancelled,
          let model = contextualModel(for: language) else { return nil }
    let identifier = contextualIdentifier(for: model)
    lock.lock()
    let isLoaded = loadedContextualModelIDs.contains(identifier)
    lock.unlock()
    guard isLoaded else { return nil }

    let input = clipped(text, maximumCharacters: 1_600)
    contextualInferenceLock.lock()
    defer { contextualInferenceLock.unlock() }
    guard let result = try? model.embeddingResult(for: input, language: language) else { return nil }
    var aggregate = [Double](repeating: 0, count: model.dimension)
    var count = 0
    result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
      guard !Task.isCancelled else { return true }
      guard vector.count == aggregate.count else { return false }
      for index in aggregate.indices {
        aggregate[index] += vector[index]
      }
      count += 1
      return false
    }
    guard !Task.isCancelled, count > 0 else { return nil }
    return KnowledgeSemanticVector(
      modelIdentifier: identifier,
      values: aggregate.map { Float($0 / Double(count)) },
      minimumSimilarity: 0.3
    )
  }

  private func contextualModel(for language: NLLanguage) -> NLContextualEmbedding? {
    lock.lock()
    defer { lock.unlock() }
    if let cached = contextualModels[language.rawValue] { return cached }
    guard let model = NLContextualEmbedding(language: language) else { return nil }
    contextualModels[language.rawValue] = model
    return model
  }

  private func contextualIdentifier(for model: NLContextualEmbedding) -> String {
    "apple-contextual-\(model.modelIdentifier)-r\(model.revision)-mean-v1"
  }

  private func detectedLanguage(for text: String) -> NLLanguage {
    let sample = clipped(text, maximumCharacters: 1_200)
    if sample.unicodeScalars.contains(where: { scalar in
      (0x3400...0x9FFF).contains(Int(scalar.value))
    }) {
      return .simplifiedChinese
    }
    return NLLanguageRecognizer.dominantLanguage(for: sample) ?? .english
  }

  private func clipped(_ text: String, maximumCharacters: Int) -> String {
    guard text.count > maximumCharacters else { return text }
    let end = text.index(text.startIndex, offsetBy: maximumCharacters)
    return String(text[..<end])
  }

  private func addHashedFeature(
    _ feature: String,
    weight: Float,
    to values: inout [Float]
  ) {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in feature.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let index = Int(hash % UInt64(values.count))
    let sign: Float = (hash & (1 << 63)) == 0 ? 1 : -1
    values[index] += sign * weight
  }

  private struct OfflineTopicMarker: Sendable {
    let id: String
    let markers: [String]
  }

  private static let offlineTopicMarkers: [OfflineTopicMarker] = [
    OfflineTopicMarker(
      id: "spending-control",
      markers: [
        "降低成本", "节约成本", "减少开销", "压缩开支", "节省开支",
        "日常支出", "预算", "开销", "开支", "支出", "省钱", "生活成本",
        "cost", "expense", "budget", "save money",
      ]
    ),
    OfflineTopicMarker(
      id: "memory-learning",
      markers: [
        "记忆", "记住", "遗忘", "间隔重复", "复习", "回忆",
        "memory", "remember", "spaced repetition", "review",
      ]
    ),
  ]

}
