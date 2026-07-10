import Foundation

private struct ReleaseEvidenceSourceCheck {
  let relativePaths: [String]
  let needle: String
  let label: String

  init(_ relativePath: String, _ needle: String, _ label: String) {
    self.relativePaths = [relativePath]
    self.needle = needle
    self.label = label
  }

  init(anyOf relativePaths: [String], _ needle: String, _ label: String) {
    self.relativePaths = relativePaths
    self.needle = needle
    self.label = label
  }
}

private struct ReleaseEvidenceSourceEvaluation {
  var missing: [String]
  var evidencePaths: [String]
}

private enum ReleaseEvidenceSourceManifest {
  static func expandedPaths(for relativePath: String, needle: String) -> [String] {
    switch relativePath {
    case "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift":
      return unique([
        relativePath,
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+AICommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+DeploymentCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+ForwardedState.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+ImageWorkbenchCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+MaterialLibraryCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+OperationalCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+PrivacyMonetizationCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+ProfileSiteCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+PublicAICommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+PublishingCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+ReleaseEvidenceCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+RepositoryCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+RepositoryImportCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+SiteMaintenanceCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+StateSetters.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore+WritingContentCommands.swift",
        "Sources/PublishingWorkbenchCore/Stores/PublishingStore.swift",
        "Sources/PublishingWorkbenchCore/Stores/RepositoryStore.swift",
        "Sources/PublishingWorkbenchCore/Stores/DeploymentStore.swift",
        "Sources/PublishingWorkbenchCore/Stores/AIWorkspaceStore.swift",
        "Sources/PublishingWorkbenchCore/Stores/WorkbenchAIStore.swift",
        "Sources/PublishingWorkbenchCore/Stores/PrivacyMonetizationStore.swift",
        "Sources/PublishingWorkbenchCore/Stores/ImageWorkbenchStore.swift",
      ])
    case "Sources/PersonalSitePublisherMac/Views/SettingsView.swift":
      return settingsPaths(for: needle, fallback: relativePath)
    case "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift":
      return releaseQualityGateServicePaths(for: needle, fallback: relativePath)
    case "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift":
      return unique([
        relativePath,
        "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceComponents.swift",
        "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift",
        "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorModels.swift",
        "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorSections.swift",
        "Sources/PersonalSitePublisherMac/Views/AIChatPromptLibraryComponents.swift",
      ])
    default:
      if relativePath.hasPrefix("Sources/PublishingWorkbenchCore/Stores/") {
        return unique([relativePath, "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift"])
      }
      if relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/Settings")
        || relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/Pro")
        || relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/Privacy")
        || relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/Token") {
        return unique([relativePath, "Sources/PersonalSitePublisherMac/Views/SettingsView.swift"])
      }
      if relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/AIChat") {
        return unique([relativePath, "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift"])
      }
      if relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/SiteMaintenance") {
        return unique([relativePath, "Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift"])
      }
      if relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/ReleaseHistory") {
        return unique([
          relativePath,
          "Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift",
          "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift",
        ])
      }
      if relativePath == "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift" {
        return unique([relativePath, "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift"])
      }
      if relativePath.hasPrefix("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGate") {
        return unique([relativePath, "Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift"])
      }
      return [relativePath]
    }
  }

  private static func settingsPaths(for needle: String, fallback: String) -> [String] {
    if [
      "store.proStatusSummary",
      "store.proSandboxVerificationSummary",
      "purchasePro(store: store)",
      "restorePro(store: store)",
      "proMonetizationAuditReport",
      "externalVerificationEvidenceMarkdown",
      "externalVerificationRecordingCommandMarkdown",
    ].contains(needle) {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/SettingsTabContentFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsProTabFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
        "Sources/PersonalSitePublisherMac/Views/ProDeveloperDiagnosticsSection.swift",
      ])
    }

    if needle == "ProBoundaryEvidenceRow" {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/ProSandboxVerificationSection.swift",
        "Sources/PersonalSitePublisherMac/Views/ProBoundaryEvidenceRow.swift",
      ])
    }

    if needle == "PremiumFeature.allCases" {
      return unique([fallback, "Sources/PersonalSitePublisherMac/Views/ProBenefitsSection.swift"])
    }

    if needle == "store.proUpgradeRequirements" {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
        "Sources/PersonalSitePublisherMac/Views/ProRequirementsSection.swift",
      ])
    }

    if [
      "GitHub/GitLab/Vercel/Netlify/Cloudflare Token",
      "saveRepositoryAccessToken",
      "deleteRepositoryAccessToken",
    ].contains(needle) {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/SettingsTabContentFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsTokenTabFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        "Sources/PersonalSitePublisherMac/Views/TokenSettingsView.swift",
        "Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift",
      ])
    }

    if needle == "checkRepositoryTokenAccess" {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/RepositoryPermissionSettingsView.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsTokenTabFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        "Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift",
      ])
    }

    if [
      "privacyProtectionAudit",
      "privacyProtectionStatus.checklistMarkdown",
      "privacyProtectionAudit.checklistMarkdown",
    ].contains(needle) {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/SettingsTabContentFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsPrivacyTabFactory.swift",
        "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        "Sources/PersonalSitePublisherMac/Views/PrivacySettingsView.swift",
        "Sources/PersonalSitePublisherMac/Views/PrivacyAdvancedDiagnosticsSection.swift",
      ])
    }

    if [
      "requiresUnlockOnLaunch",
      "locksWhenInactive",
    ].contains(needle) {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/PrivacySettingsView.swift",
        "Sources/PersonalSitePublisherMac/Views/PrivacySettingsLockSection.swift",
      ])
    }

    if needle == "masksPrivateContent" {
      return unique([
        fallback,
        "Sources/PersonalSitePublisherMac/Views/PrivacySettingsView.swift",
        "Sources/PersonalSitePublisherMac/Views/PrivacySettingsVisibilitySection.swift",
      ])
    }

    return unique([
      fallback,
      "Sources/PersonalSitePublisherMac/Views/SettingsTabContentFactory.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsDefaultRulesTabFactory.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsTokenTabFactory.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsAITabFactory.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsPrivacyTabFactory.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsProTabFactory.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsClipboardActions.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
      "Sources/PersonalSitePublisherMac/Views/SettingsConfigurationHealthCard.swift",
    ])
  }

  private static func releaseQualityGateServicePaths(for needle: String, fallback: String) -> [String] {
    if needle == "ReleaseQualityGateReport" {
      return unique([fallback, "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateReport.swift"])
    }

    if needle == "strictReadinessSummary" {
      return unique([
        fallback,
        "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateAppStoreChecklistReport.swift",
        "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateExternalVerificationReport.swift",
        "Sources/PublishingWorkbenchCore/Stores/PublishingStore+QualityActions.swift",
      ])
    }

    if needle == "localReleaseEvidenceBundleMarkdown" {
      return unique([
        fallback,
        "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateExternalVerificationReport.swift",
      ])
    }

    return [fallback]
  }

  private static func unique(_ paths: [String]) -> [String] {
    var seen: Set<String> = []
    return paths.filter { seen.insert($0).inserted }
  }
}

struct ReleaseQualityGateProductReadinessGate {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func items(
    root: URL,
    files: [URL],
    workspaceSections: [WorkspaceSection],
    capabilities: ReleaseProductCapabilityCoverage,
    proUpgradeRequirements: [ProUpgradeRequirement]
  ) -> [ReleaseQualityGateItem] {
    var items: [ReleaseQualityGateItem] = []

    items.append(workspaceItem(workspaceSections))
    items.append(storeKitSandboxItem(root: root, files: files))
    items.append(contentsOf: productCapabilityItems(capabilities, root: root))
    items.append(
      proBoundaryItem(root: root, isPresent: capabilities.proBoundary, requirements: proUpgradeRequirements)
    )

    return items
    }
    private func workspaceItem(_ sections: [WorkspaceSection]) -> ReleaseQualityGateItem {
      let required = Set(WorkspaceNavigationPresentation.productReadinessSections)
      let current = Set(sections)
      let missing = required.subtracting(current)
      let dailyEntries = WorkspaceVisibilityPolicy.dailyTopBarSections.map(\.displayName).joined(separator: "、")
      let secondaryEntries = WorkspaceVisibilityPolicy.secondaryEntrySections.map(\.displayName).joined(separator: "、")
      let diagnosticsEntries = WorkspaceVisibilityPolicy.developerDiagnosticsSections.map(\.displayName).joined(separator: "、")
      return ReleaseQualityGateItem(
        id: "workspace-coverage",
        category: .productReadiness,
        title: "产品工作区覆盖",
        status: missing.isEmpty ? .passed : .blocked,
        message: missing.isEmpty ? "工作区已按日常导航、二级入口和开发者诊断入口完成覆盖。" : "缺少 \(missing.map(\.displayName).sorted().joined(separator: ", ")) 工作区。",
        evidence: "日常导航：\(dailyEntries)；二级入口：\(secondaryEntries)；开发者诊断：\(diagnosticsEntries)"
      )
    }
  
    private func storeKitSandboxItem(root: URL, files: [URL]) -> ReleaseQualityGateItem {
      let productID = MonetizationProductCatalog.proLifetimeProductID
      let storeKitFiles = files.filter { file in
        file.pathExtension == "storekit"
      }
      let evidence = storeKitFiles.map { relativePath($0, from: root) }.sorted().joined(separator: ", ")
  
      guard !storeKitFiles.isEmpty else {
        return ReleaseQualityGateItem(
          id: "storekit-sandbox",
          category: .productReadiness,
          title: "StoreKit 沙盒配置",
          status: .blocked,
          message: "缺少 .storekit 配置，无法稳定验证 Pro 产品 ID、购买和恢复流程。",
          evidence: nil
        )
      }
  
      let hasProductID = storeKitFiles.contains { file in
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("\"\(productID)\"")
      }
  
      let storeKitText = storeKitFiles
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
      var missingChecks: [String] = []
      if !hasProductID {
        missingChecks.append("Pro 产品 ID")
      }
      if !storeKitText.contains("\"nonConsumables\"") {
        missingChecks.append("non-consumable 产品类型")
      }
      if !storeKitText.contains("\"displayPrice\"") {
        missingChecks.append("显示价格")
      }
      for locale in ["en_US", "zh_Hans"] where !storeKitText.contains("\"\(locale)\"") {
        missingChecks.append("\(locale) 本地化")
      }
      for field in ["displayName", "description"] where !storeKitText.contains("\"\(field)\"") {
        missingChecks.append("本地化 \(field)")
      }
  
      let requiredSourceChecks: [ReleaseEvidenceSourceCheck] = [
        .init(anyOf: [
          "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
        ], "store.proSandboxVerificationSummary", "设置页 sandbox 摘要"),
        .init(anyOf: [
          "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/ProSandboxVerificationSection.swift",
        ], "ProBoundaryEvidenceRow", "设置页边界事件摘要"),
        .init(anyOf: [
          "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        ], "purchasePro(store: store)", "购买入口"),
        .init(anyOf: [
          "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        ], "restorePro(store: store)", "恢复购买入口"),
        .init(anyOf: [
          "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        ], "externalVerificationEvidenceMarkdown", "StoreKit 外部证据复制"),
        .init(anyOf: [
          "Sources/PersonalSitePublisherMac/Views/SettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift",
          "Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift",
        ], "externalVerificationRecordingCommandMarkdown", "StoreKit 记录命令复制"),
        .init("Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift", "storeKitProEntitlementCoordinator.start(store: store)", "启动时权益监听"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "Product.products(for: [productID])", "Pro 产品读取"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "product.purchase()", "购买交易"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "AppStore.sync()", "恢复同步"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "Transaction.currentEntitlements", "当前权益检查"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "Transaction.updates", "交易更新监听"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "transactionUpdatesTask?.cancel()", "交易监听生命周期清理"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "applyProEntitlement(productID:", "StoreKit 权益应用"),
        .init("Sources/PersonalSitePublisherMac/Support/StoreKitProEntitlementCoordinator.swift", "markProEntitlementCheckCompleted", "缺失权益记录"),
        .init("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "applyProEntitlement(productID:", "Store 权益应用入口"),
        .init("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "markProEntitlementCheckCompleted", "Store 权益检查记录"),
        .init("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "proSandboxVerificationSummary", "Store sandbox 核验摘要"),
        .init("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "public struct ProBoundaryEvidenceSummary", "免费版 / Pro 边界事件摘要"),
        .init("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "externalVerificationRecordingCommandMarkdown", "StoreKit 记录命令模板"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryTracksRemainingSandboxChecks", "sandbox 待核验测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryRejectsLocalOverrideAsSandboxEvidence", "本地覆盖不算 sandbox 测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryRejectsMismatchedStoreKitProductID", "产品 ID 不匹配测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryRequiresBoundaryEventEvidenceBeforeVerified", "边界事件证据测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryIsVerifiedForCheckedStoreKitEntitlement", "StoreKit 权益核验通过测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryBuildsExternalEvidenceFields", "外部证据字段测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryBuildsRecordingCommand", "StoreKit 记录命令测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProEntitlementAllowsPremiumFeaturesWithoutConsumingFreeUsage", "Pro 不消耗免费额度测试"),
        .init("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testSilentStoreKitEntitlementCheckUpdatesTimestampWithoutUserMessage", "静默权益检查测试"),
        .init("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testStoreKitSandboxBlocksIncompleteProductMetadataAndMissingPurchaseRestoreEntrypoints", "StoreKit 配置缺项门禁测试"),
        .init("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testStoreKitSandboxRequiresEntitlementUpdatesAndRegressionTests", "StoreKit 源码闭环门禁测试"),
      ]
      let sourceEvaluation = evaluateSourceChecks(requiredSourceChecks, root: root)
      missingChecks.append(contentsOf: sourceEvaluation.missing)
  
      if !missingChecks.isEmpty {
        let sourceEvidence = sourceEvaluation.evidencePaths.joined(separator: ", ")
        return ReleaseQualityGateItem(
          id: "storekit-sandbox",
          category: .productReadiness,
          title: "StoreKit 沙盒配置",
          status: .blocked,
          message: "StoreKit / Pro 沙盒证据缺少 \(missingChecks.joined(separator: "、"))。",
          evidence: [evidence.nilIfEmpty, sourceEvidence.nilIfEmpty].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
        )
      }
  
      return ReleaseQualityGateItem(
        id: "storekit-sandbox",
        category: .productReadiness,
        title: "StoreKit 沙盒配置",
        status: .passed,
        message: "StoreKit 配置、启动权益刷新、购买、恢复、交易更新、监听清理、权益应用、免费额度边界和 sandbox 回归测试已经形成闭环。",
        evidence: [evidence.nilIfEmpty, sourceEvaluation.evidencePaths.joined(separator: ", ").nilIfEmpty].compactMap { $0 }.joined(separator: ", ").nilIfEmpty
      )
    }
  
    private func productBoundaryItem(id: String, title: String, isPresent: Bool) -> ReleaseQualityGateItem {
      ReleaseQualityGateItem(
        id: id,
        category: .productReadiness,
        title: title,
        status: isPresent ? .passed : .blocked,
        message: isPresent ? "当前 Mac 版已经具备该产品边界。" : "当前 Mac 版缺少该产品边界。",
        evidence: nil
      )
    }
  
    private func onlinePublishingItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "online-publishing", title: "GitHub/GitLab API 线上发布", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "public func checkAccess", "Token 权限检查入口"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "public func createRepository", "GitHub/GitLab 仓库创建 API"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "public func publish(", "线上发布入口"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "publishToGitHub", "GitHub 发布实现"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "publishToGitLab", "GitLab 发布实现"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "GitHubPutContentsBody", "GitHub contents API 直接提交"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "GitLabCreateProjectBody", "GitLab project API"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "GitHubCreatePullRequestBody", "GitHub PR API"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "GitLabCreateCommitBody", "GitLab commit API"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "GitLabCreateMergeRequestBody", "GitLab MR API"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "application/json\", forHTTPHeaderField: \"Accept", "GitLab JSON Accept 头"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "validateExpectedRemoteVersion", "远端版本冲突阻断"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "public func rollback(", "远端回滚 API"),
        ("Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift", "public func withdrawReview(", "Review 撤回 API"),
        ("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift", "ReleaseRecordBatchItem", "批量发布记录明细模型"),
        ("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift", "batchItems", "批量发布逐篇记录"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "publishSelectedDraftOnlineUsingPreferredStrategy", "单篇线上发布 Store 入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "publishBatchReadyDraftsOnlineUsingPreferredStrategy", "批量线上发布 Store 入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "createRemoteRepositoryForActiveProfile", "GitHub/GitLab 仓库创建 Store 入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "rollbackRemoteRelease", "Store 远端回滚入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "withdrawRemoteReview", "Store Review 撤回入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "shouldRefreshDeploymentStatusAfterRemoteOperation", "Review 发布不触发部署校验边界"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "relevantDeploymentStatus", "Review 历史部署快照过滤"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRepositoryPublishService.publish", "Store 调用远端发布服务"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRepositoryPublishService.checkAccess", "Store 调用 Token 权限检查"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRepositoryPublishService.createRepository", "Store 调用远端建仓服务"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRepositoryPublishService.rollback", "Store 调用远端回滚服务"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRepositoryPublishService.withdrawReview", "Store 调用 Review 撤回服务"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "remotePublishLiveVerificationCommandMarkdown", "远端实测命令模板"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "externalVerificationEnvironmentPreparationCommandMarkdown", "私有 env 准备命令模板"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remotePublishLiveVerificationCommandMarkdown", "Store 远端实测命令入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "externalVerificationEnvironmentPreparationCommandMarkdown", "Store 私有 env 准备命令入口"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift", "store.createRemoteRepositoryForActiveProfile", "线上发布中心创建仓库按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "执行线上回滚", "线上回滚按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "撤回线上 Review", "线上 Review 撤回按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "批量文章", "发布记录批量文章明细 UI"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.remotePublishLiveVerificationCommandMarkdown", "上架页远端实测命令按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.externalVerificationEnvironmentPreparationCommandMarkdown", "上架页私有 env 准备命令按钮"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitHubDirectPublishUpdatesExistingContentOnTargetBranch", "GitHub direct 成功测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitHubReviewPublishCreatesBranchWritesContentsAndPullRequest", "GitHub PR 成功测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitHubDirectPublishStopsWhenExpectedRemoteSHAChanged", "GitHub 冲突阻断测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitHubRollbackCreatesCommitFromParentTreeAndUpdatesBranch", "GitHub 远端回滚测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitHubRollbackStopsWhenTargetBranchMoved", "GitHub 回滚冲突阻断测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitHubReviewWithdrawalClosesPullRequest", "GitHub PR 撤回测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitLabDirectPublishUpdatesExistingContentOnTargetBranch", "GitLab direct 成功测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitLabReviewPublishCreatesCommitActionsAndMergeRequest", "GitLab MR 成功测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "Accept\") == \"application/json", "GitLab JSON Accept 头测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testCreatesGitLabGroupProject", "GitLab project 创建测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitLabDirectPublishStopsWhenLastCommitIDChanged", "GitLab 冲突阻断测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitLabRollbackUsesCommitRevertAPI", "GitLab 远端回滚测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testGitLabReviewWithdrawalClosesMergeRequest", "GitLab MR 撤回测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testAccessCheckReportsWritableGitHubRepository", "GitHub Token 权限测试"),
        ("Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift", "testAccessCheckReportsNormalizedGitLabAPIBaseURL", "GitLab Token 权限测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testCreateGitHubRepositoryForActiveProfileUsesAPIAndUpdatesProfile", "Store 建仓回归测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseRecordTests.swift", "testBatchRemotePublishRecordCapturesTraceableDraftItems", "批量线上发布记录明细测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseRecordTests.swift", "testBatchRemotePublishFailureRecoveryPackageIncludesDraftItems", "批量失败恢复包明细测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "batchItems.map", "Store 批量线上发布明细断言"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testOnlineReviewPublishWaitsForMergeWithoutDeploymentStatusRefresh", "Review 发布等待合并测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "主站可访问，但 PR 尚未合并", "Review 部署快照忽略测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteRollbackCreatesRollbackRecordFromReleaseHistory", "Store 远端回滚记录测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteReviewWithdrawalCreatesReleaseRecordFromReleaseHistory", "Store Review 撤回记录测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testReleaseReportProvidesRemotePublishLiveVerificationCommands", "远端实测命令测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testReleaseReportProvidesPrivateEnvironmentPreparationCommands", "私有 env 准备命令测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "online-publishing",
          category: .productReadiness,
          title: "GitHub/GitLab API 线上发布",
          status: .blocked,
          message: "线上发布链路缺少 \(missing.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "online-publishing",
        category: .productReadiness,
        title: "GitHub/GitLab API 线上发布",
        status: .passed,
        message: "线上发布已覆盖 GitHub/GitLab Token 权限检查、GitHub 建仓、直接提交、PR/MR、GitLab JSON API 请求头、远端版本冲突阻断、远端回滚、Review 撤回、单篇/批量 Store 入口、批量发布逐篇明细、实测命令模板和回归测试。",
          evidence: "Sources/PublishingWorkbenchCore/Services/RemoteRepositoryPublishService.swift, Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift, Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift, Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift, Tests/PublishingWorkbenchCoreTests/RemoteRepositoryPublishServiceTests.swift"
      )
    }
  
    private func remoteSyncCenterItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "remote-sync-center", title: "远端同步中心和冲突预览", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Models/RemoteRepositoryPublishPreview.swift", "RemoteRepositoryPublishPreview", "线上发布预览模型"),
        ("Sources/PublishingWorkbenchCore/Models/RemoteRepositoryPublishPreview.swift", "remoteConflictPaths", "远端冲突路径"),
        ("Sources/PublishingWorkbenchCore/Models/RemoteRepositoryPublishPreview.swift", "checklistMarkdown", "线上发布核对包"),
        ("Sources/PublishingWorkbenchCore/Services/RemotePublishRiskService.swift", "RemotePublishRiskService", "远端冲突风险服务"),
        ("Sources/PublishingWorkbenchCore/Services/RemotePublishRiskService.swift", "remoteConflictPaths", "远端同路径冲突检测"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "repositoryTokenAvailability", "仓库 Token 状态"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "saveRepositoryAccessToken", "保存仓库 Token"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "deleteRepositoryAccessToken", "删除仓库 Token"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "refreshRepositoryTokenAvailability", "刷新 Token 状态"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "checkRepositoryTokenAccess", "Token 权限检查"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "activeRemoteRepositoryAccessCheck", "当前仓库权限结果"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "hasStaleRemoteRepositoryAccessCheckForActiveProfile", "陈旧权限检查提示"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRepositoryPublishPreview(for draft", "单篇线上发布预览"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRepositoryPublishPreview(for plan", "批量线上发布预览"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "matchingRemoteRepositoryAccessCheck", "权限检查仓库匹配"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remotePublishRiskService.remoteConflictPaths", "预览冲突路径"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "importableRemoteChangedArticlePaths", "远端文章导入入口"),
        ("Sources/PublishingWorkbenchCore/Services/LocalRepositoryService.swift", "remoteChangedFilesForRole", "远端变更分类"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift", "线上发布中心", "同步页线上发布中心"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift", "checkRepositoryTokenAccess", "同步页权限检查按钮"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift", "remoteConflictPreview", "远端冲突预览 UI"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift", "batchOnlinePublishPreview", "批量线上发布预览 UI"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift", "remoteChangedFiles", "远端 diff 审阅 UI"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift", "importableRemoteChangedArticleCount", "可导入远端文章统计"),
        ("Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift", "线上发布预览", "发布抽屉线上发布预览"),
        ("Sources/PersonalSitePublisherMac/Views/PublishDrawerView.swift", "checkRepositoryTokenAccess", "发布抽屉权限检查"),
        ("Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift", "GitHub/GitLab/Vercel/Netlify/Cloudflare Token", "设置页仓库 Token 输入"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsTokenTabFactory.swift", "saveRepositoryAccessToken", "设置页保存 Token"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsTokenTabFactory.swift", "deleteRepositoryAccessToken", "设置页删除 Token"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "checkRepositoryTokenAccess", "设置页检查权限"),
        ("Tests/PublishingWorkbenchCoreTests/WorkspaceModelsTests.swift", "testRemoteRepositoryPreviewBlocksReadOnlyAccessCheck", "只读 Token 预览测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteRepositoryPublishPreviewSummarizesReviewRequestAndRemoteRisk", "PR/MR 风险预览测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteRepositoryPublishPreviewRequiresTokenBeforeOnlinePublish", "缺少 Token 测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteRepositoryPublishPreviewRequiresPermissionCheckBeforePublish", "权限未检查测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRepositoryPermissionCheckPersistsAcrossRelaunch", "权限检查持久化测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentOwner", "权限仓库 owner 匹配测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteRepositoryPublishPreviewRejectsAccessCheckFromDifferentAPIBaseURL", "权限 API baseURL 匹配测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testOnlineDirectPublishBlocksRemoteSamePathConflictBeforeCallingAPI", "直接提交远端冲突阻断测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testBatchRemoteRepositoryPublishPreviewIncludesReviewableRemoteConflicts", "批量远端冲突预览测试"),
        ("Tests/PublishingWorkbenchCoreTests/RepositoryAutoSyncTests.swift", "testAutoSyncFetchesUpstreamBeforeScanningRemoteChanges", "fetch upstream 后扫描远端变更测试"),
        ("Tests/PublishingWorkbenchCoreTests/LocalRepositoryServiceTests.swift", "remoteChangedFiles", "本地仓库远端变更测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "remote-sync-center",
          category: .productReadiness,
          title: "远端同步中心和冲突预览",
          status: .blocked,
          message: "远端同步中心缺少 \(missing.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Models/RemoteRepositoryPublishPreview.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift, Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "remote-sync-center",
        category: .productReadiness,
        title: "远端同步中心和冲突预览",
        status: .passed,
        message: "远端同步中心已覆盖仓库 Token 保存/删除/权限检查、权限结果匹配、单篇/批量线上发布预览、远端同路径冲突预览、upstream 远端变更导入入口和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Models/RemoteRepositoryPublishPreview.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceView.swift, Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift"
      )
    }
  
    private func repositoryAutoSyncItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "repository-auto-sync", title: "自动同步调度", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "updateRepositoryAutoSyncSettings", "自动同步设置持久化"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "tickRepositoryAutoSync", "到期调度入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "runRepositoryAutoSync", "立即执行入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "repositoryService.fetchUpstream", "扫描前 fetch upstream"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "importableRemoteChangedArticlePaths", "可导入远端文章统计"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift", "repositoryAutoSyncSection", "远端同步中心自动同步面板"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift", "Toggle(\"启用自动同步\"", "启用开关"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift", "Toggle(\"扫描前 fetch upstream\"", "fetch upstream 开关"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift", "Picker(\"扫描间隔\"", "扫描间隔控件"),
        ("Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift", "store.runRepositoryAutoSync()", "立即扫描按钮"),
        ("Tests/PublishingWorkbenchCoreTests/RepositoryAutoSyncTests.swift", "testAutoSyncTickRunsOnlyWhenDue", "到期调度回归测试"),
        ("Tests/PublishingWorkbenchCoreTests/RepositoryAutoSyncTests.swift", "testAutoSyncFetchesUpstreamBeforeScanningRemoteChanges", "真实 git upstream 扫描测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "repository-auto-sync",
          category: .productReadiness,
          title: "自动同步调度",
          status: .blocked,
          message: "自动同步调度缺少 \(missing.prefix(5).joined(separator: "、"))\(missing.count > 5 ? "…" : "")。",
          evidence: "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift, Tests/PublishingWorkbenchCoreTests/RepositoryAutoSyncTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "repository-auto-sync",
        category: .productReadiness,
        title: "自动同步调度",
        status: .passed,
        message: "自动同步已覆盖设置持久化、到期 tick、fetch upstream、远端变更统计、手动扫描、导入入口和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/RepositoryWorkspaceAutoSyncSection.swift, Tests/PublishingWorkbenchCoreTests/RepositoryAutoSyncTests.swift"
      )
    }
  
    private func aiChatWorkspaceItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "ai-chat-workspace", title: "完整 AI 对话工作区", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "struct AIChatWorkspaceView", "独立 AI 对话页"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "accessibilityIdentifier(\"ai-chat-workspace\")", "AI 工作区 accessibility 标识"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "AIChatPromptLibrarySheet", "快捷提示/指令库"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "contextOverview", "上下文文章概览"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "conversationTitle(for", "对话标题"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "regenerate(draft", "重新生成入口"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "selectedImageAttachmentIDs", "图片附件选择"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "aiChatImageAttachments", "附件发送处理"),
        ("Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift", "AIChatWorkspaceView(store: store)", "AI 独立工作区路由"),
        ("Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift", "MacMarkdownComposerView(draft: draft, store: store)", "写作工作区路由"),
        ("Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift", "WorkspaceTaskInspector(section: store.selectedSection", "右侧任务 Inspector 路由"),
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "struct EditorInspectorView", "写作元数据 Inspector"),
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "struct EditorInspectorView", "右侧元数据 Inspector"),
        ("Sources/PersonalSitePublisherMac/Views/ContentView.swift", "openAIChatWorkspace", "主工作区 AI 入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "openAIChatWorkspace", "Store 打开 AI 工作区"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "prepareAIChat", "按文章准备对话上下文"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "startNewAIChatConversation", "新建/归档对话"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "restoreArchivedAIChatConversation", "恢复历史对话"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "regenerateLastAIChatReply", "重新生成最后回复"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "regenerateAIChatReply", "重新生成指定回复"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "sendAIChatMessage", "发送聊天消息"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "aiChatImageAttachments", "文章图片转聊天附件"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift", "articleContextPrompt", "当前文章上下文提示"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift", "paragraphContextPrompt", "段落上下文提示"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift", "quotedMessagePrompt", "引用消息上下文"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatConversationPresentation.swift", "displayTitle", "对话标题生成"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatConversationPresentation.swift", "contextSummary", "上下文摘要"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatConversationPresentation.swift", "archivedConversationPresentation", "历史对话展示"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatTranscriptService.swift", "markdownTranscript", "对话导出"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatTranscriptService.swift", "图片附件", "附件转录"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchAIFeatureFacade.swift", "selectedChatDraft", "AI 工作区当前文章窄入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchAIFeatureFacade.swift", "updateChatDraft", "AI 工作区文章更新窄入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchAIFeatureFacade.swift", "chatPublishingPackage", "AI 工作区发布上下文窄入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchAIFeatureFacade.swift", "activeChatEditorSelectionRange", "AI 工作区编辑器选区窄入口"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceMessageFlowSection.swift", "AIChatMessageFlowState", "消息流状态模型"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceMessageFlowSection.swift", "AIChatMessageFlowActions", "消息流动作模型"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceMessageFlowSection.swift", "setCapabilityMode", "消息流能力中心状态动作"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "testArticleContextPromptBuildsExplicitCurrentArticleReference", "文章上下文提示测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "testParagraphContextPromptBuildsFocusedArticleInstruction", "段落上下文提示测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "testQuotedAssistantMessagePromptBuildsFollowUpInstruction", "引用消息测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatConversationPresentationTests.swift", "testDisplayTitleUsesFirstUserMessageBeforeDraftTitle", "对话标题测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatConversationPresentationTests.swift", "testContextSummaryMatchesSiteAndGeneralModes", "上下文摘要测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatTranscriptServiceTests.swift", "testMarkdownTranscriptIncludesConversationMetadataAndMessages", "对话导出测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatTranscriptServiceTests.swift", "testMessageDisplayContentIncludesImageAttachmentNames", "附件展示测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreAIPromptTests.swift", "testAIEntryOpensDedicatedChatWorkspaceWithoutMetadataAssistant", "独立工作区入口测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreAIPromptTests.swift", "testQuickPromptLibraryCoversMobilePublishingCapabilityGroups", "快捷提示覆盖测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift", "testStoreArchivesAndRestoresAIChatConversations", "按文章历史对话测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift", "testStoreRegeneratesSelectedAssistantReplyFromMatchingUserTurn", "重新生成测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreImageBatchTests.swift", "testAIChatImageAttachmentsLoadsSelectedDraftImages", "附件加载测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreImageBatchTests.swift", "testAIChatImageAttachmentsUsesMobileEightMegabyteLimit", "附件大小边界测试"),
      ]
      let forbiddenSourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "AIPublishingAssistant", "写作 Inspector 不包含 AI 发布助手边界"),
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "AI 发布助手", "写作 Inspector 不包含 AI 发布助手文案"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift", "store.publishing", "AI 工作区不直通 PublishingStore"),
        ("Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceInspectorComponents.swift", "store.publishing", "AI 工作区 Inspector 不直通 PublishingStore"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
      let violations = forbiddenSourceChecks.compactMap { check -> String? in
        let url = root.appendingPathComponent(check.relativePath)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.contains(check.needle) ? check.label : nil
      }
      let problems = missing + violations
  
      if !problems.isEmpty {
        return ReleaseQualityGateItem(
          id: "ai-chat-workspace",
          category: .productReadiness,
          title: "完整 AI 对话工作区",
          status: .blocked,
          message: "AI 对话工作区缺少或冲突 \(problems.joined(separator: "、"))。",
          evidence: "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift, Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceMessageFlowSection.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchAIFeatureFacade.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift, Tests/PublishingWorkbenchCoreTests/WorkbenchStoreAIPromptTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "ai-chat-workspace",
        category: .productReadiness,
        title: "完整 AI 对话工作区",
        status: .passed,
        message: "AI 对话工作区已覆盖独立聊天页、快捷提示、当前文章/段落/引用上下文、对话标题、历史对话、重新生成、图片附件、对话导出测试，并确认写作 Inspector 不再承载 AI 发布助手。",
        evidence: "Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceView.swift, Sources/PersonalSitePublisherMac/Views/AIChatWorkspaceMessageFlowSection.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchAIFeatureFacade.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift, Tests/PublishingWorkbenchCoreTests/WorkbenchStoreAIPromptTests.swift"
      )
    }
  
    private func seoSocialPreviewItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "seo-social-preview", title: "SEO / Open Graph / Twitter 社交预览", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "SEOSocialPreviewCardKind", "社交预览卡片模型"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "case openGraph", "Open Graph 卡片"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "case twitter", "Twitter/X 卡片"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "SEOSocialPreviewCachePresentation", "快照缓存状态"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "platformReadiness", "平台就绪度"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "socialShareCopyItems", "分享文案"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "SEOSocialPreviewDebugLink", "外部调试链接模型"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "externalDebugLinks", "外部调试链接生成"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "publishPackageMarkdown", "可复制发布包"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "deploymentSiteURL", "线上部署 URL 生产社交地址"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift", "seoSocialPreviewPrompt", "SEO 社交预览 AI Prompt"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "prepareSEOSocialPreview", "按需准备缓存快照"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "refreshSEOSocialPreview", "手动刷新快照"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "sendSEOSocialPreviewToAI", "SEO 社交预览发送到 AI"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "isSEOSocialPreviewStale", "过期检测"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "refreshSEOSocialPreviewAfterAIMetadataChange", "AI 元数据应用后刷新"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "relatedArticleSuggestions", "关联文章建议"),
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "prepareSEOSocialPreviewIfNeeded", "编辑器按需准备预览"),
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "store.refreshSEOSocialPreview", "手动刷新按钮"),
        ("Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift", "打开 AI 对话", "AI 对话入口"),
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "socialDebugLinkSection", "编辑器外部调试链接 UI"),
        ("Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift", "socialDebugLinkSection", "任务检查器外部调试链接 UI"),
        ("Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift", "relatedArticleSuggestionSection", "关联文章建议 UI"),
        ("Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift", "testSnapshotBuildsSearchOpenGraphAndTwitterCards", "搜索/OG/Twitter 快照测试"),
        ("Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift", "testSnapshotUsesDeploymentSiteURLForProductionSocialMetaWhenPreviewURLIsMissing", "线上部署 URL 社交元数据测试"),
        ("Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift", "testSnapshotProvidesExternalSocialDebugLinks", "外部调试链接测试"),
        ("Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift", "testPrivateSnapshotHidesSocialImage", "私密内容图片保护测试"),
        ("Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift", "testStoreKeepsCachedSnapshotUntilManualRefresh", "缓存和手动刷新测试"),
        ("Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift", "testApplyingAIMetadataRefreshesSEOSocialPreviewSnapshot", "AI 元数据刷新测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "relatedArticleSuggestions", "关联文章建议测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "relatedArticleSuggestionPrompt", "关联建议 AI Prompt 测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "testSEOSocialPreviewPromptBuildsMetadataAndSocialCardContext", "SEO 社交预览 AI Prompt 测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift", "testStoreSendsSEOSocialPreviewIntoAIChatWorkspace", "SEO 社交预览 AI 发送测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "seo-social-preview",
          category: .productReadiness,
          title: "SEO / Open Graph / Twitter 社交预览",
          status: .blocked,
          message: "SEO 社交预览缺少 \(missing.prefix(5).joined(separator: "、"))\(missing.count > 5 ? "…" : "")。",
          evidence: "Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift, Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "seo-social-preview",
        category: .productReadiness,
        title: "SEO / Open Graph / Twitter 社交预览",
        status: .passed,
        message: "SEO 社交预览已覆盖搜索、Open Graph、Twitter/X 卡片、线上部署 URL、快照缓存、手动刷新、外部调试链接、AI 元数据刷新、关联文章建议、AI 对话入口和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/EditorInspectorView.swift, Sources/PersonalSitePublisherMac/Views/MacMarkdownComposerView.swift, Tests/PublishingWorkbenchCoreTests/SEOSocialPreviewServiceTests.swift"
      )
    }
  
    private func deploymentStatusItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "deployment-status", title: "部署状态和发布后校验", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "case githubPages", "GitHub Pages provider"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "case gitlabPages", "GitLab Pages provider"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "case netlify", "Netlify provider"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "case vercel", "Vercel provider"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "case cloudflarePages", "Cloudflare Pages provider"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "case custom", "自定义状态端点"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "githubSignals", "GitHub Pages / Actions 检查"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "gitLabSignals", "GitLab Pipeline 检查"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "netlifySignals", "Netlify Deploy 检查"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "vercelSignals", "Vercel Deploy 检查"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "cloudflarePagesSignals", "Cloudflare Pages 检查"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "endpointSignal", "状态端点可达性检查"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "articlePageSignal", "发布后文章页面内容校验"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "articlePageSocialSignal", "发布后社交元数据校验"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "firstMetaContent", "发布页面 meta 标签读取"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "postPublishCheckItems", "发布后检查清单"),
        ("Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift", "DeploymentStatusProviderReadiness", "部署配置就绪度"),
        ("Sources/PublishingWorkbenchCore/Models/DeploymentPollingModels.swift", "DeploymentPollingSettings", "部署轮询设置模型"),
        ("Sources/PublishingWorkbenchCore/Models/DeploymentPollingModels.swift", "DeploymentPollingState", "部署轮询状态模型"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "updateDeploymentPollingSettings", "部署轮询设置持久化"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "tickDeploymentPolling", "部署轮询定时入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "runDeploymentPolling", "部署轮询手动入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "refreshDeploymentStatus", "手动刷新部署状态"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "deploymentStatusSnapshots", "部署状态快照缓存"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "deploymentStatusHistory", "部署状态历史缓存"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "deploymentStatusSummary", "部署状态面板"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "deploymentPollingSummary", "部署轮询面板"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDeploymentDebugSection.swift", "deploymentStatusHistoryTimeline", "发布后校验历史轨迹"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "Toggle(\"启用部署轮询\"", "部署轮询开关"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "Picker(\"轮询间隔\"", "部署轮询间隔控件"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "store.refreshDeploymentStatus", "部署状态刷新按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "store.runDeploymentPolling", "立即轮询按钮"),
        ("Sources/PersonalSitePublisherMac/Views/TokenRepositoryTokenSection.swift", "GitHub/GitLab/Vercel/Netlify/Cloudflare Token", "部署 Token 设置"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testGitHubPagesActionsAndEndpointBuildSuccessfulSnapshot", "GitHub Pages/Actions 测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testGitLabPipelineAndPagesEndpointBuildSuccessfulSnapshot", "GitLab Pipeline 测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testNetlifyDeployAPIBuildsSuccessfulSnapshotWithoutCustomEndpoint", "Netlify Deploy 测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testVercelDeploymentsAPIBuildsRunningSnapshotWithProjectAndTeam", "Vercel Deploy 测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testCloudflarePagesAPIBuildsSuccessfulSnapshotWithAccountAndProject", "Cloudflare Pages 测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentEndpointUsesBearerTokenOnlyWhenExplicitlyEnabled", "状态端点 Bearer Token 测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentCheckVerifiesPublishedArticlePageContainsTitle", "文章页面内容校验测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentArticleCheckVerifiesPublishedSocialMetadataAgainstReleaseSnapshot", "发布页面社交元数据成功测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentArticleCheckFailsWhenPublishedSocialImageURLIsMissing", "发布页面社交图缺失测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentArticleCheckFailsWhenPublishedSocialImageAltIsMissing", "发布页面社交图 Alt 缺失测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentArticleCheckFailsWhenPublishedSocialTitleIsMissing", "发布页面社交标题缺失测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testStoreRefreshDeploymentStatusCachesSnapshotForRecord", "Store 刷新缓存测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testStoreRefreshDeploymentStatusKeepsHistoryForRecord", "Store 刷新历史测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentPollingChecksPendingDeploymentRecordsAndCachesSnapshots", "部署轮询缓存测试"),
        ("Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift", "testDeploymentPollingSummarizesSuccessRunningAndFailedRecords", "部署轮询汇总测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "deployment-status",
          category: .productReadiness,
          title: "部署状态和发布后校验",
          status: .blocked,
          message: "部署状态链路缺少 \(missing.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift, Sources/PublishingWorkbenchCore/Models/DeploymentPollingModels.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift, Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "deployment-status",
        category: .productReadiness,
        title: "部署状态和发布后校验",
        status: .passed,
        message: "部署状态已覆盖 GitHub Pages/Actions、GitLab Pipeline、Netlify、Vercel、Cloudflare Pages、自定义端点、文章页面内容/SEO/社交元数据校验、历史轨迹、轮询、UI 入口和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Services/DeploymentStatusService.swift, Sources/PublishingWorkbenchCore/Models/DeploymentPollingModels.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift, Tests/PublishingWorkbenchCoreTests/DeploymentStatusServiceTests.swift"
      )
    }
  
    private func siteMaintenanceItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "site-maintenance", title: "站点维护工作台", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "SiteMaintenanceReport", "维护报告模型"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "calendarBuckets", "内容日历"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "calendarInsights", "内容节奏提示"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "calendarScheduleItems", "待发布排期"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "TaxonomyGovernanceSummary", "标签/分类治理"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "StaleArticleCandidate", "旧文整理"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "SiteRelationSuggestion", "文章关系 / 内链机会"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "SiteLinkAuditItem", "链接审计"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "MaintenanceOperationLogEntry", "操作日志"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "maintenanceChecklistMarkdown", "可复制维护清单"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "maintenanceActionItems", "维护行动队列"),
        ("Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift", "healthSummary", "维护健康摘要"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift", "maintenanceActionPrompt", "维护行动 AI Prompt"),
        ("Sources/PublishingWorkbenchCore/Stores/SiteMaintenanceSnapshot.swift", "SiteMaintenanceSnapshot", "维护报告快照模型"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "refreshSiteMaintenanceSnapshot", "Store 维护报告快照入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "sendMaintenanceActionToAI", "维护行动发送到 AI"),
        ("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift", "case maintenance", "维护工作区导航"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift", "SiteMaintenanceDetailView", "维护详情页"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailContent.swift", "SiteMaintenanceSnapshotPlaceholder", "维护快照手动生成入口"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailContent.swift", "SiteMaintenanceDetailContent", "维护详情主内容容器"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSections.swift", "SiteMaintenanceReportSections", "维护报告主体区块编排"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceSnapshotHeader.swift", "SiteMaintenanceSnapshotHeader", "维护快照页头 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSectionGroups.swift", "SiteMaintenancePlanningSections", "维护规划区块编排"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSectionGroups.swift", "SiteMaintenanceGovernanceReportSections", "维护治理区块编排"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift", "SiteMaintenanceActionQueueSection", "维护行动队列 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift", "sendToAI", "维护任务 AI 入口"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift", "SiteMaintenanceCalendarSection", "内容日历 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift", "SiteMaintenanceContentPerformanceSection", "内容表现 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift", "SiteMaintenanceTaxonomySection", "标签/分类治理 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift", "SiteMaintenanceStaleArticleSection", "旧文整理 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift", "SiteMaintenanceRelationSuggestionSection", "文章关系 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift", "SiteMaintenanceLinkAuditSection", "链接审计 UI"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift", "SiteMaintenanceOperationLogSection", "操作日志 UI"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingPromptLibraryService.swift", "case .maintenance", "维护 AI 提示作用域"),
        ("Tests/PublishingWorkbenchCoreTests/SiteMaintenanceServiceTests.swift", "testReportBuildsCalendarTaxonomyStaleArticlesAndLinkAudit", "日历/治理/旧文/链接测试"),
        ("Tests/PublishingWorkbenchCoreTests/SiteMaintenanceServiceTests.swift", "testReportSuggestsInternalLinksFromSharedTaxonomy", "文章关系建议测试"),
        ("Tests/PublishingWorkbenchCoreTests/SiteMaintenanceServiceTests.swift", "testMaintenanceChecklistMarkdownSummarizesActionableWorkbenchSections", "维护清单测试"),
        ("Tests/PublishingWorkbenchCoreTests/SiteMaintenanceServiceTests.swift", "testReportIncludesRecentReleaseRecordsAsOperationLog", "操作日志测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "testMaintenanceActionPromptBuildsActionableWorkbenchContext", "维护行动 Prompt 测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift", "testStoreSendsMaintenanceActionIntoAIChatWorkspace", "维护行动 AI 发送测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "site-maintenance-assistant", "维护 AI 工作流测试"),
      ]
  
      let forbiddenSourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift", "DetailContainerView", "维护详情页不保留旧 DetailContainerView 路由"),
        ("Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift", "siteMaintenanceReport", "维护详情页不直接读取 siteMaintenanceReport"),
        ("Sources/PersonalSitePublisherMac/Views/ContentHealthDetailView.swift", "siteMaintenanceReport", "内容健康页不打开即重算维护报告"),
        ("Sources/PersonalSitePublisherMac/Views/WorkspaceLayoutViews.swift", "DetailContainerView", "工作区不保留旧 DetailContainerView 双轨路由"),
      ]

      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
      let violations = forbiddenSourceChecks.compactMap { check -> String? in
        let url = root.appendingPathComponent(check.relativePath)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.contains(check.needle) ? check.label : nil
      }
      let problems = missing + violations
  
      if !problems.isEmpty {
        return ReleaseQualityGateItem(
          id: "site-maintenance",
          category: .productReadiness,
          title: "站点维护工作台",
          status: .blocked,
          message: "站点维护工作台缺少或冲突 \(problems.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailContent.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSections.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceSnapshotHeader.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSectionGroups.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift, Tests/PublishingWorkbenchCoreTests/SiteMaintenanceServiceTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "site-maintenance",
        category: .productReadiness,
        title: "站点维护工作台",
        status: .passed,
        message: "站点维护已覆盖内容日历、标签/分类治理、旧文整理、文章关系/内链机会、链接审计、操作日志、行动队列、维护任务发送到 AI、维护 AI 提示和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Services/SiteMaintenanceService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailView.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceDetailContent.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSections.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceSnapshotHeader.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceReportSectionGroups.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenancePrimarySections.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceCalendarSection.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceContentPerformanceSection.swift, Sources/PersonalSitePublisherMac/Views/SiteMaintenanceGovernanceSections.swift, Tests/PublishingWorkbenchCoreTests/SiteMaintenanceServiceTests.swift"
      )
    }
  
    private func releaseLedgerRollbackItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "release-ledger-rollback", title: "发布台账、部署记录和回滚入口", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "ReleaseLedgerStatus", "发布台账状态模型"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "pendingRemoteRecovery", "远端恢复待确认状态"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "pendingRetry", "失败/离线待重试状态"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "ReleaseRollbackDraft", "回滚草稿"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "ReleaseRecoveryPackage", "发布恢复包"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "ReleaseDeploymentOverview", "部署记录概览"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "rollbackDraft(for", "回滚草稿生成入口"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "failedRemotePublishRollbackDraft", "失败远端发布回滚方案"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "externalVerificationEvidence", "外部验证摘要"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift", "remoteRecoveryVerificationDraftMarkdown", "远端恢复验收草稿"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift", "releaseRecoveryPrompt", "发布恢复 AI Prompt"),
        ("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift", "case remoteRollback", "远端回滚发布记录类型"),
        ("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift", "case remoteReviewWithdrawal", "Review 撤回发布记录类型"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "activeProfileReleaseLedger", "Store 发布台账入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "releaseRecoveryVerificationDraftMarkdown", "Store 远端恢复验收草稿入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteRollbackDraft(for", "Store 远端回滚草稿入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remoteReviewWithdrawalDraft(for", "Store Review 撤回草稿入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "sendReleaseRecoveryPackageToAI", "恢复包发送到 AI"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "rollbackRemoteRelease", "Store 远端回滚执行入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "await refreshDeploymentStatus(for: rollbackRecord", "线上回滚后部署校验"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "withdrawRemoteReview", "Store Review 撤回执行入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "recordReleaseRecoveryExternalVerificationEvidence", "恢复证据录入入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "ReleaseHistoryDetailView", "发布记录详情页"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "releaseActionQueueSection", "发布行动队列 UI"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "releaseRecordCard", "发布记录卡片"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "copyRecoveryPackage", "恢复包复制入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "copyRecoveryEvidence", "恢复证据复制入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "复制恢复验收草稿", "恢复验收草稿 UI 入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift", "store.sendReleaseRecoveryPackageToAI", "恢复包 AI 入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "copyRollbackDraft", "回滚计划复制入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "打开回滚 PR/MR", "远端回滚入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "执行线上回滚", "线上回滚执行入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift", "撤回线上 Review", "线上 Review 撤回入口"),
        ("script/record_remote_recovery_evidence.sh", "pending/retry release ledger states", "远端恢复证据脚本"),
        ("script/test_remote_recovery_evidence.sh", "pending retry ledger regression test", "远端恢复证据脚本测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "testUnknownDeploymentCheckBecomesRetryablePendingState", "待重试状态测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "testPartialRemotePublishFailureBecomesPendingRecoveryState", "远端恢复状态测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "testRecoveryPackageCombinesDeploymentSignalsAndRollbackCommands", "恢复包测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "testRecoveryPackageBuildsExternalVerificationEvidenceSummary", "恢复证据摘要测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "testRemoteRecoveryVerificationDraftCombinesConflictRetryAndRollbackEvidence", "远端恢复验收草稿测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "testRollbackDraftsUseCommitReviewAndLocalRecoveryPlans", "回滚草稿测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift", "testGitLabCommitRollbackDraftBuildsMergeRequestURL", "GitLab 回滚 MR 测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "testReleaseRecoveryPromptBuildsRetryRollbackDecisionContext", "恢复包 Prompt 测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIChatCompletionClientTests.swift", "testStoreSendsReleaseRecoveryPackageIntoAIChatWorkspace", "恢复包 AI 发送测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteRollbackCreatesRollbackRecordFromReleaseHistory", "Store 远端回滚记录测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "Rollback commit is live", "线上回滚部署校验测试"),
        ("Tests/PublishingWorkbenchCoreTests/WorkbenchStoreProfileTests.swift", "testRemoteReviewWithdrawalCreatesReleaseRecordFromReleaseHistory", "Store Review 撤回记录测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testStoreRecordsReleaseRecoveryPackageAsExternalVerificationEvidence", "Store 录入恢复证据测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "release-ledger-rollback",
          category: .productReadiness,
          title: "发布台账、部署记录和回滚入口",
          status: .blocked,
          message: "发布台账/回滚链路缺少 \(missing.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift, Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift, Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "release-ledger-rollback",
        category: .productReadiness,
        title: "发布台账、部署记录和回滚入口",
        status: .passed,
        message: "发布台账已覆盖部署记录、pending/retry/远端恢复状态、恢复包、恢复包发送到 AI、回滚 PR/MR 草稿、远端回滚/Review 撤回记录、回滚后部署校验、外部验证摘要、远端恢复验收草稿、UI 操作入口和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Services/ReleaseLedgerService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseHistoryDetailView.swift, Sources/PersonalSitePublisherMac/Views/ReleaseHistoryRecordCardSection.swift, Tests/PublishingWorkbenchCoreTests/ReleaseLedgerServiceTests.swift"
      )
    }
  
    private func generalDraftWorkspaceItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "general-drafts", title: "素材库 / 跨站点素材", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Models/WorkspaceModels.swift", "case generalDrafts", "素材库工作区导航"),
        ("Sources/PublishingWorkbenchCore/Models/RepositoryProvider.swift", "generalDraftBackup", "素材库 Profile 类型"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "GeneralDraftLibraryReport", "素材库报告"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "GeneralDraftLibraryItem", "通用素材列表项"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "GeneralDraftReusePlan", "跨站点复用计划"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "GeneralDraftBackupPlan", "备份计划"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "GeneralDraftBackupWriteResult", "备份写入结果"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "GeneralDraftLibraryPackagePlan", "素材包计划"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "标签维度", "标签/分类统计"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "general-drafts/MANIFEST.md", "备份清单路径"),
        ("Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift", "git add general-drafts", "备份提交命令"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingChatPromptTemplateService.swift", "generalDraftReusePlanPrompt", "跨站复用 AI Prompt"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "generalDraftLibraryReport", "Store 素材库报告入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "generalDraftBackupPlan", "Store 备份计划入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "importGeneralDraftLibraryPackage", "Store 草稿包导入入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "ensureGeneralDraftProfile", "创建素材库 Profile 入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "createGeneralDraft", "新建素材入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "copyDraftToActiveProfile", "复制到当前站点入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "writeGeneralDraftBackupToRepository", "备份写入入口"),
        ("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift", "GeneralDraftLibraryDetailView", "素材库详情页"),
        ("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift", "reusePlanSection", "复用计划 UI"),
        ("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift", "sendReusePlanToAI", "复用计划发送到 AI"),
        ("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift", "backupSection", "备份计划 UI"),
        ("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift", "librarySection", "通用素材列表 UI"),
        ("Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift", "assetSection", "跨站点素材 UI"),
        ("Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift", "GeneralDraftLibraryInspectorView", "素材库检查器"),
        ("Sources/PersonalSitePublisherMac/Views/WorkspaceTaskInspector.swift", "sendReusePlanToAI", "检查器复用计划 AI 入口"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testReportGroupsGeneralDraftsReusableCandidatesAndAssets", "素材库报告测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testStoreCreatesGeneralDraftProfileAndCopiesDraftToActiveProfile", "创建/复用入口测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testReportSummarizesTagAndCategoryDistribution", "标签/分类统计测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testSourceFieldDiffsDetectChangedTitleSlugSummaryTagsCategoriesAndBodyLength", "复用字段对比测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testGeneralDraftLibraryPackagePlanExportRoundTrip", "草稿包导入导出测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testStoreImportGeneralDraftLibraryPackageUpdatesExistingAndInsertsNew", "草稿包批量导入测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testBackupPlanExportsOnlyGeneralDraftsWithManifestAndCommands", "备份计划测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testWriteBackupPersistsManifestAndGeneralDraftFiles", "备份写入测试"),
        ("Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift", "testStoreWritesGeneralDraftBackupToRepositoryAndUpdatesMessage", "Store 备份写入测试"),
        ("Tests/PublishingWorkbenchCoreTests/AIPublishingChatPromptTemplateServiceTests.swift", "testGeneralDraftReusePlanPromptBuildsCrossSiteRewriteInstruction", "跨站复用 AI Prompt 测试"),
        ("Tests/PublishingWorkbenchCoreTests/PreflightCheckServiceTests.swift", "testGeneralDraftPurposeSkipsRepositoryReadiness", "素材库发布前检查测试"),
        ("Tests/PublishingWorkbenchCoreTests/ContentHealthSummaryTests.swift", "testGeneralDraftSiteIssuesDoNotRequireRepositoryReadiness", "素材库健康摘要测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "general-drafts",
          category: .productReadiness,
          title: "素材库 / 跨站点素材",
          status: .blocked,
          message: "素材库工作区缺少 \(missing.prefix(5).joined(separator: "、"))\(missing.count > 5 ? "…" : "")。",
          evidence: "Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift, Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "general-drafts",
        category: .productReadiness,
        title: "素材库 / 跨站点素材",
        status: .passed,
        message: "素材库已覆盖独立工作区、草稿库 Profile、跨站点复用计划、AI 改写入口、备份清单/写入、侧栏/详情/检查器入口和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Services/GeneralDraftLibraryService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/GeneralDraftLibraryDetailView.swift, Tests/PublishingWorkbenchCoreTests/GeneralDraftLibraryServiceTests.swift"
      )
    }
  
    private func privacyProtectionItem(root: URL, isPresent: Bool) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "privacy-lock", title: "隐私锁和私密内容保护", isPresent: false)
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift", "PrivacyProtectionSettings", "隐私设置模型"),
        ("Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift", "requiresUnlockOnLaunch", "启动解锁设置"),
        ("Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift", "locksWhenInactive", "后台自动锁定设置"),
        ("Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift", "masksPrivateContent", "私密内容遮挡设置"),
        ("Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift", "PrivacyProtectionStatus", "隐私状态摘要"),
        ("Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift", "PrivacyProtectionAudit", "隐私体检"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "privacySettings", "Store 隐私设置"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "isPrivacyLocked", "Store 锁定状态"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "canUseProtectedWorkbench", "受保护工作台可用性"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "lockPrivacy(reason", "手动锁定入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "unlockPrivacy", "解锁入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "lockPrivacyIfNeededForInactiveScene", "切后台锁定入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "privateContentDisplay", "私密内容显示代理"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "isPrivateContentMasked", "私密文章遮挡判断"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "matchesPrivacyProtectedDraftSearch", "私密搜索保护"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "privateContentProtectedPackageMarkdown", "私密复制包遮挡"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "seoSocialPublishPackageMarkdown", "SEO/Social 复制包遮挡入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "generalDraftLibraryReport", "素材库素材包遮挡入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "privacyProtectionAudit", "隐私体检入口"),
        ("Sources/PersonalSitePublisherMac/Views/ContentView.swift", "PrivacyLockOverlay(store: store)", "主窗口隐私锁遮罩"),
        ("Sources/PersonalSitePublisherMac/Views/ContentView.swift", "lockPrivacyIfNeededForInactiveScene", "主窗口后台锁定"),
        ("Sources/PersonalSitePublisherMac/Views/DraftEditorWindowView.swift", "PrivacyLockOverlay(store: store)", "文章窗口隐私锁遮罩"),
        ("Sources/PersonalSitePublisherMac/Views/DraftEditorWindowView.swift", "lockPrivacyIfNeededForInactiveScene", "文章窗口后台锁定"),
        ("Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift", "PrivacyLockOverlay(store: store)", "设置窗口隐私锁遮罩"),
        ("Sources/PersonalSitePublisherMac/App/PersonalSitePublisherMacApp.swift", "lockPrivacyIfNeededForInactiveScene", "设置窗口后台锁定"),
        ("Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift", "lockPrivacy(reason", "菜单锁定命令"),
        ("Sources/PersonalSitePublisherMac/App/PublishingConsoleCommands.swift", "unlockPrivacy", "菜单解锁命令"),
        ("Sources/PersonalSitePublisherMac/Views/SharedViews.swift", "PrivacyLockOverlay", "隐私锁覆盖层"),
        ("Sources/PersonalSitePublisherMac/Views/SharedViews.swift", "privacy-lock-overlay", "隐私锁 accessibility 标识"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsPrivacyTabFactory.swift", "privacyProtectionAudit", "设置页隐私体检"),
        ("Sources/PersonalSitePublisherMac/Views/PrivacySettingsLockSection.swift", "requiresUnlockOnLaunch", "设置页启动锁定开关"),
        ("Sources/PersonalSitePublisherMac/Views/PrivacySettingsLockSection.swift", "locksWhenInactive", "设置页后台锁定开关"),
        ("Sources/PersonalSitePublisherMac/Views/PrivacySettingsVisibilitySection.swift", "masksPrivateContent", "设置页私密遮挡开关"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "privacyProtectionStatus.checklistMarkdown", "隐私清单复制"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "privacyProtectionAudit.checklistMarkdown", "隐私体检复制"),
        ("Sources/PublishingWorkbenchCore/Services/AIPublishingFixQueueService.swift", "guard !draft.isPrivate", "私密文章不进入 AI 修复队列"),
        ("Sources/PublishingWorkbenchCore/Services/SEOSocialPreviewService.swift", "draft.isPrivate ? nil", "私密文章不输出社交图"),
        ("Sources/PublishingWorkbenchCore/Services/ScreenshotDemoDataService.swift", "case privacyLock", "隐私锁截图演示面"),
        ("script/check_privacy_support_copy.sh", "masksPrivateContent", "隐私文案门禁脚本"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testStoreLocksOnLaunchAndInactiveWhenConfigured", "启动/后台锁定测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testProtectedWorkbenchAvailabilityFollowsPrivacyLockState", "受保护工作台测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testPrivacyLockBlocksRemotePublishingBeforeQuotaOrAPIUse", "远端发布锁定测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testPrivacyLockBlocksAIRequestsBeforeQuotaOrConversationChanges", "AI 请求锁定测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testPrivateContentDisplayMasksOnlyPrivateDraftsWhenEnabled", "私密内容遮挡测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testPrivacyProtectedDraftSearchDoesNotMatchHiddenPrivateMetadata", "私密搜索保护测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testSEOSocialPublishPackageMasksPrivateDraftWhenProtectionEnabled", "SEO/Social 复制包遮挡测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testGeneralDraftLibraryReportMasksPrivateDraftsAndAssetsWhenProtectionEnabled", "素材库素材包遮挡测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testPrivacyProtectionAuditCountsOnlyActiveProfilePrivateDrafts", "隐私体检作用域测试"),
        ("Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift", "testPrivacyProtectionStatusChecklistSummarizesReviewableBehavior", "隐私清单测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "privacy-lock",
          category: .productReadiness,
          title: "隐私锁和私密内容保护",
          status: .blocked,
          message: "隐私锁/私密内容保护缺少 \(missing.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/SharedViews.swift, Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "privacy-lock",
        category: .productReadiness,
        title: "隐私锁和私密内容保护",
        status: .passed,
        message: "隐私保护已覆盖启动/后台锁定、主窗口/文章/设置遮罩、设置开关、私密内容遮挡、搜索保护、SEO/Social 和素材库复制包遮挡、AI/远端发布拦截、隐私体检和回归测试。",
        evidence: "Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/SharedViews.swift, Tests/PublishingWorkbenchCoreTests/PrivacyProtectionTests.swift"
      )
    }
  
    private func productCapabilityItems(
      _ capabilities: ReleaseProductCapabilityCoverage,
      root: URL
    ) -> [ReleaseQualityGateItem] {
      [
        onlinePublishingItem(root: root, isPresent: capabilities.onlinePublishing),
        remoteSyncCenterItem(root: root, isPresent: capabilities.remoteSyncCenter),
        repositoryAutoSyncItem(root: root, isPresent: capabilities.repositoryAutoSync),
        seoSocialPreviewItem(root: root, isPresent: capabilities.seoSocialPreview),
        deploymentStatusItem(root: root, isPresent: capabilities.deploymentStatusPanel),
        siteMaintenanceItem(root: root, isPresent: capabilities.siteMaintenanceWorkspace),
        releaseLedgerRollbackItem(root: root, isPresent: capabilities.releaseLedgerRollback),
        generalDraftWorkspaceItem(root: root, isPresent: capabilities.generalDraftWorkspace),
        privacyProtectionItem(root: root, isPresent: capabilities.privacyProtection),
        aiChatWorkspaceItem(root: root, isPresent: capabilities.aiChatWorkspace),
      ]
    }
  
    private func proBoundaryItem(
      root: URL,
      isPresent: Bool,
      requirements: [ProUpgradeRequirement]
    ) -> ReleaseQualityGateItem {
      guard isPresent else {
        return productBoundaryItem(id: "pro-boundary", title: "免费版 / Pro 边界", isPresent: false)
      }
  
      guard !requirements.isEmpty else {
        return ReleaseQualityGateItem(
          id: "pro-boundary",
          category: .productReadiness,
          title: "免费版 / Pro 边界",
          status: .blocked,
          message: "Pro 边界缺少免费版额度、升级原因和购买/恢复下一步证据。",
          evidence: nil
        )
      }
  
      let requirementsByFeature = Dictionary(uniqueKeysWithValues: requirements.map { ($0.feature, $0) })
      let missingFeatures = PremiumFeature.allCases.filter { requirementsByFeature[$0] == nil }
      if !missingFeatures.isEmpty {
        return ReleaseQualityGateItem(
          id: "pro-boundary",
          category: .productReadiness,
          title: "免费版 / Pro 边界",
          status: .blocked,
          message: "Pro 升级说明缺少 \(missingFeatures.map(\.displayName).joined(separator: "、"))。",
          evidence: requirements.map(\.checklistLine).joined(separator: "\n").nilIfEmpty
        )
      }
  
      let incompleteRequirements = requirements.filter { requirement in
        requirement.summary.trimmedForPublishing.isEmpty
          || requirement.reason.trimmedForPublishing.isEmpty
          || requirement.nextStep.trimmedForPublishing.isEmpty
          || requirement.quotaSummary.trimmedForPublishing.isEmpty
      }
      if !incompleteRequirements.isEmpty {
        return ReleaseQualityGateItem(
          id: "pro-boundary",
          category: .productReadiness,
          title: "免费版 / Pro 边界",
          status: .blocked,
          message: "Pro 升级说明不完整：\(incompleteRequirements.map { $0.feature.displayName }.joined(separator: "、"))。",
          evidence: requirements.map(\.checklistLine).joined(separator: "\n").nilIfEmpty
        )
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "public enum PremiumFeature", "付费功能枚举"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "case aiRequest", "AI 请求边界"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "case onlinePublishing", "线上发布边界"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "case batchPublishing", "批量发布边界"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "public struct FreePlanLimits", "免费额度模型"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "public struct ProUpgradeRequirement", "升级说明模型"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "public struct ProMonetizationAuditReport", "Pro 审核清单"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "public struct ProSandboxVerificationSummary", "StoreKit sandbox 摘要"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "public struct ProBoundaryEvidenceSummary", "免费版 / Pro 边界事件摘要"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "accessDecision(for feature: PremiumFeature)", "Store 访问决策入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "remainingFreeUses(for feature: PremiumFeature)", "Store 免费额度展示"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "proUpgradeRequirements", "Store 升级说明入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "proStatusSummary", "Store Pro 状态摘要"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "proSandboxVerificationSummary", "Store sandbox 核验摘要"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "consumeFeatureUse(_ feature: PremiumFeature)", "免费额度消耗入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "canStartFeatureUse(_ feature: PremiumFeature)", "使用前拦截入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "recordProFeatureBlock", "Pro 阻断提示记录"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "consumeFeatureUse(.onlinePublishing)", "线上发布额度消耗"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "consumeFeatureUse(.batchPublishing)", "批量发布额度消耗"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "canStartFeatureUse(.aiRequest)", "AI 请求使用前拦截"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsProTabFactory.swift", "proStatusSummary", "设置页 Pro 状态"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsProTabFactory.swift", "proSandboxVerificationSummary", "设置页 sandbox 核验"),
        ("Sources/PersonalSitePublisherMac/Views/ProSandboxVerificationSection.swift", "ProBoundaryEvidenceRow", "设置页边界事件摘要"),
        ("Sources/PersonalSitePublisherMac/Views/ProBenefitsSection.swift", "PremiumFeature.allCases", "设置页付费功能列表"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsProTabFactory.swift", "proUpgradeRequirements", "设置页升级说明列表"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "purchasePro(store: store)", "购买入口"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "restorePro(store: store)", "恢复购买入口"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "proMonetizationAuditReport", "Pro 审核清单复制"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "externalVerificationEvidenceMarkdown", "StoreKit 外部证据复制"),
        ("Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift", "externalVerificationRecordingCommandMarkdown", "StoreKit 记录命令复制"),
        ("Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift", "externalVerificationRecordingCommandMarkdown", "StoreKit 记录命令模板"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testFreePlanAllowsLimitedAIRequestsAndBlocksOnlinePublishing", "免费额度阻断测试"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testStoreExposesUpgradeRequirementsForSettingsAndGates", "Store 升级说明测试"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProEntitlementAllowsPremiumFeaturesWithoutConsumingFreeUsage", "Pro 不消耗额度测试"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testBlockedAIChatSendDoesNotAppendUserMessage", "AI 阻断不改对话测试"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testBlockedPremiumFeatureRecordsUpgradeNoticeAndUnlockClearsIt", "阻断提示和解锁清理测试"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testSilentStoreKitEntitlementCheckUpdatesTimestampWithoutUserMessage", "静默权益检查测试"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryRequiresBoundaryEventEvidenceBeforeVerified", "边界事件证据测试"),
        ("Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift", "testProSandboxVerificationSummaryBuildsRecordingCommand", "StoreKit 记录命令测试"),
      ]
  
      let missing = evaluateSourceChecks(sourceChecks, root: root).missing
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "pro-boundary",
          category: .productReadiness,
          title: "免费版 / Pro 边界",
          status: .blocked,
          message: "Pro 边界源码缺少 \(missing.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Models/MonetizationModels.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/SettingsProTabFactory.swift, Sources/PersonalSitePublisherMac/Views/SettingsStoreActions.swift, Sources/PersonalSitePublisherMac/Views/ProSettingsView.swift, Tests/PublishingWorkbenchCoreTests/MonetizationTests.swift"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "pro-boundary",
        category: .productReadiness,
        title: "免费版 / Pro 边界",
        status: .passed,
        message: "AI 请求、GitHub/GitLab 线上发布和批量发布都有额度、升级原因、下一步说明、源码拦截、设置入口和回归测试。",
        evidence: requirements.map(\.checklistLine).joined(separator: "\n")
      )
    }
  

  private func evaluateSourceChecks(
    _ checks: [ReleaseEvidenceSourceCheck],
    root: URL
  ) -> ReleaseEvidenceSourceEvaluation {
    var missing: [String] = []
    var evidencePaths: Set<String> = []

    for check in checks {
      let matchedPaths = check.relativePaths.filter { relativePath in
        sourceText(relativePath, root: root).contains(check.needle)
      }

      if matchedPaths.isEmpty {
        missing.append(check.label)
        evidencePaths.formUnion(check.relativePaths)
      } else {
        evidencePaths.formUnion(matchedPaths)
      }
    }

    return ReleaseEvidenceSourceEvaluation(
      missing: missing,
      evidencePaths: evidencePaths.sorted()
    )
  }

  private func evaluateSourceChecks(
    _ checks: [(relativePath: String, needle: String, label: String)],
    root: URL
  ) -> ReleaseEvidenceSourceEvaluation {
    evaluateSourceChecks(
      checks.map { check in
        ReleaseEvidenceSourceCheck(
          anyOf: ReleaseEvidenceSourceManifest.expandedPaths(
            for: check.relativePath,
            needle: check.needle
          ),
          check.needle,
          check.label
        )
      },
      root: root
    )
  }

  private func sourceText(_ relativePath: String, root: URL) -> String {
    (try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
  }

  private func relativePath(_ url: URL, from root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath) else {
      return path
    }
    return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}
