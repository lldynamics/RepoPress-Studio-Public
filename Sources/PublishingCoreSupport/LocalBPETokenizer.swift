import Foundation

/// The two OpenAI mergeable BPE vocabularies used by the local prompt-size
/// calculator.  The vocabulary files are intentionally kept as resources so
/// no network request (or Python runtime) is needed when preparing a request.
public struct LocalBPETokenizer: Sendable {
  public enum Encoding: String, Codable, CaseIterable, Hashable, Sendable {
    case o200kBase = "o200k_base"
    case cl100kBase = "cl100k_base"

    public var resourceName: String { rawValue }
  }

  public enum Precision: String, Codable, Hashable, Sendable {
    case exact
    /// A byte count is an upper bound for a byte-pair encoding.  It is used
    /// when an optional vocabulary resource is absent or malformed.
    case conservativeFallback
  }

  /// A model-independent conservative upper bound for one string.  Every
  /// valid BPE token contains at least one UTF-8 byte, so this cannot
  /// under-count a prompt when a provider-specific vocabulary is unavailable.
  public static func conservativeTokenCount(_ text: String) -> Int {
    text.utf8.count
  }

  /// Returns the tiktoken family that is known for common model names.
  /// Providers with a different tokenizer deliberately return `nil`; using a
  /// foreign vocabulary would look precise while producing a wrong count.
  public static func encoding(forModel model: String) -> Encoding? {
    let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { return nil }
    if value == Encoding.o200kBase.rawValue { return .o200kBase }
    if value == Encoding.cl100kBase.rawValue { return .cl100kBase }

    let o200kMarkers = [
      "gpt-4o", "gpt-4.1", "gpt-5", "o1", "o3", "o4"
    ]
    if o200kMarkers.contains(where: {
      value == $0 || value.hasPrefix($0 + "-") || value.hasPrefix($0 + ".")
    }) {
      return .o200kBase
    }

    let cl100kMarkers = ["gpt-4", "gpt-3.5", "text-embedding-3"]
    if cl100kMarkers.contains(where: { value == $0 || value.hasPrefix($0 + "-") }) {
      return .cl100kBase
    }
    return nil
  }

  /// Alias retained for call sites that use the shorter spelling.
  public static func encoding(for model: String) -> Encoding? {
    encoding(forModel: model)
  }

  public let encoding: Encoding?
  public let precision: Precision

  private let vocabulary: Vocabulary?

  public var isExact: Bool { precision == .exact }
  public var usesConservativeFallback: Bool { precision == .conservativeFallback }

  /// Loads an encoding from `Bundle.module/Tokenizers`.  `resourceURL` is
  /// injectable for tests and for callers that keep resources outside the app
  /// bundle.  A missing resource never throws and always selects byte-count
  /// fallback mode.
  public init(
    encoding: Encoding = .o200kBase,
    resourceURL: URL? = nil
  ) {
    self.init(
      selectedEncoding: encoding,
      resourceURL: resourceURL,
      resourceData: nil
    )
  }

  /// Initializes a tokenizer for a model.  Unknown models intentionally use
  /// the conservative byte counter instead of guessing another vocabulary.
  public init(model: String, resourceURL: URL? = nil) {
    self.init(
      selectedEncoding: Self.encoding(forModel: model),
      resourceURL: resourceURL,
      resourceData: nil
    )
  }

  /// Initializes from raw `.tiktoken` data.  This is useful for deterministic
  /// tests and for embedders that provide their own resource bundle.
  public init(resourceData: Data, encoding: Encoding = .o200kBase) {
    self.init(
      selectedEncoding: encoding,
      resourceURL: nil,
      resourceData: resourceData
    )
  }

  /// Counts tokens in ordinary text.  Special-token strings are treated as
  /// ordinary text on purpose: prompt text must not be able to smuggle a
  /// tiktoken control token into a request merely by spelling its name.
  public func tokenCount(_ text: String) -> Int {
    encode(text).count
  }

  public func count(_ text: String) -> Int {
    tokenCount(text)
  }

  /// Returns merge ranks when the vocabulary is available.  In fallback mode
  /// each UTF-8 byte is represented by its byte value, which is sufficient for
  /// count and truncation callers and makes the fallback observable in tests.
  public func encode(_ text: String) -> [Int] {
    guard !text.isEmpty else { return [] }
    guard let vocabulary else {
      return text.utf8.map(Int.init)
    }

    var result: [Int] = []
    result.reserveCapacity(max(1, text.utf8.count / 3))
    for chunk in chunks(in: text, using: vocabulary.pattern) {
      guard let encoded = encodeChunk(chunk, vocabulary: vocabulary) else {
        return text.utf8.map(Int.init)
      }
      result.append(contentsOf: encoded)
    }
    return result
  }

  // MARK: - Private

  private init(
    selectedEncoding: Encoding?,
    resourceURL: URL?,
    resourceData: Data?
  ) {
    self.encoding = selectedEncoding
    guard let selectedEncoding else {
      self.vocabulary = nil
      self.precision = .conservativeFallback
      return
    }

    let loaded: Vocabulary?
    if let resourceData {
      loaded = Vocabulary(data: resourceData, encoding: selectedEncoding)
    } else {
      loaded = VocabularyCache.shared.vocabulary(
        for: selectedEncoding,
        resourceURL: resourceURL
      )
    }
    self.vocabulary = loaded
    self.precision = loaded == nil ? .conservativeFallback : .exact
  }

  private func chunks(
    in text: String,
    using pattern: NSRegularExpression?
  ) -> [String] {
    guard let pattern else { return [text] }
    let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = pattern.matches(in: text, range: fullRange)
    guard !matches.isEmpty else { return [text] }

    var output: [String] = []
    output.reserveCapacity(matches.count)
    var cursor = text.startIndex
    for match in matches {
      guard let range = Range(match.range, in: text) else { continue }
      if cursor < range.lowerBound {
        output.append(String(text[cursor..<range.lowerBound]))
      }
      output.append(String(text[range]))
      cursor = range.upperBound
    }
    if cursor < text.endIndex {
      output.append(String(text[cursor..<text.endIndex]))
    }
    return output.isEmpty ? [text] : output
  }

  private func encodeChunk(_ chunk: String, vocabulary: Vocabulary) -> [Int]? {
    var nodes = chunk.utf8.map { MergeNode(bytes: Data([$0])) }
    guard !nodes.isEmpty else { return [] }

    var heap = MergeMinHeap()
    for index in nodes.indices {
      nodes[index].previous = index == nodes.startIndex ? nil : index - 1
      nodes[index].next = index == nodes.index(before: nodes.endIndex) ? nil : index + 1
    }
    for index in nodes.indices.dropLast() {
      pushCandidate(
        leftIndex: index,
        nodes: nodes,
        vocabulary: vocabulary,
        into: &heap
      )
    }

    // The heap removes the old implementation's O(n²) full-pair scan. Each
    // merge invalidates at most the predecessor and the merged node, so the
    // long no-whitespace path is O(n log n) in candidate count.
    while let candidate = heap.pop() {
      guard candidate.left < nodes.count,
        nodes[candidate.left].alive,
        nodes[candidate.left].generation == candidate.leftGeneration,
        let right = nodes[candidate.left].next,
        right < nodes.count,
        nodes[right].alive,
        nodes[right].generation == candidate.rightGeneration
      else { continue }

      var merged = nodes[candidate.left].bytes
      merged.append(nodes[right].bytes)
      nodes[candidate.left].bytes = merged
      nodes[candidate.left].generation &+= 1
      nodes[candidate.left].next = nodes[right].next
      nodes[right].alive = false
      if let next = nodes[right].next {
        nodes[next].previous = candidate.left
      }

      if let previous = nodes[candidate.left].previous {
        pushCandidate(
          leftIndex: previous,
          nodes: nodes,
          vocabulary: vocabulary,
          into: &heap
        )
      }
      pushCandidate(
        leftIndex: candidate.left,
        nodes: nodes,
        vocabulary: vocabulary,
        into: &heap
      )
    }

    var result: [Int] = []
    result.reserveCapacity(nodes.count)
    var index: Int? = nodes.firstIndex(where: { $0.alive })
    while let current = index {
      guard let rank = vocabulary.ranks[nodes[current].bytes] else { return nil }
      result.append(rank)
      index = nodes[current].next
    }
    return result
  }

  private func pushCandidate(
    leftIndex: Int,
    nodes: [MergeNode],
    vocabulary: Vocabulary,
    into heap: inout MergeMinHeap
  ) {
    guard leftIndex >= 0, leftIndex < nodes.count, nodes[leftIndex].alive,
      let right = nodes[leftIndex].next,
      right < nodes.count, nodes[right].alive
    else { return }
    var pair = nodes[leftIndex].bytes
    pair.append(nodes[right].bytes)
    guard let rank = vocabulary.ranks[pair] else { return }
    heap.push(
      MergeCandidate(
        rank: rank,
        left: leftIndex,
        leftGeneration: nodes[leftIndex].generation,
        rightGeneration: nodes[right].generation
      )
    )
  }
}

private struct MergeNode {
  var bytes: Data
  var previous: Int?
  var next: Int?
  var generation = 0
  var alive = true
}

private struct MergeCandidate {
  let rank: Int
  let left: Int
  let leftGeneration: Int
  let rightGeneration: Int
}

private struct MergeMinHeap {
  private var values: [MergeCandidate] = []

  mutating func push(_ value: MergeCandidate) {
    values.append(value)
    siftUp(from: values.index(before: values.endIndex))
  }

  mutating func pop() -> MergeCandidate? {
    guard !values.isEmpty else { return nil }
    if values.count == 1 { return values.removeLast() }
    let result = values[0]
    values[0] = values.removeLast()
    siftDown(from: 0)
    return result
  }

  private func precedes(_ lhs: MergeCandidate, _ rhs: MergeCandidate) -> Bool {
    lhs.rank < rhs.rank || (lhs.rank == rhs.rank && lhs.left < rhs.left)
  }

  private mutating func siftUp(from index: Int) {
    var child = index
    while child > 0 {
      let parent = (child - 1) / 2
      guard precedes(values[child], values[parent]) else { break }
      values.swapAt(child, parent)
      child = parent
    }
  }

  private mutating func siftDown(from index: Int) {
    var parent = index
    while true {
      let left = parent * 2 + 1
      guard left < values.count else { return }
      var best = left
      let right = left + 1
      if right < values.count, precedes(values[right], values[left]) {
        best = right
      }
      guard precedes(values[best], values[parent]) else { return }
      values.swapAt(parent, best)
      parent = best
    }
  }
}

private final class Vocabulary: @unchecked Sendable {
  let ranks: [Data: Int]
  let pattern: NSRegularExpression?

  init?(data: Data, encoding: LocalBPETokenizer.Encoding) {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var ranks: [Data: Int] = [:]
    ranks.reserveCapacity(encoding == .o200kBase ? 200_000 : 100_000)

    for line in text.split(whereSeparator: \.isNewline) {
      guard let separator = line.firstIndex(of: " ") else { continue }
      let encoded = line[..<separator]
      let rankText = line[line.index(after: separator)...]
      guard let bytes = Data(base64Encoded: String(encoded)),
        let rank = Int(rankText)
      else { continue }
      ranks[bytes] = rank
    }
    let expectedRankCount = encoding == .o200kBase ? 199_998 : 100_256
    guard ranks.count == expectedRankCount else { return nil }
    for byte in UInt8.min...UInt8.max {
      guard ranks[Data([byte])] != nil else { return nil }
    }

    let patternText: String
    switch encoding {
    case .cl100kBase:
      patternText =
        "'(?i:[sdmt]|ll|ve|re)|[^\\r\\n\\p{L}\\p{N}]?+\\p{L}++|\\p{N}{1,3}+| ?[^\\s\\p{L}\\p{N}]++[\\r\\n]*+|\\s++$|\\s*[\\r\\n]|\\s+(?!\\S)|\\s"
    case .o200kBase:
      patternText =
        "[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]*[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\\r\\n\\p{L}\\p{N}]?[\\p{Lu}\\p{Lt}\\p{Lm}\\p{Lo}\\p{M}]+[\\p{Ll}\\p{Lm}\\p{Lo}\\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n/]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
    }
    guard let pattern = try? NSRegularExpression(pattern: patternText) else { return nil }

    self.ranks = ranks
    self.pattern = pattern
  }
}

private final class VocabularyCache: @unchecked Sendable {
  private enum Entry {
    case loaded(Vocabulary)
    case missing
  }

  static let shared = VocabularyCache()

  private let lock = NSLock()
  private var values: [String: Entry] = [:]

  func vocabulary(
    for encoding: LocalBPETokenizer.Encoding,
    resourceURL: URL?
  ) -> Vocabulary? {
    if let resourceURL {
      return load(encoding: encoding, resourceURL: resourceURL)
    }

    let key = encoding.rawValue
    lock.lock()
    if let cached = values[key] {
      lock.unlock()
      if case .loaded(let vocabulary) = cached { return vocabulary }
      return nil
    }
    lock.unlock()

    // SwiftPM's `.process("Resources")` currently flattens this directory in
    // the built bundle, while source/resource inspection tools may preserve
    // `Tokenizers/`. Accept both layouts so the app and focused tests use the
    // same exact vocabulary.
    let loaded = (
      Bundle.module.url(
        forResource: encoding.rawValue,
        withExtension: "tiktoken",
        subdirectory: "Tokenizers"
      )
      ?? Bundle.module.url(
        forResource: encoding.rawValue,
        withExtension: "tiktoken"
      )
    )
      .flatMap { load(encoding: encoding, resourceURL: $0) }

    lock.lock()
    values[key] = loaded.map(Entry.loaded) ?? .missing
    lock.unlock()
    return loaded
  }

  private func load(
    encoding: LocalBPETokenizer.Encoding,
    resourceURL: URL
  ) -> Vocabulary? {
    guard let data = try? Data(contentsOf: resourceURL) else { return nil }
    return Vocabulary(data: data, encoding: encoding)
  }
}
