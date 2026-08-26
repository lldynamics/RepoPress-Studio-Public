import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class AIChatInspectorHeaderPresentationTests: XCTestCase {
  func testAgentToolAvailabilityExplainsEveryFailClosedLayer() {
    var enabledCodex = AIProviderConfig(preset: .codexAppServer)
    enabledCodex.applyPresetDefaults()

    XCTAssertEqual(
      AIChatAgentToolAvailabilityPresentation.availability(
        config: enabledCodex,
        conversationMode: .inheritConnection
      ),
      .available
    )
    XCTAssertEqual(
      AIChatAgentToolAvailabilityPresentation.availability(
        config: enabledCodex,
        conversationMode: .textOnly
      ),
      .conversationTextOnly
    )

    var connectionDisabled = enabledCodex
    connectionDisabled.advancedSettings = AIProviderAdvancedSettings(
      allowsApplicationTools: false
    )
    XCTAssertEqual(
      AIChatAgentToolAvailabilityPresentation.availability(
        config: connectionDisabled,
        conversationMode: .inheritConnection
      ),
      .connectionDisabled
    )

    var draftCreationDenied = enabledCodex
    draftCreationDenied.advancedSettings = AIProviderAdvancedSettings(
      allowsApplicationTools: true,
      agentPermissionPolicy: AIAgentPermissionPolicy(enabledScopes: [.localRead])
    )
    XCTAssertEqual(
      AIChatAgentToolAvailabilityPresentation.availability(
        config: draftCreationDenied,
        conversationMode: .inheritConnection
      ),
      .draftCreationDenied
    )

    let unknownCustom = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "unknown-tools",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(allowsApplicationTools: true)
    )
    XCTAssertEqual(
      AIChatAgentToolAvailabilityPresentation.availability(
        config: unknownCustom,
        conversationMode: .inheritConnection
      ),
      .capabilityUnknown
    )
    XCTAssertEqual(
      AIChatAgentToolAvailabilityPresentation.availability(
        config: unknownCustom,
        conversationMode: .inheritConnection
      ).actionTitle,
      "打开 AI 设置"
    )

    var unsupportedCustom = unknownCustom
    let now = Date()
    let key = AIProviderCapabilityCacheKey(config: unsupportedCustom)
    unsupportedCustom.capabilityProbeEvidence = [
      .toolCalling: AIProviderCapabilityProbeEvidence(
        key: key,
        capability: .toolCalling,
        outcome: .unsupported,
        observedAt: now,
        expiresAt: now.addingTimeInterval(60)
      )
    ]
    XCTAssertEqual(
      AIChatAgentToolAvailabilityPresentation.availability(
        config: unsupportedCustom,
        conversationMode: .inheritConnection
      ),
      .capabilityUnsupported
    )
  }

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

  func testSiteContextSummaryNamesTheCurrentArticleAndDefaultWorkbenchContext() {
    let summary = AIChatInspectorHeaderPresentation.contextSummary(
      mode: .site,
      draftTitle: "  发布方案  ",
      selectedReferences: []
    )

    XCTAssertEqual(summary.title, "当前文章")
    XCTAssertEqual(summary.detail, "正在使用：发布方案；默认包含站点和发布工作台上下文。")
  }

  func testContextSummaryShowsExplicitReferencesWhenSelected() {
    let reference = AIContextReference.currentSelection(
      draftID: UUID(),
      range: NSRange(location: 0, length: 12),
      characterCount: 12
    )

    let summary = AIChatInspectorHeaderPresentation.contextSummary(
      mode: .site,
      draftTitle: "发布方案",
      selectedReferences: [reference]
    )

    XCTAssertEqual(summary.title, "当前文章")
    XCTAssertTrue(summary.detail.contains("当前选区"))
    XCTAssertTrue(summary.detail.contains("12"))
  }

  func testGeneralContextSummaryMakesArticleBoundaryExplicit() {
    let summary = AIChatInspectorHeaderPresentation.contextSummary(
      mode: .general,
      draftTitle: "发布方案",
      selectedReferences: []
    )

    XCTAssertEqual(summary.title, "通用聊天")
    XCTAssertEqual(summary.detail, "不读取当前文章正文、仓库状态或发布检查。")
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

  func testCodexProviderHidesInternalTransportSentinels() {
    var config = AIProviderConfig(preset: .codexAppServer)
    config.applyPresetDefaults()

    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.modelSummary(
        for: config,
        activeModel: AIProviderPreset.codexDefaultModel
      ),
      config.preset.localizedDisplayName + " · " + String(localized: "账户默认模型")
    )
    XCTAssertEqual(
      AIChatConnectionStatusPresentation.shortProviderName(for: config),
      "Codex"
    )
    XCTAssertTrue(
      AIChatConnectionStatusPresentation.readiness(
        for: config,
        hasToken: false,
        hasDraft: true
      ).isReady
    )
  }

  func testCodexProviderShowsConcreteActiveModelInCompactHeader() {
    var config = AIProviderConfig(preset: .codexAppServer)
    config.applyPresetDefaults()

    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.modelSummary(
        for: config,
        activeModel: "gpt-5-codex"
      ),
      config.preset.localizedDisplayName + " · gpt-5-codex"
    )
    XCTAssertEqual(
      AIChatInspectorHeaderPresentation.modelSummary(
        for: config,
        activeModel: nil
      ),
      config.preset.localizedDisplayName
    )
  }

  func testQuickSwitchSheetBuildsFastStandardAndHighQualityCandidates() {
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

  func testQuickSwitchSheetShowsCustomModelInputOnlyForEditableSelection() {
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
