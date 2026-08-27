import PublishingCoreSupport
import XCTest

@testable import PublishingAICore

final class AIChatRequestTokenBudgetTests: XCTestCase {
  func testSlidingWindowKeepsFirstSystemAndLatestUser() {
    let budget = AIChatRequestTokenBudget(
      model: "gpt-4o-mini",
      contextWindow: 1_000,
      safetyMargin: 16,
      tokenizer: LocalBPETokenizer(encoding: .o200kBase)
    )
    var messages = [AIChatMessage(role: "system", content: "首个系统指令必须保留。")]
    messages.append(
      AIChatMessage(
        role: "system",
        content: "知识片段起点：保留资料来源。\n\n" + String(repeating: "知识正文。", count: 400)
      )
    )
    for index in 0..<18 {
      messages.append(
        AIChatMessage(
          role: "user", content: "旧消息 \(index)：" + String(repeating: "历史内容。", count: 30)))
      messages.append(
        AIChatMessage(
          role: "assistant", content: "旧回复 \(index)：" + String(repeating: "回答内容。", count: 30)))
    }
    messages.append(AIChatMessage(role: "user", content: "最新用户问题：请保留这一句。"))

    let result = budget.fit(messages: messages, requestedOutputTokens: 160)
    XCTAssertTrue(result.didTrim)
    XCTAssertEqual(result.messages.first?.role, "system")
    XCTAssertTrue(result.messages.first?.contentText.contains("首个系统指令") == true)
    XCTAssertTrue(result.messages.contains { $0.contentText.contains("最新用户问题") })
    XCTAssertFalse(result.messages.contains { $0.contentText.contains("旧消息 0") })
    XCTAssertLessThanOrEqual(
      result.promptTokenCount + result.outputTokenBudget + result.safetyMargin,
      result.contextWindow
    )
  }

  func testKnowledgeAndExplicitContextClipAtParagraphHeadAndTail() {
    let budget = AIChatRequestTokenBudget(
      model: "unknown-private-model",
      contextWindow: 360,
      safetyMargin: 8,
      tokenizer: LocalBPETokenizer(model: "unknown-private-model")
    )
    let context =
      "资料标题与来源\n\n" + String(repeating: "中间正文。", count: 500)
      + "\n\n资料末尾引用编号 [K9]。"
    let result = budget.fit(
      messages: [
        AIChatMessage(role: "system", content: "系统规则"),
        AIChatMessage(role: "system", content: context),
        AIChatMessage(role: "user", content: "最新问题"),
      ],
      requestedOutputTokens: 64
    )
    let contextMessage = result.messages.first { $0.contentText.contains("资料标题") }
    XCTAssertNotNil(contextMessage)
    XCTAssertTrue(contextMessage?.contentText.contains("[K9]") == true)
    XCTAssertTrue(result.fitsContextWindow)
  }

  func testSchemaTokensConsumeBudgetAndOutputIsClamped() {
    let budget = AIChatRequestTokenBudget(
      model: "gpt-4o",
      contextWindow: 400,
      safetyMargin: 12,
      tokenizer: LocalBPETokenizer(encoding: .o200kBase)
    )
    let tools = [
      AIToolDefinition(
        function: AIToolFunctionDefinition(
          name: "search",
          description: "Search local knowledge",
          parameters: .object(["query": .string("string")])
        )
      )
    ]
    let schemaTokens = budget.additionalPromptTokens(
      tools: tools,
      responseFormat: .jsonObject,
      toolChoice: .auto
    )
    XCTAssertGreaterThan(schemaTokens, 0)
    let result = budget.fit(
      messages: [
        AIChatMessage(role: "system", content: "规则"),
        AIChatMessage(role: "user", content: "请回答"),
      ],
      requestedOutputTokens: 2_000,
      additionalPromptTokens: schemaTokens
    )
    XCTAssertTrue(result.fitsContextWindow)
    XCTAssertLessThan(result.outputTokenBudget, 2_000)
  }

  func testUnknownModelUsesConservativeWindow() {
    XCTAssertEqual(
      AIChatRequestTokenBudget.contextWindow(forModel: "vendor-secret-model"),
      AIChatRequestTokenBudget.unknownModelContextWindow
    )
    XCTAssertEqual(AIChatRequestTokenBudget.contextWindow(forModel: "gpt-5.1"), 128_000)
    XCTAssertEqual(LocalBPETokenizer.encoding(forModel: "gpt-5.1"), .o200kBase)
  }

  func testFormattedContextWindowAndTokenCount() {
    XCTAssertEqual(
      AIChatRequestTokenBudget.formattedContextWindow(forModel: "claude-3-5-sonnet"), "200k")
    XCTAssertEqual(
      AIChatRequestTokenBudget.formattedContextWindow(forModel: "gemini-1.5-pro"), "1M")
    XCTAssertEqual(AIChatRequestTokenBudget.formattedContextWindow(forModel: "gpt-4o"), "128k")
    XCTAssertEqual(
      AIChatRequestTokenBudget.formattedContextWindow(forModel: "deepseek-chat"), "64k")
    XCTAssertEqual(
      AIChatRequestTokenBudget.formattedContextWindow(forModel: "moonshot-v1-32k"), "32k")
    XCTAssertEqual(AIChatRequestTokenBudget.formattedContextWindow(forModel: "gpt-4-0613"), "16k")
    XCTAssertEqual(AIChatRequestTokenBudget.formattedContextWindow(forModel: "llama-3-8b"), "8k")
    XCTAssertEqual(
      AIChatRequestTokenBudget.formattedContextWindow(forModel: "custom-model-128k"), "128k")
    XCTAssertEqual(AIChatRequestTokenBudget.formatTokenCount(1_000_000), "1M")
    XCTAssertEqual(AIChatRequestTokenBudget.formatTokenCount(128_000), "128k")
    XCTAssertEqual(AIChatRequestTokenBudget.formatTokenCount(8_192), "8k")
  }

  func testToolCallAndToolResultAreRetainedOrDroppedAsAGroup() {
    let call = AIToolCall(
      id: "call-1",
      function: AIToolFunctionCall(name: "search", arguments: "{\"query\":\"local\"}")
    )
    let messages = [
      AIChatMessage(role: "system", content: "规则"),
      AIChatMessage(role: "assistant", content: nil, toolCalls: [call]),
      AIChatMessage(role: "tool", content: "搜索结果", toolCallID: "call-1"),
      AIChatMessage(role: "user", content: "请总结"),
    ]
    let result = AIChatRequestTokenBudget(
      model: "gpt-4o",
      contextWindow: 200,
      safetyMargin: 8,
      tokenizer: LocalBPETokenizer(encoding: .o200kBase)
    ).fit(messages: messages, requestedOutputTokens: 64)
    let selectedCall = result.messages.contains { $0.toolCalls?.contains(call) == true }
    let selectedResult = result.messages.contains { $0.toolCallID == "call-1" }
    XCTAssertEqual(selectedCall, selectedResult)
  }

  func testContinuationCheckpointTokenClipPreservesNewestSuffix() {
    let budget = AIChatRequestTokenBudget(
      model: "gpt-4o",
      tokenizer: LocalBPETokenizer(encoding: .o200kBase)
    )
    let checkpoint = String(repeating: "较早段落。", count: 100) + "必须保留的未完成句尾"
    let fitted = budget.fitTextSuffix(checkpoint, maximumTokens: 24)

    XCTAssertLessThanOrEqual(budget.tokenizer.tokenCount(fitted), 24)
    XCTAssertTrue(fitted.hasSuffix("必须保留的未完成句尾"))
    XCTAssertTrue(fitted.hasPrefix("…"))
  }

  func testImageOnlyLatestUserMessageIsNeverCollapsedToEmptyContent() {
    let image = AIChatMessageContentPart.imageURL("https://example.com/image.png")
    let messages = [
      AIChatMessage(role: "system", content: "规则"),
      AIChatMessage(role: "user", content: .parts([image])),
    ]
    let result = AIChatRequestTokenBudget(
      model: "gpt-4o",
      contextWindow: 2_000,
      safetyMargin: 8,
      tokenizer: LocalBPETokenizer(encoding: .o200kBase)
    ).fit(messages: messages, requestedOutputTokens: 128)
    let latest = result.messages.last { $0.role == "user" }
    guard case .parts(let parts)? = latest?.content else {
      return XCTFail("latest image-only input must remain an image part")
    }
    XCTAssertEqual(parts.map(\.type), [.imageURL])
  }
}

extension AIChatMessage {
  fileprivate var contentText: String {
    switch content {
    case .none:
      return ""
    case .text(let text):
      return text
    case .parts(let parts):
      return parts.compactMap(\.text).joined()
    }
  }
}
