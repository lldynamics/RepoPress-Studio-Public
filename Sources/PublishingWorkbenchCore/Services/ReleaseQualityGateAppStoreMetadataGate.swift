import Foundation

struct ReleaseQualityGateAppStoreMetadataGate {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func evaluate(
    root: URL,
    files: [URL]
  ) -> (items: [ReleaseQualityGateItem], tasks: [ReleaseAppStoreChecklistTask]) {
    let items: [ReleaseQualityGateItem] = [
      appStoreChecklistItem(root: root),
      appStoreMetadataItem(root: root, files: files),
      appStoreArchiveReadinessItem(root: root),
      releaseGateAutomationItem(root: root),
    ]
    let tasks = appStoreChecklistTasks(root: root)
    return (items, tasks)
  }
    private func appStoreChecklistItem(root: URL) -> ReleaseQualityGateItem {
      let checklistURL = root.appendingPathComponent("APP_STORE_CHECKLIST.md")
      guard fileManager.fileExists(atPath: checklistURL.path) else {
        return ReleaseQualityGateItem(
          id: "app-store-checklist",
          category: .appStore,
          title: "App Store checklist",
          status: .blocked,
          message: "缺少 APP_STORE_CHECKLIST.md，无法形成上架前逐项门禁。",
          evidence: nil
        )
      }
  
      let text = (try? String(contentsOf: checklistURL, encoding: .utf8)) ?? ""
      let uncheckedItems = uncheckedChecklistItems(in: text)
      let uncheckedCount = uncheckedItems.count
      let message: String
      let evidence: String
      if uncheckedItems.isEmpty {
        message = "上架清单没有未完成项。"
        evidence = "APP_STORE_CHECKLIST.md"
      } else {
        let preview = uncheckedItems.prefix(3).joined(separator: "；")
        message = "上架清单仍有 \(uncheckedCount) 个未完成项：\(preview)\(uncheckedCount > 3 ? "…" : "")"
        evidence = "APP_STORE_CHECKLIST.md · " + uncheckedItems.joined(separator: " | ")
      }
      return ReleaseQualityGateItem(
        id: "app-store-checklist",
        category: .appStore,
        title: "App Store checklist",
        status: uncheckedCount == 0 ? .passed : .blocked,
        message: message,
        evidence: evidence
      )
    }
  
    private func appStoreChecklistTasks(root: URL) -> [ReleaseAppStoreChecklistTask] {
      let checklistURL = root.appendingPathComponent("APP_STORE_CHECKLIST.md")
      guard fileManager.fileExists(atPath: checklistURL.path),
            let text = try? String(contentsOf: checklistURL, encoding: .utf8) else {
        return []
      }
  
      var sectionTitle: String?
      var taskCountsByID: [String: Int] = [:]
      return text.components(separatedBy: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("## ") {
          sectionTitle = String(trimmed.dropFirst("## ".count)).trimmedForPublishing.nilIfEmpty
          return nil
        }
        guard trimmed.hasPrefix("- [") else {
          return nil
        }
        let lowercased = trimmed.lowercased()
        let isChecked: Bool
        if lowercased.hasPrefix("- [x]") {
          isChecked = true
        } else if lowercased.hasPrefix("- [ ]") {
          isChecked = false
        } else {
          return nil
        }
        let title = String(trimmed.dropFirst("- [ ]".count)).trimmedForPublishing
        guard !title.isEmpty else {
          return nil
        }
        let baseID = checklistTaskID(for: sectionTitle, title: title)
        let index = taskCountsByID[baseID, default: 0]
        taskCountsByID[baseID] = index + 1
        let id = index == 0 ? baseID : "\(baseID)-\(index + 1)"
        return ReleaseAppStoreChecklistTask(
          id: id,
          sectionTitle: sectionTitle,
          title: title,
          isChecked: isChecked
        )
      }
    }
  
    private func checklistTaskID(for sectionTitle: String?, title: String) -> String {
      let raw = [sectionTitle, title]
        .compactMap { $0?.nilIfEmpty }
        .joined(separator: " ")
        .lowercased()
      let allowed = CharacterSet.alphanumerics
      let slug = raw.unicodeScalars.reduce(into: "") { partial, scalar in
        if allowed.contains(scalar) {
          partial.append(String(scalar))
        } else if !partial.hasSuffix("-") {
          partial.append("-")
        }
      }
      return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).nilIfEmpty ?? UUID().uuidString
    }
  
    private func appStoreMetadataItem(root: URL, files: [URL]) -> ReleaseQualityGateItem {
      let scriptPath = "script/check_app_store_metadata.sh"
      let scriptURL = root.appendingPathComponent(scriptPath)
      let entitlements = files
        .filter { $0.pathExtension == "entitlements" }
        .map { relativePath($0, from: root) }
        .sorted()
      let entitlementMissingChecks = appStoreEntitlementMissingChecks(in: files)
      let buildScriptURL = root.appendingPathComponent("script/build_and_run.sh")
      let buildScriptText = (try? String(contentsOf: buildScriptURL, encoding: .utf8)) ?? ""
      let missingBuildMetadata = appStoreBuildMetadataMissingChecks(in: buildScriptText)
  
      guard fileManager.fileExists(atPath: scriptURL.path) else {
        return ReleaseQualityGateItem(
          id: "app-store-metadata",
          category: .appStore,
          title: "App Store 元数据门禁",
          status: .blocked,
          message: "缺少 \(scriptPath)，无法自动验证 bundle id、版本号、图标、显示名、最低系统和 sandbox entitlements。",
          evidence: entitlements.joined(separator: ", ").nilIfEmpty
        )
      }
  
      guard !entitlements.isEmpty else {
        return ReleaseQualityGateItem(
          id: "app-store-metadata",
          category: .appStore,
          title: "App Store 元数据门禁",
          status: .blocked,
          message: "缺少 App Store entitlements 文件，无法验证 sandbox、网络和用户选择文件访问权限。",
          evidence: scriptPath
        )
      }
  
      guard entitlementMissingChecks.isEmpty else {
        return ReleaseQualityGateItem(
          id: "app-store-metadata",
          category: .appStore,
          title: "App Store 元数据门禁",
          status: .blocked,
          message: "App Store entitlements 缺少 \(entitlementMissingChecks.joined(separator: "、"))。",
          evidence: entitlements.joined(separator: ", ")
        )
      }
  
      guard missingBuildMetadata.isEmpty else {
        return ReleaseQualityGateItem(
          id: "app-store-metadata",
          category: .appStore,
          title: "App Store 元数据门禁",
          status: .blocked,
          message: "打包脚本缺少 \(missingBuildMetadata.joined(separator: "、")) 元数据。",
          evidence: "script/build_and_run.sh"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "app-store-metadata",
        category: .appStore,
        title: "App Store 元数据门禁",
        status: .passed,
        message: "已提供可复现脚本验证 bundle id、版本号、图标、显示名、最低系统和 sandbox entitlements。",
        evidence: ([scriptPath] + entitlements).joined(separator: ", ")
      )
    }
  
    private func appStoreBuildMetadataMissingChecks(in scriptText: String) -> [String] {
      var missing: [String] = []
      if !scriptText.contains("CFBundleIdentifier") {
        missing.append("Bundle ID")
      }
      if !scriptText.contains("CFBundleShortVersionString") {
        missing.append("版本号")
      }
      if !scriptText.contains("CFBundleVersion") {
        missing.append("Build number")
      }
      if !scriptText.contains("CFBundleIconFile") {
        missing.append("App icon")
      }
      if !scriptText.contains("CFBundleDisplayName") {
        missing.append("显示名")
      }
      if !scriptText.contains("LSMinimumSystemVersion") {
        missing.append("最低系统")
      }
      return missing
    }
  
    private func appStoreArchiveReadinessItem(root: URL) -> ReleaseQualityGateItem {
      let scriptPath = "script/check_app_store_archive_readiness.sh"
      let scriptURL = root.appendingPathComponent(scriptPath)
      let evidencePath = "docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md"
      let evidenceURL = root.appendingPathComponent(evidencePath)
  
      guard fileManager.fileExists(atPath: scriptURL.path) else {
        return ReleaseQualityGateItem(
          id: "app-store-archive-readiness",
          category: .appStore,
          title: "App Store 归档准备门禁",
          status: .blocked,
          message: "缺少 \(scriptPath)，无法区分本地 .app 包检查、签名/hardened runtime 和 App Store Connect/Transporter 外部验证。",
          evidence: nil
        )
      }
  
      guard fileManager.fileExists(atPath: evidenceURL.path) else {
        return ReleaseQualityGateItem(
          id: "app-store-archive-readiness",
          category: .appStore,
          title: "App Store 归档准备门禁",
          status: .blocked,
          message: "缺少 \(evidencePath)，无法记录 clean archive、distribution signing 和 Transporter/App Store Connect 验证结果。",
          evidence: scriptPath
        )
      }
  
      let scriptText = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
      let requiredNeedles: [(needle: String, name: String)] = [
        ("script/check_app_store_metadata.sh", "metadata gate"),
        ("codesign", "签名验证"),
        ("hardened runtime", "hardened runtime 提示"),
        ("--strict", "strict 模式"),
        ("APP_STORE_ARCHIVE_VALIDATION.md", "归档验证证据模板"),
      ]
      let missingNeedles = requiredNeedles
        .filter { !scriptText.contains($0.needle) }
        .map(\.name)
  
      guard missingNeedles.isEmpty else {
        return ReleaseQualityGateItem(
          id: "app-store-archive-readiness",
          category: .appStore,
          title: "App Store 归档准备门禁",
          status: .blocked,
          message: "\(scriptPath) 缺少 \(missingNeedles.joined(separator: "、")) 检查。",
          evidence: scriptPath
        )
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "appStoreArchiveValidationRecordingCommandMarkdown", "归档验证记录命令模板"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "externalVerificationEnvironmentPreparationCommandMarkdown", "私有 env 准备命令模板"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "externalVerificationEnvironmentFieldChecklistMarkdown", "私有 env 字段清单模板"),
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "ReleaseExternalVerificationEnvStatusReport", "私有 env 状态报告解析"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "appStoreArchiveValidationRecordingCommandMarkdown", "Store 归档验证命令入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "externalVerificationEnvironmentPreparationCommandMarkdown", "Store 私有 env 准备命令入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "externalVerificationEnvironmentFieldChecklistMarkdown", "Store 私有 env 字段清单入口"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "externalVerificationEnvironmentStatusReport", "Store 私有 env 状态报告入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.appStoreArchiveValidationRecordingCommandMarkdown", "上架页归档验证复制按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.externalVerificationEnvironmentPreparationCommandMarkdown", "上架页私有 env 准备复制按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.externalVerificationEnvironmentFieldChecklistMarkdown", "上架页私有 env 字段清单按钮"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "externalVerificationEnvironmentStatusSection", "上架页私有 env 状态摘要"),
        ("script/record_app_store_build_metadata_evidence.sh", "App Store build metadata", "本地 build metadata 证据记录脚本"),
        ("script/test_app_store_build_metadata_evidence.sh", "build metadata evidence test", "本地 build metadata 证据自测"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testReleaseReportProvidesCleanRuntimeAndArchiveRecordingCommands", "记录命令测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testReleaseReportProvidesPrivateEnvironmentPreparationCommands", "私有 env 准备命令测试"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testExternalVerificationEnvStatusReportParsesRedactedMarkdownByFile", "私有 env 状态报告解析测试"),
      ]
      let missingSourceChecks = sourceChecks.compactMap { check -> String? in
        let sourceText = (try? String(contentsOf: root.appendingPathComponent(check.relativePath), encoding: .utf8)) ?? ""
        return sourceText.contains(check.needle) ? nil : check.label
      }
      if !missingSourceChecks.isEmpty {
        return ReleaseQualityGateItem(
          id: "app-store-archive-readiness",
          category: .appStore,
          title: "App Store 归档准备门禁",
          status: .blocked,
          message: "App Store 归档验证闭环缺少 \(missingSourceChecks.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift"
        )
      }
  
      let evidenceText = (try? String(contentsOf: evidenceURL, encoding: .utf8)) ?? ""
      let uncheckedItems = uncheckedChecklistItems(in: evidenceText)
      guard uncheckedItems.isEmpty else {
        return ReleaseQualityGateItem(
          id: "app-store-archive-readiness",
          category: .appStore,
          title: "App Store 归档准备门禁",
          status: .warning,
          message: "本地归档准备脚本已就绪，但 clean archive、签名/hardened runtime 或 Transporter/App Store Connect 验证仍有 \(uncheckedItems.count) 项未记录。",
          evidence: "\(scriptPath), \(evidencePath)"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "app-store-archive-readiness",
        category: .appStore,
        title: "App Store 归档准备门禁",
        status: .passed,
        message: "已提供脚本区分本地包检查、签名/hardened runtime 和 App Store Connect/Transporter 外部归档验证证据。",
        evidence: "\(scriptPath), \(evidencePath)"
      )
    }
  
    private func appStoreEntitlementMissingChecks(in files: [URL]) -> [String] {
      let entitlementText = files
        .filter { $0.pathExtension == "entitlements" }
        .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
      var missing: [String] = []
      if !entitlementText.contains("com.apple.security.app-sandbox") {
        missing.append("App Sandbox")
      }
      if !entitlementText.contains("com.apple.security.network.client") {
        missing.append("Network Client")
      }
      if !entitlementText.contains("com.apple.security.files.user-selected.read-write") {
        missing.append("User Selected Read/Write")
      }
      return missing
    }
  
    private func releaseGateAutomationItem(root: URL) -> ReleaseQualityGateItem {
      let scriptURL = root.appendingPathComponent("script/check_release_gate.sh")
      guard fileManager.fileExists(atPath: scriptURL.path) else {
        return ReleaseQualityGateItem(
          id: "release-automation",
          category: .appStore,
          title: "总发布门禁脚本",
          status: .blocked,
          message: "缺少 script/check_release_gate.sh，无法一键复现本地化、UI runtime、StoreKit、截图、外部验收和测试门禁。",
          evidence: nil
        )
      }
  
      let text = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
      let requiredChecks = [
        "script/check_localization_gate.sh": "本地化",
        "script/check_app_store_metadata.sh": "App Store 元数据",
        "script/check_app_store_archive_readiness.sh": "App Store 归档准备",
        "script/record_app_store_archive_validation_evidence.sh": "App Store 归档证据受控录入",
        "script/test_app_store_archive_validation_evidence.sh": "App Store 归档证据结构自测",
        "script/check_ui_runtime.sh": "UI runtime",
        "script/check_clean_runtime_evidence.sh": "干净用户运行证据",
        "script/record_clean_runtime_evidence.sh": "干净用户运行证据受控录入",
        "script/test_clean_runtime_evidence.sh": "干净用户运行证据自测",
        "script/check_privacy_support_copy.sh": "隐私/支持文案",
        "script/test_privacy_support_copy.sh": "隐私/支持文案自测",
        "script/check_storekit.sh": "StoreKit",
        "script/record_storekit_sandbox_evidence.sh": "StoreKit sandbox 证据受控录入",
        "script/test_storekit_sandbox_evidence.sh": "StoreKit sandbox 证据结构自测",
        "script/export_release_evidence_bundle.sh": "本地证据包导出",
        "script/verify_remote_publish_live.sh": "远端真实 API 发布验证",
        "script/test_remote_publish_live_verifier.sh": "远端真实 API 发布验证自测",
        "script/verify_remote_publish_live_matrix.sh": "远端真实 API 发布矩阵验证",
        "script/test_remote_publish_live_matrix.sh": "远端真实 API 发布矩阵自测",
        "script/record_external_verification_evidence.sh": "外部证据受控录入",
        "script/record_remote_recovery_evidence.sh": "远端冲突部署回滚证据受控录入",
        "script/test_remote_recovery_evidence.sh": "远端冲突部署回滚证据结构自测",
        "script/test_external_verification_evidence.sh": "外部证据结构自测",
        "script/check_screenshot_surface_map.sh": "截图场景源码映射",
        "script/test_screenshot_surface_map.sh": "截图场景源码映射自测",
        "script/test_screenshot_manifest_sync.sh": "截图 manifest 同步自测",
        "script/sync_screenshot_manifest_status.sh": "截图 manifest 状态同步",
        "script/test_app_store_checklist_sync_evidence.sh": "App Store checklist 证据同步自测",
        "script/test_release_gate_strict_reporting.sh": "strict 发布阻塞汇总自测",
        "script/sync_app_store_checklist.sh": "App Store checklist 证据同步",
        "script/check_screenshots.sh": "截图",
        "script/check_external_verification_evidence.sh": "外部验收证据",
        "script/check_screenshot_privacy.sh": "截图隐私",
        "script/test_screenshot_privacy.sh": "截图隐私自测",
        "swift test": "Swift 测试",
      ]
      let missing = requiredChecks
        .filter { key, _ in
          if !text.contains(key) {
            return true
          }
          guard key == "script/export_release_evidence_bundle.sh"
            || key == "script/record_app_store_archive_validation_evidence.sh"
            || key == "script/test_app_store_archive_validation_evidence.sh"
            || key == "script/check_clean_runtime_evidence.sh"
            || key == "script/record_clean_runtime_evidence.sh"
            || key == "script/test_clean_runtime_evidence.sh"
            || key == "script/check_privacy_support_copy.sh"
            || key == "script/test_privacy_support_copy.sh"
            || key == "script/record_storekit_sandbox_evidence.sh"
            || key == "script/test_storekit_sandbox_evidence.sh"
            || key == "script/verify_remote_publish_live.sh"
            || key == "script/test_remote_publish_live_verifier.sh"
            || key == "script/verify_remote_publish_live_matrix.sh"
            || key == "script/test_remote_publish_live_matrix.sh"
            || key == "script/record_external_verification_evidence.sh"
            || key == "script/record_remote_recovery_evidence.sh"
            || key == "script/test_remote_recovery_evidence.sh"
            || key == "script/test_external_verification_evidence.sh"
            || key == "script/check_screenshot_surface_map.sh"
            || key == "script/test_screenshot_surface_map.sh"
            || key == "script/test_screenshot_manifest_sync.sh"
            || key == "script/sync_screenshot_manifest_status.sh"
            || key == "script/test_screenshot_privacy.sh"
            || key == "script/test_app_store_checklist_sync_evidence.sh"
            || key == "script/test_release_gate_strict_reporting.sh"
            || key == "script/sync_app_store_checklist.sh"
          else {
            return false
          }
          return !fileManager.fileExists(atPath: root.appendingPathComponent(key).path)
        }
        .map(\.value)
        .sorted()
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "localReleaseEvidenceBundleMarkdown", "本地证据包 Markdown 生成"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "writeLocalReleaseEvidenceBundle", "Store 本地证据包写入入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.localReleaseEvidenceBundleMarkdown", "上架页复制本地证据包"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.writeLocalReleaseEvidenceBundle", "上架页写入本地证据包"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testStoreWritesRedactedLocalReleaseEvidenceBundle", "本地证据包 redaction 测试"),
      ]
      let missingSourceChecks = sourceChecks.compactMap { check -> String? in
        let sourceText = (try? String(contentsOf: root.appendingPathComponent(check.relativePath), encoding: .utf8)) ?? ""
        return sourceText.contains(check.needle) ? nil : check.label
      }
  
      if missing.isEmpty {
        if !missingSourceChecks.isEmpty {
          return ReleaseQualityGateItem(
            id: "release-automation",
            category: .appStore,
            title: "总发布门禁脚本",
            status: .blocked,
            message: "本地证据包导出缺少 \(missingSourceChecks.joined(separator: "、"))。",
            evidence: "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift, Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift"
          )
        }
        return ReleaseQualityGateItem(
          id: "release-automation",
          category: .appStore,
          title: "总发布门禁脚本",
          status: .passed,
          message: "总 release gate 已串联本地化、UI runtime、StoreKit、截图、外部验收、隐私和 Swift 测试。",
          evidence: "script/check_release_gate.sh"
        )
      }
  
      return ReleaseQualityGateItem(
        id: "release-automation",
        category: .appStore,
        title: "总发布门禁脚本",
        status: .blocked,
        message: "script/check_release_gate.sh 缺少 \(missing.joined(separator: "、")) 门禁调用。",
        evidence: "script/check_release_gate.sh"
      )
    }
  
    private func uncheckedChecklistItems(in text: String) -> [String] {
      text.components(separatedBy: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- [ ]") else {
          return nil
        }
        return String(trimmed.dropFirst("- [ ]".count)).trimmedForPublishing.nilIfEmpty
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
