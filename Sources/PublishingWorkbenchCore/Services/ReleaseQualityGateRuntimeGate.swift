import Foundation

struct ReleaseQualityGateRuntimeGate {
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func items(root: URL, files: [URL]) -> [ReleaseQualityGateItem] {
    [
      runtimeBootstrapItem(root: root),
      runtimeAutomationItem(root: root, files: files),
      cleanRuntimeEvidenceItem(root: root),
      privacySupportCopyItem(root: root),
    ]
  }
    private func runtimeBootstrapItem(root: URL) -> ReleaseQualityGateItem {
      let script = root.appendingPathComponent("script/build_and_run.sh")
      let exists = fileManager.fileExists(atPath: script.path)
      return ReleaseQualityGateItem(
        id: "runtime-bootstrap",
        category: .runtime,
        title: "运行入口",
        status: exists ? .passed : .blocked,
        message: exists ? "已提供 Codex/本地可复用的启动脚本。" : "缺少 script/build_and_run.sh，无法稳定复现 UI runtime。",
        evidence: exists ? "script/build_and_run.sh" : nil
      )
    }
  
    private func runtimeAutomationItem(root: URL, files: [URL]) -> ReleaseQualityGateItem {
      let candidates = [
        "script/check_ui_runtime.sh",
        "script/check_accessibility.sh",
        "script/check_runtime_ui.sh",
        "script/check_release_gate.sh"
      ]
      let found = candidates.first { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }
      let evidenceFiles = files.filter { file in
        let name = file.lastPathComponent.lowercased()
        return name.contains("accessibility") || name.contains("ui-runtime") || name.contains("runtime-ui")
      }
  
      if let found {
        return ReleaseQualityGateItem(
          id: "runtime-automation",
          category: .runtime,
          title: "Accessibility / UI 自动门禁",
          status: .passed,
          message: "已发现 runtime 或 accessibility 自动检查脚本。",
          evidence: found
        )
      }
  
      return ReleaseQualityGateItem(
        id: "runtime-automation",
        category: .runtime,
        title: "Accessibility / UI 自动门禁",
        status: evidenceFiles.isEmpty ? .blocked : .warning,
        message: evidenceFiles.isEmpty ? "缺少 UI runtime/accessibility 自动检查脚本或证据。" : "发现相关证据文件，但缺少统一可运行脚本。",
        evidence: evidenceFiles.map { relativePath($0, from: root) }.sorted().joined(separator: ", ").nilIfEmpty
      )
    }
  
    private func cleanRuntimeEvidenceItem(root: URL) -> ReleaseQualityGateItem {
      let evidencePath = "docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md"
      let checkScriptPath = "script/check_clean_runtime_evidence.sh"
      let recordScriptPath = "script/record_clean_runtime_evidence.sh"
      let testScriptPath = "script/test_clean_runtime_evidence.sh"
      let evidenceURL = root.appendingPathComponent(evidencePath)
      let requiredScripts = [checkScriptPath, recordScriptPath, testScriptPath]
      let missingScripts = requiredScripts.filter {
        !fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
      }
  
      guard fileManager.fileExists(atPath: evidenceURL.path) else {
        return ReleaseQualityGateItem(
          id: "clean-runtime-evidence",
          category: .runtime,
          title: "干净用户运行证据",
          status: .blocked,
          message: "缺少 \(evidencePath)，无法区分本地 package gate 和干净 macOS account 运行验收。",
          evidence: nil
        )
      }
  
      if !missingScripts.isEmpty {
        return ReleaseQualityGateItem(
          id: "clean-runtime-evidence",
          category: .runtime,
          title: "干净用户运行证据",
          status: .blocked,
          message: "缺少 \(missingScripts.joined(separator: "、"))，无法受控记录 clean runtime 验收。",
          evidence: evidencePath
        )
      }
  
      let sourceChecks: [(relativePath: String, needle: String, label: String)] = [
        ("Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift", "cleanRuntimeEvidenceRecordingCommandMarkdown", "clean runtime 记录命令模板"),
        ("Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift", "cleanRuntimeEvidenceRecordingCommandMarkdown", "Store clean runtime 命令入口"),
        ("Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift", "store.cleanRuntimeEvidenceRecordingCommandMarkdown", "上架页 clean runtime 复制按钮"),
        ("Tests/PublishingWorkbenchCoreTests/ReleaseQualityGateServiceTests.swift", "testReleaseReportProvidesCleanRuntimeAndArchiveRecordingCommands", "记录命令测试"),
      ]
      let missingSourceChecks = sourceChecks.compactMap { check -> String? in
        let sourceText = (try? String(contentsOf: root.appendingPathComponent(check.relativePath), encoding: .utf8)) ?? ""
        return sourceText.contains(check.needle) ? nil : check.label
      }
      if !missingSourceChecks.isEmpty {
        return ReleaseQualityGateItem(
          id: "clean-runtime-evidence",
          category: .runtime,
          title: "干净用户运行证据",
          status: .blocked,
          message: "clean runtime 证据闭环缺少 \(missingSourceChecks.joined(separator: "、"))。",
          evidence: "Sources/PublishingWorkbenchCore/Services/ReleaseQualityGateService.swift, Sources/PublishingWorkbenchCore/Stores/WorkbenchStore.swift, Sources/PersonalSitePublisherMac/Views/ReleaseQualityGateDetailView.swift"
        )
      }
  
      let text = (try? String(contentsOf: evidenceURL, encoding: .utf8)) ?? ""
      let status = cleanRuntimeEvidenceStatus(in: text)
      if !status.privateEvidenceTitles.isEmpty {
        return ReleaseQualityGateItem(
          id: "clean-runtime-evidence",
          category: .runtime,
          title: "干净用户运行证据",
          status: .blocked,
          message: "clean runtime Evidence 含有疑似私密内容：\(status.privateEvidenceTitles.joined(separator: "、"))。",
          evidence: evidencePath
        )
      }
      if !status.emptyCheckedTitles.isEmpty {
        return ReleaseQualityGateItem(
          id: "clean-runtime-evidence",
          category: .runtime,
          title: "干净用户运行证据",
          status: .blocked,
          message: "clean runtime 已勾选项缺少 Evidence：\(status.emptyCheckedTitles.joined(separator: "、"))。",
          evidence: evidencePath
        )
      }
      if status.missingTitles.isEmpty && status.completedCount == status.requiredCount {
        return ReleaseQualityGateItem(
          id: "clean-runtime-evidence",
          category: .runtime,
          title: "干净用户运行证据",
          status: .passed,
          message: "已记录 clean macOS account 或等价测试用户的启动、隐私锁/设置/工作区和 accessibility smoke 证据。",
          evidence: evidencePath
        )
      }
      return ReleaseQualityGateItem(
        id: "clean-runtime-evidence",
        category: .runtime,
        title: "干净用户运行证据",
        status: .warning,
        message: "clean runtime 证据模板已就绪，仍有 \(status.requiredCount - status.completedCount) 项未完成。",
        evidence: evidencePath
      )
    }
  
    private struct CleanRuntimeEvidenceStatus {
      var requiredCount: Int
      var completedCount: Int
      var missingTitles: [String]
      var emptyCheckedTitles: [String]
      var privateEvidenceTitles: [String]
    }
  
    private func cleanRuntimeEvidenceStatus(in text: String) -> CleanRuntimeEvidenceStatus {
      let requiredTitles = [
        "App launched from `script/build_and_run.sh --verify` on a clean macOS account or equivalent test user.",
        "First launch, privacy lock, settings, and workspace switching were verified without exposing private content.",
        "Keyboard navigation, focus visibility, VoiceOver labels, and primary commands were smoke checked in the running app.",
      ]
      let privateEvidencePattern = #"(/Users/|/Volumes/|file:///Users/|file:///Volumes/|github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[ \t]*Bearer[ \t]+[A-Za-z0-9._-]{20,}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|Apple[ \t]*ID|TeamIdentifier=|Receipt[ \t]*ID|receipt[ \t]*id|private article|私人文章|私密文章)"#
      let lines = text.components(separatedBy: .newlines)
      var found: [String: (checked: Bool, evidence: String)] = [:]
  
      for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- [") else { continue }
        let checked: Bool
        let title: String
        if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
          checked = true
          title = String(trimmed.dropFirst("- [x] ".count))
        } else if trimmed.hasPrefix("- [ ] ") {
          checked = false
          title = String(trimmed.dropFirst("- [ ] ".count))
        } else {
          continue
        }
        guard requiredTitles.contains(title) else { continue }
        var evidence = ""
        if index + 1 < lines.count {
          let evidenceLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
          if evidenceLine.hasPrefix("Evidence:") {
            evidence = String(evidenceLine.dropFirst("Evidence:".count))
              .trimmingCharacters(in: .whitespaces)
          }
        }
        found[title] = (checked, evidence)
      }
  
      let missingTitles = requiredTitles.filter { found[$0] == nil }
      let emptyCheckedTitles = requiredTitles.filter { title in
        guard let item = found[title] else { return false }
        return item.checked && item.evidence.isEmpty
      }
      let privateEvidenceTitles = requiredTitles.filter { title in
        guard let evidence = found[title]?.evidence, !evidence.isEmpty else { return false }
        return evidence.range(of: privateEvidencePattern, options: .regularExpression) != nil
      }
      let completedCount = requiredTitles.filter { title in
        guard let item = found[title] else { return false }
        return item.checked && !item.evidence.isEmpty
      }.count
  
      return CleanRuntimeEvidenceStatus(
        requiredCount: requiredTitles.count,
        completedCount: completedCount,
        missingTitles: missingTitles,
        emptyCheckedTitles: emptyCheckedTitles,
        privateEvidenceTitles: privateEvidenceTitles
      )
    }
  
    private func privacySupportCopyItem(root: URL) -> ReleaseQualityGateItem {
      let script = root.appendingPathComponent("script/check_privacy_support_copy.sh")
      let copy = root.appendingPathComponent("docs/privacy-support-copy.md")
      let privacyModel = root.appendingPathComponent("Sources/PublishingWorkbenchCore/Models/PrivacyProtectionModels.swift")
      let contentView = root.appendingPathComponent("Sources/PersonalSitePublisherMac/Views/ContentView.swift")
      let sharedViews = root.appendingPathComponent("Sources/PersonalSitePublisherMac/Views/SharedViews.swift")
      let seoTests = root.appendingPathComponent("Tests/PublishingWorkbenchCoreTests/SEOAuditServiceTests.swift")
  
      var missing: [String] = []
      if !fileManager.fileExists(atPath: script.path) {
        missing.append("check_privacy_support_copy.sh")
      }
      if !fileManager.fileExists(atPath: copy.path) {
        missing.append("privacy-support-copy.md")
      }
  
      let copyText = (try? String(contentsOf: copy, encoding: .utf8)) ?? ""
      let requiredTerms = [
        "privacy lock",
        "launch protection",
        "background auto lock",
        "Private-content masking",
        "private article titles",
        "local paths",
        "access tokens",
        "authorization headers",
        "private article body text",
        "support requests",
        "redacted screenshots",
        "online publishing",
        "AI requests",
        "StoreKit",
      ]
      let lowercasedCopy = copyText.lowercased()
      missing.append(contentsOf: requiredTerms.compactMap { term in
        lowercasedCopy.contains(term.lowercased()) ? nil : term
      })
  
      if copyText.range(
        of: #"(/Users/|/Volumes/|file:///Users/|file:///Volumes/)"#,
        options: .regularExpression
      ) != nil {
        missing.append("本地路径 redaction")
      }
      if copyText.range(
        of: #"(github_pat_|ghp_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,})"#,
        options: .regularExpression
      ) != nil {
        missing.append("Token redaction")
      }
  
      let sourceChecks: [(URL, String, String)] = [
        (privacyModel, "requiresUnlockOnLaunch", "启动解锁模型"),
        (privacyModel, "locksWhenInactive", "后台锁定模型"),
        (privacyModel, "masksPrivateContent", "私密内容遮挡模型"),
        (contentView, "lockPrivacyIfNeededForInactiveScene", "后台锁定入口"),
        (sharedViews, "privacy-lock-overlay", "隐私锁 accessibility 标识"),
        (seoTests, "私密文章不输出预览图", "私密 SEO/social 预览保护测试"),
      ]
      for (file, needle, label) in sourceChecks {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !text.contains(needle) {
          missing.append(label)
        }
      }
  
      if !missing.isEmpty {
        return ReleaseQualityGateItem(
          id: "privacy-support-copy",
          category: .appStore,
          title: "隐私政策 / 支持文案",
          status: .blocked,
          message: "隐私/支持文案门禁缺少 \(missing.prefix(5).joined(separator: "、"))\(missing.count > 5 ? "…" : "")。",
          evidence: [relativePath(copy, from: root), relativePath(script, from: root)].joined(separator: ", ")
        )
      }
  
      return ReleaseQualityGateItem(
        id: "privacy-support-copy",
        category: .appStore,
        title: "隐私政策 / 支持文案",
        status: .passed,
        message: "隐私/支持文案已覆盖隐私锁、后台锁定、私密内容遮挡、支持请求 redaction 和外部服务边界。",
        evidence: "docs/privacy-support-copy.md, script/check_privacy_support_copy.sh"
      )
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
