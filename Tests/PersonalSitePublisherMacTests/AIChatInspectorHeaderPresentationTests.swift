import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class AIChatInspectorHeaderPresentationTests: XCTestCase {
  func testConversationTitleUsesTrimmedTitleOrNewConversationFallback() {
    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.conversationTitle("  发布方案讨论  "),
      "发布方案讨论"
    )
    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.conversationTitle(" \n "),
      "新对话"
    )
    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.conversationTitle(nil),
      "新对话"
    )
  }

  func testSiteContextUsesCurrentArticleAsCompactTitle() {
    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.contextTitle(for: .site),
      "当前文章"
    )
    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.contextTitle(for: .general),
      "通用聊天"
    )
  }

  func testCustomProviderUsesFriendlyCustomAPITitle() {
    let custom = AIProviderConfig(preset: .custom)

    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.providerTitle(for: custom),
      "自定义 API"
    )
  }

  func testModelSummaryKeepsFullModelOutsideCompactHeader() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "custom-review-model"
    )

    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.modelSummary(
        for: config,
        activeModel: "custom-review-model"
      ),
      "自定义 API · custom-review-model"
    )
  }

  func testModelPopoverBuildsFastStandardAndHighQualityCandidates() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "custom-model"
    )

    let candidates = AIChatInspectorHeaderPresentation.modelGradeCandidates(
      for: config,
      currentModel: "custom-review-model"
    )

    XCTAssertEqual(candidates.map(\.grade), [.fast, .standard, .highQuality])
    XCTAssertEqual(candidates.map(\.title), ["快速", "标准", "高质量"])
  }

  func testCustomModelInputOnlyAppearsForEditableSelection() {
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "site-default"
    )
    let standard = AIChatModelSelectionPresentationService.presentation(
      grade: .standard,
      selectedModel: "custom-review-model",
      config: config
    )
    let custom = AIChatModelSelectionPresentationService.presentation(
      grade: .custom,
      selectedModel: "custom-review-model",
      config: config
    )

    XCTAssertFalse(
      AIChatInspectorHeaderPresentation.showsCustomModelInput(selection: standard)
    )
    XCTAssertTrue(
      AIChatInspectorHeaderPresentation.showsCustomModelInput(selection: custom)
    )
    XCTAssertFalse(
      AIChatInspectorHeaderPresentation.showsCustomModelInput(selection: nil)
    )
  }

  func testReasoningControlOnlyAppearsForSupportedProviderAndDraft() {
    let custom = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "custom-model"
    )

    XCTAssertFalse(
      AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
        config: custom,
        hasDraft: true
      )
    )
    XCTAssertFalse(
      AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
        config: custom,
        hasDraft: false
      )
    )

    let deepSeek = AIProviderConfig(preset: .deepSeek)
    XCTAssertTrue(
      AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
        config: deepSeek,
        hasDraft: true
      )
    )
    XCTAssertFalse(
      AIChatInspectorHeaderPresentation.supportsSelectableReasoningLevel(
        config: deepSeek,
        hasDraft: false
      )
    )
  }

  func testConnectionStatusTurnsYellowWhenEndpointIsMissing() {
    let missingEndpoint = AIProviderConfig(
      preset: .custom,
      baseURL: "",
      model: "custom-model"
    )
    let configuredLocal = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "qwen2.5",
      requiresAPIKey: false
    )
    let customEndpointWithSelectedModel = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: ""
    )

    XCTAssertEqual(
      AIChatConnectionStatusPresentation.readiness(
        for: missingEndpoint,
        hasToken: false,
        hasDraft: true
      ),
      .missingEndpoint
    )
    XCTAssertEqual(
      AIChatConnectionStatusPresentation.summary(
        for: configuredLocal,
        activeModel: "qwen2.5",
        hasDraft: true
      ),
      "Local: qwen2.5"
    )
    XCTAssertTrue(
      AIChatConnectionStatusPresentation.readiness(
        for: configuredLocal,
        hasToken: false,
        hasDraft: true
      ).isReady
    )
    XCTAssertTrue(
      AIChatConnectionStatusPresentation.readiness(
        for: customEndpointWithSelectedModel,
        activeModel: "custom-review-model",
        hasToken: true,
        hasDraft: true
      ).isReady
    )
  }
}
