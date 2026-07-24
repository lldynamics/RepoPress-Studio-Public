import XCTest
@testable import PublishingWorkbenchCore

final class WorkspaceModelsTests: XCTestCase {
  func testWorkspaceSectionsExposeStableCommandNumberShortcuts() {
    XCTAssertEqual(
      WorkspaceSection.allCases.map(\.displayNameLocalizationKey),
      ["workspace.writing", "workspace.library", "workspace.siteStarter", "workspace.sync", "workspace.images", "workspace.contentHealth", "workspace.maintenance", "workspace.releaseHistory"]
    )
    XCTAssertEqual(WorkspaceSection.allCases.map { String($0.keyboardShortcutKey) }, ["1", "9", "5", "2", "3", "4", "7", "8"])
    XCTAssertEqual(WorkspaceSection.allCases.map(\.keyboardShortcutLabel), ["⌘1", "⌘9", "⌘5", "⌘2", "⌘3", "⌘4", "⌘7", "⌘8"])
    XCTAssertEqual(
      WorkspaceSection.allCases.map(\.localizationKey),
      [
        "workspace.writing",
        "workspace.library",
        "workspace.siteStarter",
        "workspace.sync",
        "workspace.images",
        "workspace.contentHealth",
        "workspace.maintenance",
        "workspace.releaseHistory",
      ]
    )
    XCTAssertEqual(Set(WorkspaceSection.allCases.map(\.keyboardShortcutKey)).count, WorkspaceSection.allCases.count)
    XCTAssertEqual(
      WorkspaceSection.allCases.map(\.detailLocalizationKey),
      ["workspace.writing.detail", "workspace.library.detail", "workspace.siteStarter.detail", "workspace.sync.detail", "workspace.images.detail", "workspace.contentHealth.detail", "workspace.maintenance.detail", "workspace.releaseHistory.detail"]
    )
  }

  func testWorkspaceNavigationPresentationCentralizesSurfacePolicies() {
    XCTAssertEqual(WorkspaceNavigationPresentation.defaultSection, .writing)
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuItems.map(\.section),
      [.writing, .library, .sync, .images, .contentHealth]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.secondaryEntryItems.map(\.section),
      [.siteStarter]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.secondaryEntryItems.map(\.keyboardShortcutLabel),
      ["⌘5"]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuAdvancedItems.map(\.section),
      [.siteStarter, .maintenance, .releaseHistory]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuAdvancedItems.map(\.keyboardShortcutLabel),
      ["⌘5", "⌘7", "⌘8"]
    )
    XCTAssertEqual(WorkspaceVisibilityPolicy.hiddenNavigationSections, [.maintenance, .releaseHistory])
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandMenuItems.map(\.keyboardShortcutLabel),
      ["⌘1", "⌘9", "⌘2", "⌘3", "⌘4"]
    )
    XCTAssertEqual(
      WorkspaceNavigationPresentation.commandPaletteSections,
      [.writing, .library, .sync, .images, .contentHealth, .siteStarter]
    )
  }

  func testCommandPaletteUsesCanonicalWorkspaceAllowlist() {
    let sections = WorkspaceNavigationPresentation.commandPaletteSections

    XCTAssertEqual(sections, WorkspaceVisibilityPolicy.commandPaletteSections)
    XCTAssertEqual(Set(sections).count, sections.count)
    XCTAssertTrue(Set(sections).isDisjoint(with: WorkspaceVisibilityPolicy.hiddenNavigationSections))
    XCTAssertFalse(sections.contains(.maintenance))
    XCTAssertFalse(sections.contains(.releaseHistory))
  }

  func testEveryWorkspaceSectionHasAnExplicitCenterSurfaceRoute() {
    XCTAssertEqual(
      WorkspaceSection.allCases.map(\.centerSurface),
      [.editor, .knowledgeLibrary, .siteStarter, .repository, .images, .contentHealth, .contentHealth, .repository]
    )
    XCTAssertEqual(
      WorkspaceSection.allCases.filter(\.requiresEditableDraftForCenterSurface),
      [.writing]
    )
    XCTAssertEqual(Set(WorkspaceSection.allCases.map(\.centerSurface)), Set(WorkspaceCenterSurface.allCases))
  }

  func testEveryWorkspaceSectionHasAnExplicitInspectorRoute() {
    XCTAssertEqual(
      WorkspaceSection.allCases.map { WorkspaceInspectorPresentation.route(for: $0) },
      [
        .articleMetadata,
        .unavailable,
        .siteStarter,
        .repository,
        .articleImages,
        .articleChecks,
        .unavailable,
        .unavailable,
      ]
    )
  }

  func testInspectorRouteHandlesAssistantAndParentWorkspaceSubpages() {
    XCTAssertEqual(
      WorkspaceInspectorPresentation.route(for: .writing, isAIAssistantPresented: true),
      .aiAssistant
    )
    XCTAssertFalse(
      WorkspaceInspectorPresentation.supportsInspector(for: .sync, isRepositoryHistoryPresented: true)
    )
    XCTAssertFalse(
      WorkspaceInspectorPresentation.supportsInspector(for: .contentHealth, isMaintenancePresented: true)
    )
    XCTAssertTrue(WorkspaceInspectorPresentation.supportsInspector(for: .siteStarter))
  }

  func testInspectorPresentationPreservesExplicitRequestAcrossResponsiveLayoutChanges() {
    XCTAssertTrue(
      WorkspaceInspectorPresentation.isPresented(
        requested: true,
        supportsInspector: true,
        isFocusMode: false
      )
    )
    XCTAssertFalse(
      WorkspaceInspectorPresentation.isPresented(
        requested: true,
        supportsInspector: true,
        isFocusMode: true
      )
    )
    XCTAssertFalse(
      WorkspaceInspectorPresentation.isPresented(
        requested: true,
        supportsInspector: false,
        isFocusMode: false
      )
    )
    XCTAssertFalse(
      WorkspaceInspectorPresentation.isPresented(
        requested: false,
        supportsInspector: true,
        isFocusMode: false
      )
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

    XCTAssertEqual(preview.accessSummary, CoreL10n.text("Token 可读但未确认写入"))
    XCTAssertEqual(preview.readiness, .blocked)
    XCTAssertFalse(preview.canPublish)
    XCTAssertTrue(preview.checklistMarkdown.contains("- 状态：\(CoreL10n.text("已阻塞"))"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- 权限检查端点：https://api.github.com"))
    XCTAssertTrue(preview.checklistMarkdown.contains("- [ ] 已确认 Token 对 owner/site 具备内容写入权限"))
  }

  func testRemoteRepositoryPreviewDecodesLegacyPayloadAsUnknownRemoteRisk() throws {
    let preview = RemoteRepositoryPublishPreview(
      provider: .github,
      repositoryName: "owner/site",
      mode: .directCommit,
      branchName: "main",
      targetBranch: "main",
      changedPaths: ["content/posts/legacy.md"],
      remoteRiskState: .clean,
      hasToken: true,
      blockingIssues: [],
      warningIssues: []
    )
    let encoded = try JSONEncoder().encode(preview)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "remoteRiskState")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(RemoteRepositoryPublishPreview.self, from: legacyData)

    XCTAssertEqual(decoded.remoteRiskState, .unknown)
  }

  func testInspectorPresentationTemporarilyHidesWhenLayoutCannotFitInspector() {
    XCTAssertFalse(
      WorkspaceInspectorPresentation.isPresented(
        requested: true,
        supportsInspector: true,
        isFocusMode: false,
        allowsInspector: false
      )
    )
    XCTAssertTrue(
      WorkspaceInspectorPresentation.isPresented(
        requested: true,
        supportsInspector: true,
        isFocusMode: false,
        allowsInspector: true
      )
    )
  }
}
