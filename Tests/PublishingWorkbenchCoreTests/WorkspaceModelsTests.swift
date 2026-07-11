import XCTest
@testable import PublishingWorkbenchCore

final class WorkspaceModelsTests: XCTestCase {
  func testWorkspaceSectionsExposeStableCommandNumberShortcuts() {
    XCTAssertEqual(
      WorkspaceSection.allCases.map(\.displayNameLocalizationKey),
      ["workspace.writing", "workspace.siteStarter", "workspace.sync", "workspace.images", "workspace.contentHealth", "workspace.ai", "workspace.generalDrafts", "workspace.maintenance", "workspace.releaseHistory", "workspace.releaseReadiness"]
    )
    XCTAssertEqual(WorkspaceSection.allCases.map { String($0.keyboardShortcutKey) }, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    XCTAssertEqual(WorkspaceSection.allCases.map(\.keyboardShortcutLabel), ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9", "⌘0"])
    XCTAssertEqual(
      WorkspaceSection.allCases.map(\.localizationKey),
      [
        "workspace.writing",
        "workspace.siteStarter",
        "workspace.sync",
        "workspace.images",
        "workspace.contentHealth",
        "workspace.ai",
        "workspace.generalDrafts",
        "workspace.maintenance",
        "workspace.releaseHistory",
        "workspace.releaseReadiness",
      ]
    )
    XCTAssertEqual(Set(WorkspaceSection.allCases.map(\.keyboardShortcutKey)).count, WorkspaceSection.allCases.count)
    XCTAssertEqual(
      WorkspaceSection.allCases.map(\.detailLocalizationKey),
      ["workspace.writing.detail", "workspace.siteStarter.detail", "workspace.sync.detail", "workspace.images.detail", "workspace.contentHealth.detail", "workspace.ai.detail", "workspace.generalDrafts.detail", "workspace.maintenance.detail", "workspace.releaseHistory.detail", "workspace.releaseReadiness.detail"]
    )
    XCTAssertEqual(WorkspaceSection.writing.contextSidebarMode, .writingDrafts)
    XCTAssertEqual(WorkspaceSection.contentHealth.contextSidebarMode, .contentHealthFilters)
    XCTAssertEqual(WorkspaceSection.sync.contextSidebarMode, .repositoryStages)
    XCTAssertEqual(WorkspaceSection.siteStarter.contextSidebarMode, .none)
    XCTAssertEqual(WorkspaceSection.releaseReadiness.contextSidebarMode, .none)
  }

  func testWorkspaceNavigationPresentationCentralizesSurfacePolicies() {
    XCTAssertEqual(WorkspaceNavigationPresentation.defaultSection, .writing)
    XCTAssertEqual(
      WorkspaceNavigationPresentation.topBarItems.map(\.section),
      [.sync, .images, .contentHealth, .releaseHistory]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuItems.map(\.section),
      [.writing, .sync, .images, .contentHealth, .releaseHistory]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.productReadinessSections,
      WorkspaceSection.allCases
    )
    XCTAssertEqual(
      WorkspaceVisibilityPolicy.productionRailSections,
      WorkspaceSection.allCases.filter { $0 != .releaseReadiness }
    )
    XCTAssertEqual(WorkspaceVisibilityPolicy.developerDiagnosticsSections, [.releaseReadiness])
    XCTAssertTrue(WorkspaceNavigationPresentation.sections(for: .sidebarList).isEmpty)
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuItems.map(\.keyboardShortcutLabel),
      ["⌘1", "⌘3", "⌘4", "⌘5", "⌘9"]
    )
  }

  func testSiteProfileDecodesMissingAIWritingStyleWithDefault() throws {
    let encoded = try JSONEncoder.workbench.encode(SiteProfile.defaultProfile)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "aiWritingStyle")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder.workbench.decode(SiteProfile.self, from: legacyData)

    XCTAssertEqual(decoded.resolvedAIWritingStyle.preset, .jinfangZola)
    XCTAssertTrue(decoded.aiWritingStylePromptInstructions.contains("克制、实用、直接"))
    XCTAssertTrue(decoded.aiWritingStylePromptInstructions.contains("个人网站、静态博客"))
  }

  func testAIWritingStylePresetAppliesMobileDefaults() {
    var style = AIWritingStyleConfig()

    style.applyPreset(.technicalNote)

    XCTAssertEqual(style.preset, .technicalNote)
    XCTAssertTrue(style.promptInstructions.contains("准确、结构清晰"))
    XCTAssertTrue(style.promptInstructions.contains("技术对象、关键步骤和适用边界"))
  }

  func testAIChatModelCatalogMapsDeepSeekGradesForTaskKinds() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: AIProviderPreset.deepSeek.defaultModel,
      requiresAPIKey: true
    )

    XCTAssertEqual(
      AIChatModelCatalog.config(for: .prePublishReview, baseConfig: config).normalizedRequestModel,
      "deepseek-v4-pro"
    )
    XCTAssertEqual(
      AIChatModelCatalog.config(for: .batchMetadataRepair, baseConfig: config).normalizedRequestModel,
      "deepseek-v4-flash"
    )
    XCTAssertEqual(
      AIChatModelCatalog.config(for: .textEditing, baseConfig: config).normalizedRequestModel,
      "deepseek-v4-flash"
    )
    XCTAssertEqual(AIModelTaskKind.prePublishReview.preferredGrade, .highQuality)
    XCTAssertEqual(AIModelTaskKind.batchMetadataRepair.preferredGrade, .fast)
  }

  func testAIChatModelCatalogBuildsUniqueCandidates() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: "custom-model",
      requiresAPIKey: true
    )

    XCTAssertEqual(
      AIChatModelCatalog.modelCandidates(activeModel: " custom-model ", config: config),
      ["custom-model", "deepseek-v4-flash", "deepseek-v4-pro"]
    )
  }

  func testAIChatModelSelectionPresentationMirrorsMobileModelMenu() {
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
      model: AIProviderPreset.deepSeek.defaultModel,
      requiresAPIKey: true
    )

    let standard = AIChatModelSelectionPresentationService.presentation(
      grade: .standard,
      selectedModel: "",
      config: config
    )

    XCTAssertEqual(standard.activeModel, "deepseek-v4-flash")
    XCTAssertEqual(standard.defaultModel, "deepseek-v4-flash")
    XCTAssertEqual(standard.modelCandidates, ["deepseek-v4-flash", "deepseek-v4-pro"])
    XCTAssertFalse(standard.canEditCustomModel)

    let custom = AIChatModelSelectionPresentationService.presentation(
      grade: .custom,
      selectedModel: "  custom-chat-model  ",
      config: config
    )

    XCTAssertEqual(custom.activeModel, "custom-chat-model")
    XCTAssertEqual(custom.defaultModel, "deepseek-v4-flash")
    XCTAssertEqual(custom.modelCandidates, ["custom-chat-model", "deepseek-v4-flash", "deepseek-v4-pro"])
    XCTAssertTrue(custom.canEditCustomModel)
  }

  func testAIProviderConfigMatchesMobileImageInputSupportPolicy() {
    XCTAssertFalse(
      AIProviderConfig(
        preset: .deepSeek,
        baseURL: AIProviderPreset.deepSeek.defaultBaseURL,
        model: AIProviderPreset.deepSeek.defaultModel,
        requiresAPIKey: true
      ).supportsImageInput
    )
    XCTAssertFalse(
      AIProviderConfig(
        preset: .custom,
        baseURL: "https://api.deepseek.com",
        model: "deepseek-v4-flash",
        requiresAPIKey: true
      ).supportsImageInput
    )
    XCTAssertTrue(
      AIProviderConfig(
        preset: .openAICompatible,
        baseURL: "https://api.openai.example/v1",
        model: "gpt-4.1",
        requiresAPIKey: true
      ).supportsImageInput
    )
    XCTAssertEqual(
      AIProviderConfig(preset: .openAICompatible).normalizedDisplayName,
      AIProviderPreset.openAICompatible.displayName
    )
  }

  func testRemoteRepositoryPreviewBlocksReadOnlyAccessCheck() {
    let preview = RemoteRepositoryPublishPreview(
      provider: .github,
      repositoryName: "owner/site",
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: ["content/posts/read-only.md"],
      hasToken: true,
      accessCheck: RemoteRepositoryAccessCheck(
        provider: .github,
        repositoryName: "owner/site",
        apiBaseURL: RepositoryProvider.github.defaultBaseURL,
        defaultBranch: "main",
        canRead: true,
        canWrite: false,
        message: "GitHub Token 可读取仓库，但未确认写入权限。"
      ),
      blockingIssues: [],
      warningIssues: []
    )

    XCTAssertEqual(preview.accessSummary, "Token 可读但未确认写入")
    XCTAssertEqual(preview.readiness, .blocked)
    XCTAssertFalse(preview.canPublish)
    XCTAssertTrue(preview.checklistMarkdown.contains("- 状态：已阻塞"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- 权限检查端点：https://api.github.com"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已确认 Token 对 owner/site 具备写入权限"))
  }
}
