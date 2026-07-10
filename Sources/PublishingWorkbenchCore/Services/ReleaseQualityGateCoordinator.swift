import Foundation

struct ReleaseQualityGateCoordinator {
  private let fileManager: FileManager
  private let localizationGate: ReleaseQualityGateLocalizationGate
  private let runtimeGate: ReleaseQualityGateRuntimeGate
  private let screenshotGate: ReleaseQualityGateScreenshotGate
  private let appStoreMetadataGate: ReleaseQualityGateAppStoreMetadataGate
  private let productReadinessGate: ReleaseQualityGateProductReadinessGate

  private let requiredScreenshotIDs = [
    "writing",
    "ai-chat",
    "sync-api-publish",
    "seo-social-preview",
    "deployment-status",
    "maintenance",
    "general-drafts",
    "pro-settings",
    "privacy-lock",
    "release-readiness",
  ]

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.localizationGate = ReleaseQualityGateLocalizationGate(fileManager: fileManager)
    self.runtimeGate = ReleaseQualityGateRuntimeGate(fileManager: fileManager)
    self.screenshotGate = ReleaseQualityGateScreenshotGate(fileManager: fileManager)
    self.appStoreMetadataGate = ReleaseQualityGateAppStoreMetadataGate(fileManager: fileManager)
    self.productReadinessGate = ReleaseQualityGateProductReadinessGate(fileManager: fileManager)
  }

  func report(
    projectRoot: URL,
    workspaceSections: [WorkspaceSection],
    hasPrivacyProtection: Bool,
    hasProBoundary: Bool,
    proUpgradeRequirements: [ProUpgradeRequirement]?,
    hasDeploymentStatusPanel: Bool,
    hasAIChatWorkspace: Bool,
    productCapabilities: ReleaseProductCapabilityCoverage?
  ) -> ReleaseQualityGateReport {
    let root = projectRoot.standardizedFileURL
    let files = allFiles(under: root)
    let screenshotResult = screenshotGate.evaluate(
      root: root,
      files: files,
      requiredScreenshotIDs: requiredScreenshotIDs
    )
    let screenshotRequirements = screenshotResult.requirements
    let externalVerificationItems = externalVerificationItems()
    let externalEvidenceFileStatus = externalVerificationEvidenceFileStatus(
      root: root,
      items: externalVerificationItems
    )
    let appStoreEvaluation = appStoreMetadataGate.evaluate(root: root, files: files)
    let appStoreChecklistTasks = appStoreEvaluation.tasks
    let capabilities = productCapabilities ?? ReleaseProductCapabilityCoverage(
      deploymentStatusPanel: hasDeploymentStatusPanel,
      privacyProtection: hasPrivacyProtection,
      proBoundary: hasProBoundary,
      aiChatWorkspace: hasAIChatWorkspace
    )
    var items: [ReleaseQualityGateItem] = []

    items.append(contentsOf: localizationGate.items(root: root, files: files))
    items.append(contentsOf: runtimeGate.items(root: root, files: files))
    items.append(contentsOf: screenshotResult.items)
    items.append(contentsOf: appStoreEvaluation.items)
    items.append(
      contentsOf: productReadinessGate.items(
        root: root,
        files: files,
        workspaceSections: workspaceSections,
        capabilities: capabilities,
        proUpgradeRequirements: proUpgradeRequirements
          ?? MonetizationService().upgradeRequirements(state: .default)
      )
    )

    return ReleaseQualityGateReport(
      projectRootPath: root.path,
      items: items,
      screenshotRequirements: screenshotRequirements,
      externalVerificationItems: externalVerificationItems,
      appStoreChecklistTasks: appStoreChecklistTasks,
      externalVerificationEvidenceFileStatus: externalEvidenceFileStatus
    )
  }

  private func externalVerificationEvidenceFileStatus(
    root: URL,
    items: [ReleaseExternalVerificationItem]
  ) -> ReleaseExternalVerificationEvidenceFileStatus {
    let relativePath = "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md"
    let fileURL = root.appendingPathComponent(relativePath)
    let requiredIDs = items.map(\.id)
    guard fileManager.fileExists(atPath: fileURL.path),
          let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return ReleaseExternalVerificationEvidenceFileStatus(
        relativePath: relativePath,
        isPresent: false,
        totalCount: requiredIDs.count,
        completedItemIDs: [],
        missingItemIDs: requiredIDs,
        privacyFindings: []
      )
    }

    let completedIDs = requiredIDs.filter { id in
      externalVerificationEvidenceFileItemIsComplete(itemID: id, text: text)
    }
    let completedIDSet = Set(completedIDs)
    let missingIDs = requiredIDs.filter { !completedIDSet.contains($0) }
    var privacyFindings: [String] = []
    if text.range(of: #"(/Users/|/Volumes/|file:///Users/|file:///Volumes/)"#, options: .regularExpression) != nil {
      privacyFindings.append("本地路径")
    }
    if text.range(
      of: #"(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})"#,
      options: .regularExpression
    ) != nil {
      privacyFindings.append("Token 或授权头")
    }

    return ReleaseExternalVerificationEvidenceFileStatus(
      relativePath: relativePath,
      isPresent: true,
      totalCount: requiredIDs.count,
      completedItemIDs: completedIDs,
      missingItemIDs: missingIDs,
      privacyFindings: privacyFindings
    )
  }

  private func externalVerificationEvidenceFileItemIsComplete(
    itemID: String,
    text: String
  ) -> Bool {
    let escapedID = NSRegularExpression.escapedPattern(for: itemID)
    guard text.range(
      of: #"(?m)^- \[[xX]\]\s+`\#(escapedID)`"#,
      options: .regularExpression
    ) != nil else {
      return false
    }
    return requiredExternalVerificationFileLabels(for: itemID).allSatisfy { text.contains($0) }
  }

  private func requiredExternalVerificationFileLabels(for itemID: String) -> [String] {
    switch itemID {
    case "remote-conflict-deployment-rollback":
      return [
        "Remote conflict preview:",
        "Pending/offline state:",
        "Deployment retry:",
        "Rollback package:",
      ]
    case "storekit-sandbox":
      return [
        "StoreKit product lookup:",
        "StoreKit purchase:",
        "StoreKit restore:",
        "StoreKit free quota:",
        "StoreKit boundary events:",
      ]
    case "app-store-screenshots":
      return [
        "Screenshot set:",
        "Screenshot privacy gate:",
        "Screenshot strict gate:",
      ]
    default:
      return []
    }
  }

  private func externalVerificationItems() -> [ReleaseExternalVerificationItem] {
    [
      ReleaseExternalVerificationItem(
        id: "github-direct-publish",
        title: "GitHub API 直接提交",
        purpose: "验证 least-privilege GitHub Token 可以完成线上直接提交并写入发布记录。",
        evidenceToCollect: "测试仓库 URL、Token 权限截图或文字记录、提交 SHA、发布记录截图、部署检查结果。",
        steps: [
          "使用只授予目标测试仓库 contents write / pull requests read 的 GitHub Token。",
          "在 Sync 工作区完成 Token 保存和权限检查，确认仓库名、默认分支和可写状态匹配当前 Profile。",
          "选择一篇可删除测试文章，确认远端同路径冲突预览为空或已处理。",
          "使用线上直接提交发布，记录返回的 commit SHA 和变更文件列表。",
          "刷新部署状态，确认 GitHub Pages / Actions 或自定义状态端点给出发布后结论。",
          "从发布记录复制报告，确认 release ledger 包含远端提交和后续行动项。"
        ]
      ),
      ReleaseExternalVerificationItem(
        id: "github-review-publish",
        title: "GitHub PR 发布",
        purpose: "验证线上发布可以创建 review 分支和 Pull Request，并保留回滚/部署追踪。",
        evidenceToCollect: "PR URL、provider API 返回的 PR number/state、review 分支名、目标分支、发布记录、部署状态、回滚草稿。",
        steps: [
          "将 Profile 发布策略切换为线上 PR/MR。",
          "使用 GitHub Token 完成权限检查，确认具备 contents write 和 pull requests write。",
          "发布测试文章，确认 review 分支名和目标分支符合预期。",
          "打开生成的 PR URL，确认标题、正文和文件变更正确。",
          "合并或关闭测试 PR 后刷新部署状态和发布记录。",
          "复制回滚 PR 草稿，确认回滚分支、标题和正文不包含 Token 或本地路径。"
        ]
      ),
      ReleaseExternalVerificationItem(
        id: "gitlab-direct-publish",
        title: "GitLab API 直接提交",
        purpose: "验证 least-privilege GitLab Token 可以通过 API 直接提交目标项目。",
        evidenceToCollect: "GitLab 项目 URL、Token scope 记录、commit SHA、发布记录、Pipeline 或 Pages 状态。",
        steps: [
          "使用只面向测试项目且具备 read_repository / write_repository 或 api 最小可行权限的 GitLab Token。",
          "在 Sync 工作区完成 Token 保存和权限检查，确认 namespace/project 与当前 Profile 匹配。",
          "确认远端同路径冲突预览已经审阅。",
          "使用线上直接提交发布测试文章，记录 commit SHA 和变更路径。",
          "刷新 GitLab Pipeline / Pages 或自定义部署状态。",
          "确认失败或离线状态会进入 release ledger 的待处理行动队列。"
        ]
      ),
      ReleaseExternalVerificationItem(
        id: "gitlab-review-publish",
        title: "GitLab MR 发布",
        purpose: "验证线上发布可以创建 GitLab review 分支和 Merge Request。",
        evidenceToCollect: "MR URL、provider API 返回的 MR iid/state、source branch、target branch、发布记录、部署检查和回滚草稿。",
        steps: [
          "将 Profile 发布策略切换为线上 PR/MR。",
          "使用 GitLab Token 完成权限检查，确认项目可写。",
          "发布测试文章，确认 source branch 与 target branch 正确。",
          "打开 MR URL，确认标题、正文和文件变更正确。",
          "刷新部署状态，确认 Pipeline 状态进入发布记录。",
          "复制回滚 MR 草稿，确认回滚路径和远端链接正确。"
        ]
      ),
      ReleaseExternalVerificationItem(
        id: "remote-conflict-deployment-rollback",
        title: "远端冲突、部署和回滚",
        purpose: "验证冲突阻断、失败/离线 pending、部署轮询和回滚入口形成闭环。",
        evidenceToCollect: "冲突预览截图、阻断提示、pending 行动项、部署状态截图、回滚计划。",
        steps: [
          "在远端手动修改同一路径文章，回到 Mac 版生成线上发布预览。",
          "确认直接提交被阻断，并且核对包列出远端冲突路径。",
          "制造一次部署未知或失败状态，确认发布记录显示 pending/retry 行动项。",
          "使用发布记录中的重新检查刷新部署状态。",
          "复制回滚计划和 PR/MR 草稿，确认包含分支、目标文件和远端链接。",
          "删除测试文章或回滚测试仓库，确认不会留下真实内容污染。"
        ]
      ),
      ReleaseExternalVerificationItem(
        id: "storekit-sandbox",
        title: "StoreKit sandbox 购买与恢复",
        purpose: "验证 Pro 产品、购买、恢复和免费额度边界在 sandbox 中可用。",
        evidenceToCollect: "StoreKit 产品 ID、购买结果、恢复结果、Pro 状态摘要、免费额度阻断提示。",
        steps: [
          "使用 StoreKit 配置或 App Store sandbox 账号读取 personal.site.publisher.pro。",
          "在免费版触发 AI、线上发布和批量发布边界，确认升级提示包含购买或恢复。",
          "完成一次购买，确认权益来源显示 StoreKit，免费额度不再消耗。",
          "清除本地权益后执行恢复购买，确认可以重新应用 Pro。",
          "无可恢复购买时确认不会误标记为 Pro。",
          "复制 StoreKit 沙盒核验摘要作为验收记录。"
        ]
      ),
      ReleaseExternalVerificationItem(
        id: "app-store-screenshots",
        title: "App Store 截图与隐私审计",
        purpose: "验证十张上架截图齐全，并且没有泄露 Token、本地路径或私密内容。",
        evidenceToCollect: "十张截图文件、截图隐私 gate 输出、严格 release gate 输出。",
        steps: [
          "按上架门禁中的截图采集计划逐项运行 capture_app_screenshots.sh。",
          "确认 writing、AI、sync/API publish、SEO/social、deployment、maintenance、general drafts、Pro、privacy、release gate 十张截图齐全。",
          "运行 check_screenshot_privacy.sh，确认截图不包含 Token、授权头、本地路径或私密正文。",
          "运行 ./script/check_release_gate.sh --strict，确认截图 strict gate 通过。",
          "把截图和 gate 输出保存为上传前证据。"
        ]
      )
    ]
  }

  private func allFiles(under root: URL) -> [URL] {
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      return []
    }

    return enumerator.compactMap { element in
      guard let url = element as? URL else { return nil }
      let path = relativePath(url, from: root)
      if path.hasPrefix(".build/") || path.hasPrefix(".git/") {
        return nil
      }
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
      return values?.isRegularFile == true ? url : nil
    }
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
