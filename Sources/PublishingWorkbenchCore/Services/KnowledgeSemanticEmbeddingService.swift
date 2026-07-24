import Foundation
import NaturalLanguage

struct KnowledgeSemanticVector: Hashable, Sendable {
  var modelIdentifier: String
  var values: [Float]
  var minimumSimilarity: Double

  init(
    modelIdentifier: String,
    values: [Float],
    minimumSimilarity: Double
  ) {
    self.modelIdentifier = modelIdentifier
    self.values = Self.normalized(values)
    self.minimumSimilarity = minimumSimilarity
  }

  var isEmpty: Bool { values.isEmpty || !values.contains { $0 != 0 } }

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

struct KnowledgeChunkEmbedding: Sendable {
  var chunkID: UUID
  var revisionID: UUID
  var vector: KnowledgeSemanticVector
}

struct KnowledgeSemanticIndexRecord: Sendable {
  var document: KnowledgeDocument
  var chunk: KnowledgeChunk

  var searchableText: String {
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
final class KnowledgeSemanticEmbeddingService: @unchecked Sendable {
  static let fallbackModelIdentifier = "local-semantic-hash-v2"

  private let lock = NSLock()
  private let contextualInferenceLock = NSLock()
  private var contextualModels: [String: NLContextualEmbedding] = [:]
  private var loadedContextualModelIDs: Set<String> = []
  private var preparingContextualModelIDs: Set<String> = []

  func vectors(for text: String) -> [KnowledgeSemanticVector] {
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

  func vector(for text: String, modelIdentifier: String) -> KnowledgeSemanticVector? {
    vectors(for: text).first { $0.modelIdentifier == modelIdentifier }
  }

  func availableModelDimensions(for texts: [String]) -> [String: Int] {
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

  func prepareContextualModelIfNeeded(for text: String) {
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

    for concept in Self.semanticConcepts {
      guard !Task.isCancelled else { break }
      if concept.aliases.contains(where: normalized.contains) {
        addHashedFeature("concept:\(concept.id)", weight: 7.0, to: &values)
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

  private struct SemanticConcept: Sendable {
    var id: String
    var aliases: [String]
  }

  private static let semanticConcepts: [SemanticConcept] = [
    SemanticConcept(id: "cost", aliases: ["成本", "降低成本", "节约成本", "减少开销", "压缩开支", "节省开支", "日常支出", "预算", "开销", "开支", "支出", "省钱", "cost", "expense", "budget", "save money"]),
    SemanticConcept(id: "memory", aliases: ["记忆", "记住", "遗忘", "间隔重复", "复习", "回忆", "memory", "remember", "spaced repetition", "review"]),
    SemanticConcept(id: "learning", aliases: ["学习", "掌握知识", "自学", "教育", "训练", "learning", "study", "education", "training"]),
    SemanticConcept(id: "writing", aliases: ["写作", "撰写", "创作", "成文", "文章", "writing", "drafting", "compose", "article"]),
    SemanticConcept(id: "retrieval", aliases: ["检索", "搜索", "查找", "寻找资料", "召回", "retrieval", "search", "find", "lookup"]),
    SemanticConcept(id: "knowledge", aliases: ["知识库", "资料库", "知识管理", "第二大脑", "笔记系统", "knowledge base", "knowledge management", "second brain"]),
    SemanticConcept(id: "productivity", aliases: ["效率", "生产力", "提高产出", "节省时间", "工作流", "productivity", "efficiency", "workflow", "save time"]),
    SemanticConcept(id: "health", aliases: ["健康", "身体状况", "身心", "保健", "health", "wellbeing", "wellness"]),
    SemanticConcept(id: "sleep", aliases: ["睡眠", "入睡", "失眠", "休息", "睡觉", "sleep", "insomnia", "rest"]),
    SemanticConcept(id: "emotion", aliases: ["情绪", "心情", "焦虑", "压力", "心理", "emotion", "mood", "anxiety", "stress"]),
    SemanticConcept(id: "decision", aliases: ["决策", "选择", "判断", "取舍", "decision", "choice", "judgment", "tradeoff"]),
    SemanticConcept(id: "risk", aliases: ["风险", "危险", "隐患", "不确定性", "risk", "danger", "uncertainty"]),
    SemanticConcept(id: "privacy", aliases: ["隐私", "数据保护", "个人信息", "保密", "privacy", "data protection", "confidential"]),
    SemanticConcept(id: "security", aliases: ["安全", "防护", "攻击", "漏洞", "security", "protection", "attack", "vulnerability"]),
    SemanticConcept(id: "software", aliases: ["软件", "程序", "应用", "代码", "开发", "software", "program", "application", "code", "development"]),
    SemanticConcept(id: "research", aliases: ["研究", "调研", "调查", "论证", "证据", "research", "investigation", "evidence"]),
    SemanticConcept(id: "communication", aliases: ["沟通", "交流", "表达", "对话", "communication", "conversation", "dialogue"]),
    SemanticConcept(id: "management", aliases: ["管理", "治理", "组织", "规划", "management", "governance", "organization", "planning"]),
    SemanticConcept(id: "growth", aliases: ["增长", "成长", "提升", "进步", "growth", "improvement", "progress"]),
    SemanticConcept(id: "sustainability", aliases: ["可持续", "长期主义", "长期保存", "耐久", "sustainable", "long term", "durable"]),
  ]
}
