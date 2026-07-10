import Foundation

extension ReleaseQualityGateReport {
  public func appStoreChecklistCoverage(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> ReleaseAppStoreChecklistCoverageSummary {
    let checkedTasks = appStoreChecklistTasks.filter(\.isChecked)
    let uncheckedTasks = appStoreChecklistTasks.filter { !$0.isChecked }
    let evidenceBackedTasks = uncheckedTasks.compactMap { task -> ReleaseAppStoreChecklistEvidenceCoverage? in
      guard let evidence = checklistEvidence(for: task, records: records) else {
        return nil
      }
      return ReleaseAppStoreChecklistEvidenceCoverage(task: task, evidence: evidence)
    }
    let evidenceBackedIDs = Set(evidenceBackedTasks.map(\.task.id))
    let missingTasks = uncheckedTasks.filter { !evidenceBackedIDs.contains($0.id) }
    return ReleaseAppStoreChecklistCoverageSummary(
      totalCount: appStoreChecklistTasks.count,
      checkedCount: checkedTasks.count,
      evidenceBackedTasks: evidenceBackedTasks,
      missingTasks: missingTasks
    )
  }

  public func strictReadinessSummary(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> ReleaseStrictReadinessSummary {
    var actions: [ReleaseStrictReadinessAction] = []

    if !missingScreenshotRequirements.isEmpty {
      let missingIDs = missingScreenshotRequirements.prefix(4).map(\.id).joined(separator: "、")
      let suffix = missingScreenshotRequirements.count > 4 ? "…" : ""
      actions.append(
        ReleaseStrictReadinessAction(
          id: "app-store-screenshots",
          title: "采集 App Store 截图",
          message: "仍缺 \(missingScreenshotRequirements.count) 张截图：\(missingIDs)\(suffix)",
          command: "./script/capture_app_screenshots.sh",
          priority: .high
        )
      )
    }

    let externalCoverage = externalVerificationCoverage(records: records)
    if !externalVerificationItems.isEmpty
      && (!externalVerificationEvidenceFileStatus.isComplete || !externalCoverage.isComplete) {
      let title = externalVerificationEvidenceFileStatus.privacyFindings.isEmpty
        ? "补齐外部验收证据"
        : "清理外部验收证据包"
      let coverageMessage = externalCoverage.isComplete
        ? externalVerificationEvidenceFileStatus.message
        : externalCoverage.message
      actions.append(
        ReleaseStrictReadinessAction(
          id: "external-verification",
          title: title,
          message: coverageMessage,
          command: "./script/check_external_verification_evidence.sh",
          priority: .high
        )
      )
    }

    let checklistCoverage = appStoreChecklistCoverage(records: records)
    if !appStoreChecklistTasks.isEmpty && !checklistCoverage.isFullyCoveredByChecklistOrEvidence {
      actions.append(
        ReleaseStrictReadinessAction(
          id: "app-store-checklist",
          title: "完成 App Store checklist 人工项",
          message: checklistCoverage.message,
          command: "open APP_STORE_CHECKLIST.md",
          priority: .medium
        )
      )
    }

    if actions.isEmpty && !isReadyForAppStore {
      let issueCount = blockingItems.count + warningItems.count
      actions.append(
        ReleaseStrictReadinessAction(
          id: "release-gate-items",
          title: "处理剩余上架门禁项",
          message: "仍有 \(issueCount) 个本地化、runtime、截图、App Store 或产品边界门禁项需要处理。",
          command: "./script/check_release_gate.sh --strict",
          priority: .medium
        )
      )
    }

    if actions.isEmpty {
      return ReleaseStrictReadinessSummary(
        title: "严格发布门禁可执行",
        message: "截图、外部验收证据包、App Store checklist 和本地 release gate 当前都有可验证证据。运行 strict gate 做最终确认。",
        actions: []
      )
    }

    return ReleaseStrictReadinessSummary(
      title: "严格发布仍缺 \(actions.count) 类证据",
      message: "先补齐这些证据，再运行 ./script/check_release_gate.sh --strict；不要用普通构建结果替代外部验收。",
      actions: actions
    )
  }

  public func appStoreChecklistMarkdownApplyingEvidence(
    to markdown: String,
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> ReleaseAppStoreChecklistWritebackResult {
    let coverage = appStoreChecklistCoverage(records: records)
    let evidenceByTaskTitle = Dictionary(
      coverage.evidenceBackedTasks.map { ($0.task.title, $0.evidence) },
      uniquingKeysWith: { first, _ in first }
    )
    guard !evidenceByTaskTitle.isEmpty else {
      return ReleaseAppStoreChecklistWritebackResult(markdown: markdown, updatedCount: 0)
    }

    var updatedCount = 0
    let updatedLines = markdown.components(separatedBy: "\n").flatMap { line -> [String] in
      let leadingWhitespace = String(line.prefix { $0 == " " || $0 == "\t" })
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("- [ ]") else {
        return [line]
      }
      let title = String(trimmed.dropFirst("- [ ]".count)).trimmedForPublishing
      guard let evidence = evidenceByTaskTitle[title] else {
        return [line]
      }

      updatedCount += 1
      return [
        "\(leadingWhitespace)- [x] \(title)",
        "\(leadingWhitespace)  Evidence: \(evidence)"
      ]
    }

    return ReleaseAppStoreChecklistWritebackResult(
      markdown: updatedLines.joined(separator: "\n"),
      updatedCount: updatedCount
    )
  }

  public func appStoreChecklistManualCommandMarkdown(
    for task: ReleaseAppStoreChecklistTask
  ) -> String {
    let sections = appStoreChecklistManualCommandSections(for: task)
    var lines = [
      "# App Store Checklist Task Command",
      "",
      "- Section: \(task.sectionTitle ?? "Unsectioned")",
      "- Task: \(task.title)",
      "",
      "Use this only after performing the real verification. Keep tokens, authorization headers, local filesystem paths, private article text, and personal account identifiers out of evidence files.",
    ]

    for section in sections {
      lines.append("")
      lines.append("## \(section.title)")
      lines.append("")
      lines.append(section.body)
    }

    lines.append("")
    lines.append("## Verify Checklist State")
    lines.append("")
    lines.append("```sh")
    lines.append("script/sync_app_store_checklist.sh --dry-run")
    lines.append("script/check_release_gate.sh --strict")
    lines.append("```")
    return lines.joined(separator: "\n")
  }

  private func appStoreChecklistManualCommandSections(
    for task: ReleaseAppStoreChecklistTask
  ) -> [(title: String, body: String)] {
    let title = task.title.lowercased()

    if title.contains("bundle identifier")
      || title.contains("version")
      || title.contains("build number")
      || title.contains("minimum macos")
      || title.contains("sandbox entitlements") {
      return [
        ("Metadata Gate", fencedShell(["script/check_app_store_metadata.sh"])),
      ]
    }

    if title.contains("signing team")
      || title.contains("hardened runtime")
      || title.contains("clean release archive")
      || title.contains("clean checkout")
      || title.contains("validate the archive")
      || title.contains("app store connect")
      || title.contains("transporter") {
      return [
        ("Archive Evidence", appStoreArchiveValidationRecordingCommandMarkdown),
      ]
    }

    if title.contains("script/build_and_run.sh") || title.contains("clean macos account") {
      return [
        ("Clean Runtime Evidence", cleanRuntimeEvidenceRecordingCommandMarkdown),
      ]
    }

    if title.contains("capture writing")
      || title.contains("release gate screens")
      || title.contains("screenshots contain no private")
      || title.contains("local tokens")
      || title.contains("personal paths") {
      return [
        ("Screenshot Capture", fencedShell([
          "script/check_app_store_screenshot_capture_readiness.sh",
          "script/capture_app_screenshots.sh --auto-window --force-relaunch",
          "script/check_screenshots.sh",
          "script/check_screenshot_privacy.sh",
          "script/record_app_store_screenshot_evidence.sh --execute",
        ])),
      ]
    }

    if title.contains("storekit") || title.contains("free quota") {
      return [
        ("StoreKit Evidence", externalVerificationRecordingCommandMarkdown(for: "storekit-sandbox")),
      ]
    }

    if title.contains("github direct") {
      return [
        ("GitHub/GitLab Live Matrix", remotePublishLiveVerificationCommandMarkdown),
        ("GitHub Direct Evidence", externalVerificationRecordingCommandMarkdown(for: "github-direct-publish")),
        ("GitHub PR Evidence", externalVerificationRecordingCommandMarkdown(for: "github-review-publish")),
      ]
    }

    if title.contains("gitlab direct") {
      return [
        ("GitHub/GitLab Live Matrix", remotePublishLiveVerificationCommandMarkdown),
        ("GitLab Direct Evidence", externalVerificationRecordingCommandMarkdown(for: "gitlab-direct-publish")),
        ("GitLab MR Evidence", externalVerificationRecordingCommandMarkdown(for: "gitlab-review-publish")),
      ]
    }

    if title.contains("remote conflict")
      || title.contains("pending/offline")
      || title.contains("deployment checks")
      || title.contains("rollback guidance") {
      return [
        ("Remote Recovery Evidence", externalVerificationRecordingCommandMarkdown(for: "remote-conflict-deployment-rollback")),
      ]
    }

    return [
      ("Manual Evidence", fencedShell([
        "script/sync_app_store_checklist.sh --dry-run",
      ])),
    ]
  }

  private func fencedShell(_ commands: [String]) -> String {
    (["```sh"] + commands + ["```"]).joined(separator: "\n")
  }

  private func checklistEvidence(
    for task: ReleaseAppStoreChecklistTask,
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> String? {
    let title = task.title.lowercased()
    let passedGateIDs = Set(items.filter { $0.status == .passed }.map(\.id))
    let recordedItemIDs = Set(records.filter(isChecklistEligibleExternalVerificationRecord).map(\.itemID))

    func passedGate(_ id: String, _ evidence: String) -> String? {
      passedGateIDs.contains(id) ? evidence : nil
    }

    func recorded(_ ids: [String], _ evidence: String) -> String? {
      ids.allSatisfy { recordedItemIDs.contains($0) } ? evidence : nil
    }

    if title.contains("signing team") || title.contains("hardened runtime") {
      return passedGate("app-store-archive-readiness", "App Store 归档准备门禁已通过")
    }
    if title.contains("clean release archive") || title.contains("clean checkout") {
      return passedGate("app-store-archive-readiness", "已记录 clean checkout 生成 Release archive 的归档验证证据")
    }
    if title.contains("validate the archive")
      || title.contains("app store connect")
      || title.contains("transporter") {
      return passedGate("app-store-archive-readiness", "已记录 Transporter/App Store Connect 归档验证证据")
    }
    if title.contains("bundle identifier")
      || title.contains("version")
      || title.contains("build number")
      || title.contains("minimum macos")
      || title.contains("sandbox entitlements") {
      return passedGate("app-store-metadata", "App Store 元数据门禁已通过")
    }
    if title.contains("localization catalog") || title.contains("localizable.strings") {
      return passedGate("localization-catalog", "本地化资源门禁已通过")
    }
    if title.contains("simplified chinese") || title.contains("english copy") {
      return passedGate("localization-languages", "中英语言覆盖门禁已通过")
    }
    if title.contains("localization gate") {
      return passedGate("localization-automation", "本地化自动门禁已通过")
    }
    if title.contains("script/build_and_run.sh") || title.contains("clean macos account") {
      return passedGate("clean-runtime-evidence", "已记录 clean macOS account 或等价测试用户运行证据")
    }
    if title.contains("ui runtime") || title.contains("accessibility gate") {
      return passedGate("runtime-automation", "UI runtime/accessibility 门禁已通过")
    }
    if title.contains("keyboard navigation")
      || title.contains("focus rings")
      || title.contains("voiceover labels")
      || title.contains("privacy lock behavior") {
      return passedGate("runtime-automation", "UI runtime/accessibility 门禁已通过")
    }
    if title.contains("screenshot capture") || title.contains("verification script") {
      return passedGate("screenshot-gate", "截图采集/验证门禁已覆盖")
    }
    if title.contains("capture writing") || title.contains("release gate screens") {
      return recorded(["app-store-screenshots"], "已记录 App Store 截图外部验收证据")
    }
    if title.contains("screenshots contain no private")
      || title.contains("local tokens")
      || title.contains("personal paths") {
      return passedGate("screenshot-privacy", "截图隐私门禁已通过")
    }
    if title.contains("privacy policy")
      || title.contains("support copy")
      || title.contains("private-content behavior") {
      return passedGate("privacy-support-copy", "隐私/支持文案门禁已通过")
    }
    if title.contains("storekit") || title.contains("free quota") {
      return recorded(["storekit-sandbox"], "已记录 StoreKit sandbox 外部验收证据")
    }
    if title.contains("upgrade copy") {
      return passedGate("pro-boundary", "免费版/Pro 边界门禁已通过")
    }
    if title.contains("github direct") {
      return recorded(
        ["github-direct-publish", "github-review-publish"],
        "已记录 GitHub 直接提交和 PR 外部验收证据"
      )
    }
    if title.contains("gitlab direct") {
      return recorded(
        ["gitlab-direct-publish", "gitlab-review-publish"],
        "已记录 GitLab 直接提交和 MR 外部验收证据"
      )
    }
    if title.contains("remote conflict")
      || title.contains("pending/offline")
      || title.contains("deployment checks")
      || title.contains("rollback guidance") {
      return recorded(
        ["remote-conflict-deployment-rollback"],
        "已记录远端冲突、部署和回滚外部验收证据"
      )
    }
    return nil
  }
}

