import PublishingAICore
import XCTest

@testable import PublishingWorkbenchCore

final class AIChatRequestTokenBudgetIntegrationTests: XCTestCase {
  func testNormalizationFailsClosedWhenAtomicSchemaCannotFit() throws {
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "private-small-model",
      requiresAPIKey: false
    )
    let oversizedTool = AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: "oversized",
        description: String(repeating: "不可删除的工具协议定义。", count: 2_000),
        parameters: .object(["value": .string("string")])
      )
    )

    XCTAssertThrowsError(
      try AIChatCompletionClient().prepareRequest(
        AIChatCompletionRequest(
          model: config.model,
          messages: [AIChatMessage(role: "user", content: "执行工具")],
          tools: [oversizedTool]
        ),
        config: config,
        purpose: .capabilityProbe,
        mode: .nonStreaming
      )
    ) { error in
      XCTAssertEqual(
        error as? AIChatCompletionClientError,
        .requestContextWindowExceeded(contextWindow: 8_192)
      )
    }
  }
}
