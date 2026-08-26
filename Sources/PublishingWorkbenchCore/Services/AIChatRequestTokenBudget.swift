import Foundation
import PublishingAICore
import PublishingCoreSupport

/// A bounded, local request-context planner.  It deliberately owns no
/// provider state: model context windows are a conservative local table and
/// callers may override one when a provider has advertised a different limit.
public struct AIChatRequestTokenBudget: Sendable {
  public static let unknownModelContextWindow = 8_192
  public static let defaultSafetyMargin = 128

  public let model: String
  public let contextWindow: Int
  public let safetyMargin: Int
  public let tokenizer: LocalBPETokenizer

  public var promptTokenLimit: Int {
    max(1, contextWindow - safetyMargin)
  }

  public init(
    model: String,
    contextWindow: Int? = nil,
    safetyMargin: Int = Self.defaultSafetyMargin,
    tokenizer: LocalBPETokenizer? = nil
  ) {
    self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    self.contextWindow = max(1, contextWindow ?? Self.contextWindow(forModel: model))
    self.safetyMargin = min(max(0, safetyMargin), max(0, self.contextWindow - 1))
    self.tokenizer = tokenizer ?? LocalBPETokenizer(model: model)
  }

  /// The table intentionally chooses the smaller common limit for ambiguous
  /// provider aliases.  Unknown models use 8k, so a request is compacted
  /// before a small/local endpoint can reject it with a context-window error.
  public static func contextWindow(forModel model: String) -> Int {
    let value = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { return unknownModelContextWindow }

    if value.contains("claude") {
      return 200_000
    }
    if value.contains("gemini") {
      return 1_000_000
    }
    if value.contains("deepseek") {
      return 64_000
    }
    if value.contains("moonshot") || value.contains("kimi") {
      return 32_000
    }
    if value.contains("gpt-4o") || value.contains("gpt-4.1") || value.contains("gpt-5")
      || value.hasPrefix("o1") || value.hasPrefix("o3") || value.hasPrefix("o4")
      || value.contains("codex")
    {
      return 128_000
    }
    if value.contains("gpt-4") || value.contains("gpt-3.5") {
      return 16_384
    }
    if value.contains("llama") || value.contains("mistral") || value.contains("qwen") {
      return 8_192
    }
    return unknownModelContextWindow
  }

  public static func contextWindow(for model: String) -> Int {
    contextWindow(forModel: model)
  }

  public struct Result: Sendable {
    public let messages: [AIChatMessage]
    public let promptTokenCount: Int
    public let outputTokenBudget: Int
    public let contextWindow: Int
    public let safetyMargin: Int
    public let didTrim: Bool
    public let tokenizerPrecision: LocalBPETokenizer.Precision

    public var fitsContextWindow: Bool {
      promptTokenCount + outputTokenBudget + safetyMargin <= contextWindow
    }
  }

  /// Compacts messages before they are encoded or sent.  The first system
  /// instruction and the latest user message are mandatory; older turns are
  /// admitted newest-first and then restored to their original order.  Other
  /// system messages (normally explicit/knowledge context) are retained when
  /// possible and clipped at paragraph boundaries before history is dropped.
  public func fit(
    messages: [AIChatMessage],
    requestedOutputTokens: Int? = nil,
    additionalPromptTokens: Int = 0
  ) -> Result {
    let outputBudget = resolvedOutputBudget(requestedOutputTokens)
    let promptLimit = max(
      1,
      contextWindow - safetyMargin - outputBudget - max(0, additionalPromptTokens)
    )
    guard !messages.isEmpty else {
      return Result(
        messages: [],
        promptTokenCount: max(0, additionalPromptTokens),
        outputTokenBudget: max(
          1,
          min(outputBudget, max(1, contextWindow - safetyMargin - max(0, additionalPromptTokens)))
        ),
        contextWindow: contextWindow,
        safetyMargin: safetyMargin,
        didTrim: false,
        tokenizerPrecision: tokenizer.precision
      )
    }

    let firstSystemIndex = messages.firstIndex { $0.role.lowercased() == "system" }
    let latestUserIndex = messages.lastIndex { $0.role.lowercased() == "user" }

    var selected: [Int: AIChatMessage] = [:]
    var used = 0

    // Allocate the two mandatory messages first. If their full text cannot
    // fit, split the remaining prompt budget so neither message disappears.
    if let firstSystemIndex {
      let first = messages[firstSystemIndex]
      let fullCost = messageTokenCount(first)
      let reserveForLatest = latestUserIndex == nil ? 0 : minimumMessageTokens
      let allowance = max(minimumMessageTokens, promptLimit - reserveForLatest)
      let fitted = fullCost <= allowance
        ? first
        : clippedMessage(first, maximumTokens: allowance)
      selected[firstSystemIndex] = fitted
      used += messageTokenCount(fitted)
    }

    if let latestUserIndex, latestUserIndex != firstSystemIndex {
      let latest = messages[latestUserIndex]
      let allowance = max(
        minimumMessageTokens,
        promptLimit - used
      )
      let fitted = messageTokenCount(latest) <= allowance
        ? latest
        : clippedMessage(latest, maximumTokens: allowance)
      selected[latestUserIndex] = fitted
      used += messageTokenCount(fitted)
    }

    // Put explicit/knowledge system context ahead of old conversation turns.
    // A context message can be reduced to its head and tail at paragraph
    // boundaries, preserving source labels and the newest citation material.
    let contextIndexes = messages.indices.filter { index in
      index != firstSystemIndex
        && index != latestUserIndex
        && messages[index].role.lowercased() == "system"
    }
    for index in contextIndexes {
      let remaining = promptLimit - used
      guard remaining >= minimumMessageTokens else { break }
      let message = messages[index]
      let cost = messageTokenCount(message)
      let fitted = cost <= remaining
        ? message
        : clippedMessage(message, maximumTokens: remaining)
      guard messageTokenCount(fitted) > messageOverhead else { continue }
      selected[index] = fitted
      used += messageTokenCount(fitted)
    }

    // Sliding window: newest turns win, but output remains in source order.
    for index in messages.indices.reversed() {
      guard selected[index] == nil else { continue }
      let remaining = promptLimit - used
      guard remaining >= minimumMessageTokens else { break }
      let group = protocolGroup(containing: index, in: messages)
      guard group.allSatisfy({ selected[$0] == nil }) else { continue }
      let groupCost = group.reduce(0) { $0 + messageTokenCount(messages[$1]) }
      guard groupCost <= remaining else { continue }
      for groupIndex in group {
        selected[groupIndex] = messages[groupIndex]
      }
      used += groupCost
    }

    // If a large context consumed the allowance needed by the latest user
    // turn, restore that mandatory turn by evicting optional messages from
    // oldest to newest. This also handles very small injected test windows.
    if let latestUserIndex, selected[latestUserIndex] == nil {
      var remaining = promptLimit
      let mandatorySystem = firstSystemIndex.flatMap { selected[$0] }
      if let mandatorySystem {
        remaining -= messageTokenCount(mandatorySystem)
      }
      let fitted = clippedMessage(messages[latestUserIndex], maximumTokens: max(
        minimumMessageTokens,
        remaining
      ))
      for index in selected.keys.sorted() where index != firstSystemIndex {
        selected.removeValue(forKey: index)
      }
      selected[latestUserIndex] = fitted
    }

    let boundedMessages = selected.keys.sorted().compactMap { selected[$0] }
    let promptTokenCount = boundedMessages.reduce(0) { $0 + messageTokenCount($1) }
      + max(0, additionalPromptTokens)
    let didModifyMessage = selected.contains { index, message in
      message != messages[index]
    }
    let didTrim = boundedMessages.count != messages.count
      || didModifyMessage
      || promptTokenCount + outputBudget + safetyMargin > contextWindow

    // A conservative token limit is the final invariant. The clipping logic
    // above works in whole messages first; this last pass handles a mandatory
    // system/user pair whose overhead alone exceeds a tiny test window.
    let finalMessages: [AIChatMessage]
    if promptTokenCount <= promptLimit + max(0, additionalPromptTokens) {
      finalMessages = boundedMessages
    } else {
      finalMessages = finalClip(
        boundedMessages,
        maximumTokens: promptLimit
      )
    }
    let finalPromptTokenCount = finalMessages.reduce(0) { $0 + messageTokenCount($1) }
      + max(0, additionalPromptTokens)
    let finalOutputBudget = max(
      1,
      min(
        outputBudget,
        contextWindow - safetyMargin - min(finalPromptTokenCount, contextWindow - safetyMargin - 1)
      )
    )

    return Result(
      messages: finalMessages,
      promptTokenCount: finalPromptTokenCount,
      outputTokenBudget: finalOutputBudget,
      contextWindow: contextWindow,
      safetyMargin: safetyMargin,
      didTrim: didTrim || finalMessages.count != messages.count,
      tokenizerPrecision: tokenizer.precision
    )
  }

  public func tokenCount(of messages: [AIChatMessage]) -> Int {
    messages.reduce(0) { $0 + messageTokenCount($1) }
  }

  /// Clips one text value with the same tokenizer and paragraph-aware policy
  /// used by request compaction. Continuation checkpoints use this before they
  /// become mandatory protocol messages.
  public func fitText(_ text: String, maximumTokens: Int) -> String {
    clipText(text, maximumTokens: maximumTokens)
  }

  /// Fits a continuation checkpoint while preserving the newest incomplete
  /// sentence at the end rather than the older head of the checkpoint.
  public func fitTextSuffix(_ text: String, maximumTokens: Int) -> String {
    guard !text.isEmpty, maximumTokens > 0 else { return "" }
    guard tokenizer.tokenCount(text) > maximumTokens else { return text }

    let scalars = Array(text.unicodeScalars)
    let marker = "…"
    var low = 0
    var high = scalars.count
    var best = ""
    while low <= high {
      let middle = (low + high) / 2
      let suffix = String(String.UnicodeScalarView(scalars.suffix(middle)))
      let candidate = marker + suffix
      if tokenizer.tokenCount(candidate) <= maximumTokens {
        best = candidate
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return best
  }

  /// Estimates provider-side schema overhead without serializing credentials
  /// or sending anything. JSON encoding is intentionally local and bounded by
  /// the caller's own tool/response-format values.
  public func additionalPromptTokens(
    tools: [AIToolDefinition]?,
    responseFormat: AIStructuredOutputFormat?,
    toolChoice: AIToolChoice? = nil
  ) -> Int {
    let encoder = JSONEncoder()
    var tokenCount = 0
    if let tools, let data = try? encoder.encode(tools) {
      tokenCount += tokenizer.tokenCount(String(decoding: data, as: UTF8.self))
    }
    if let responseFormat, let data = try? encoder.encode(responseFormat) {
      tokenCount += tokenizer.tokenCount(String(decoding: data, as: UTF8.self))
    }
    if let toolChoice, let data = try? encoder.encode(toolChoice) {
      tokenCount += tokenizer.tokenCount(String(decoding: data, as: UTF8.self))
    }
    return tokenCount
  }

  // MARK: - Counting and clipping

  private let messageOverhead = 4
  private let minimumMessageTokens = 5

  private func resolvedOutputBudget(_ requested: Int?) -> Int {
    let fallback = min(2_048, max(256, contextWindow / 8))
    return max(1, min(requested ?? fallback, max(1, contextWindow - safetyMargin - 1)))
  }

  private func messageTokenCount(_ message: AIChatMessage) -> Int {
    var count = messageOverhead + tokenizer.tokenCount(message.role)
    switch message.content {
    case .none:
      break
    case .text(let text):
      count += tokenizer.tokenCount(text)
    case .parts(let parts):
      for part in parts {
        switch part.type {
        case .text:
          count += tokenizer.tokenCount(part.text ?? "")
        case .imageURL:
          // Image payload tokens are provider-specific. This deliberately
          // over-approximates them so an image cannot consume the output
          // reserve unnoticed.
          count += 1_536
        }
      }
    }
    if let toolCalls = message.toolCalls {
      count += toolCalls.count * 128
    }
    if let toolCallID = message.toolCallID {
      count += tokenizer.tokenCount(toolCallID)
    }
    return count
  }

  /// Tool-call messages form one protocol transaction. Selecting one without
  /// its matching `tool` result can make an otherwise bounded request invalid,
  /// so history admission always handles the transaction atomically.
  private func protocolGroup(
    containing index: Int,
    in messages: [AIChatMessage]
  ) -> [Int] {
    let message = messages[index]
    var result: Set<Int> = [index]
    if let toolCallID = message.toolCallID?.nilIfEmpty {
      for candidate in messages.indices where candidate < index {
        guard let calls = messages[candidate].toolCalls else { continue }
        if calls.contains(where: { $0.id == toolCallID }) {
          result.insert(candidate)
        }
      }
    }
    if let calls = message.toolCalls, !calls.isEmpty {
      let callIDs = Set(calls.map(\.id))
      for candidate in messages.indices where candidate > index {
        guard messages[candidate].role.lowercased() == "tool",
          let toolCallID = messages[candidate].toolCallID,
          callIDs.contains(toolCallID)
        else { continue }
        result.insert(candidate)
      }
    }
    return result.sorted()
  }

  private func clippedMessage(
    _ message: AIChatMessage,
    maximumTokens: Int
  ) -> AIChatMessage {
    var clipped = message
    let imageAllowance = message.contentParts.reduce(0) { partial, part in
      partial + (part.type == .imageURL ? 1_536 : 0)
    }
    let toolAllowance = (message.toolCalls?.count ?? 0) * 128
      + (message.toolCallID.map { tokenizer.tokenCount($0) } ?? 0)
    let contentLimit = max(
      1,
      maximumTokens
        - messageOverhead
        - tokenizer.tokenCount(message.role)
        - imageAllowance
        - toolAllowance
    )
    switch message.content {
    case .text(let text):
      clipped.content = .text(clipText(text, maximumTokens: contentLimit))
    case .parts(let parts):
      let text = parts.compactMap { $0.type == .text ? $0.text : nil }.joined()
      let boundedText = clipText(text, maximumTokens: contentLimit)
      let imageParts = parts.filter { $0.type == .imageURL }
      var boundedParts: [AIChatMessageContentPart] = []
      if !boundedText.isEmpty {
        boundedParts.append(.text(boundedText))
      }
      boundedParts.append(contentsOf: imageParts)
      clipped.content = boundedParts.isEmpty ? nil : .parts(boundedParts)
    case .none:
      break
    }
    // Tool calls and image parts are atomic protocol material. They are kept
    // intact while ordinary text is clipped; optional history containing them
    // is admitted only as a whole message by the sliding-window pass.
    return clipped
  }

  private func finalClip(
    _ messages: [AIChatMessage],
    maximumTokens: Int
  ) -> [AIChatMessage] {
    guard !messages.isEmpty else { return [] }
    var result: [AIChatMessage] = []
    var used = 0
    var index = 0
    while index < messages.count {
      let message = messages[index]
      let remaining = maximumTokens - used
      guard remaining >= minimumMessageTokens else { break }
      let group = protocolGroup(containing: index, in: messages)
      if group.count > 1 {
        let groupCost = group.reduce(0) { $0 + messageTokenCount(messages[$1]) }
        if groupCost <= remaining {
          result.append(contentsOf: group.map { messages[$0] })
          used += groupCost
        }
        index = (group.last ?? index) + 1
        continue
      }
      let isMandatory = index == 0 || message.role.lowercased() == "user"
        && index == messages.lastIndex(where: { $0.role.lowercased() == "user" })
      let candidate = isMandatory || messageTokenCount(message) > remaining
        ? clippedMessage(message, maximumTokens: remaining)
        : message
      let cost = messageTokenCount(candidate)
      guard cost <= remaining, cost > messageOverhead else {
        index += 1
        continue
      }
      result.append(candidate)
      used += cost
      index += 1
    }
    return result
  }

  private func clipText(_ text: String, maximumTokens: Int) -> String {
    guard !text.isEmpty, maximumTokens > 0 else { return "" }
    guard tokenizer.tokenCount(text) > maximumTokens else { return text }

    let paragraphs = text
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let marker = "\n…\n"
    if paragraphs.count >= 2 {
      var head = paragraphs[0]
      var tail = paragraphs[paragraphs.count - 1]
      var candidate = head + marker + tail
      while tokenizer.tokenCount(candidate) > maximumTokens {
        if tokenizer.tokenCount(head) >= tokenizer.tokenCount(tail), head.count > 1 {
          head = String(head.dropLast(max(1, head.count / 8)))
        } else if tail.count > 1 {
          tail = String(tail.dropFirst(max(1, tail.count / 8)))
        } else {
          break
        }
        candidate = head + marker + tail
      }
      if tokenizer.tokenCount(candidate) <= maximumTokens {
        return candidate
      }
    }

    // One oversized paragraph has no safe paragraph boundary. Binary search
    // Unicode scalar boundaries, then keep both ends with an explicit marker.
    let scalars = Array(text.unicodeScalars)
    var low = 0
    var high = scalars.count
    var best = ""
    while low <= high {
      let middle = (low + high) / 2
      let prefix = String(String.UnicodeScalarView(scalars.prefix(middle)))
      if tokenizer.tokenCount(prefix) <= maximumTokens {
        best = prefix
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    if best.isEmpty { return String(text.prefix(1)) }
    return best
  }
}

private extension AIChatMessage {
  var contentParts: [AIChatMessageContentPart] {
    guard case .parts(let parts)? = content else { return [] }
    return parts
  }
}
