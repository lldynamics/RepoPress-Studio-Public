import Foundation

extension ReleaseQualityGateReport {
  public var externalVerificationPlanMarkdown: String {
    var lines = [
      "# 外部发布验收计划",
      "",
      "- 项目：\(projectRootPath)",
      "- 验收项：\(externalVerificationItems.count)",
      "- 原则：使用最小权限 Token、测试仓库和可删除测试文章；不要在截图或报告中暴露 Token、授权头、本地路径或私密正文。",
      "",
    ]

    if externalVerificationItems.isEmpty {
      lines.append("- 当前报告没有外部验收项。")
    } else {
      lines.append(contentsOf: externalVerificationItems.map(\.checklistMarkdown))
    }

    return lines.joined(separator: "\n")
  }

  public var remotePublishLiveVerificationCommandMarkdown: String {
    [
      "# GitHub/GitLab Live Publish Verification Commands",
      "",
      "Use disposable test repositories and least-privilege tokens. Do not paste tokens, authorization headers, local filesystem paths, private article text, or personal account identifiers into evidence files.",
      "",
      "Optional private env setup: run `script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remote-publish` to copy `docs/release-evidence/remote-publish-live.env.example`, then fill and source `remote-publish-live.env` outside the repository.",
      "",
      "## Required Environment",
      "",
      "```sh",
      "export REMOTE_VERIFY_GITHUB_TOKEN=\"<github-token>\"",
      "export REMOTE_VERIFY_GITHUB_OWNER=\"<github-owner>\"",
      "export REMOTE_VERIFY_GITHUB_REPO=\"<github-test-repo>\"",
      "export REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER=\"Release ledger contains GitHub direct publish evidence.\"",
      "export REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER=\"Release ledger contains GitHub PR publish evidence.\"",
      "",
      "export REMOTE_VERIFY_GITLAB_TOKEN=\"<gitlab-token>\"",
      "export REMOTE_VERIFY_GITLAB_OWNER=\"<gitlab-owner-or-group>\"",
      "export REMOTE_VERIFY_GITLAB_REPO=\"<gitlab-test-project>\"",
      "export REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER=\"Release ledger contains GitLab direct publish evidence.\"",
      "export REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER=\"Release ledger contains GitLab MR publish evidence.\"",
      "```",
      "",
      "## Dry Run",
      "",
      "```sh",
      "script/verify_remote_publish_live_matrix.sh",
      "```",
      "",
      "## Execute And Record Evidence",
      "",
      "```sh",
      "script/verify_remote_publish_live_matrix.sh --execute",
      "```",
      "",
      "## Single Flow Commands",
      "",
      "```sh",
      "script/verify_remote_publish_live.sh --provider github --mode direct --execute",
      "script/verify_remote_publish_live.sh --provider github --mode review --execute",
      "script/verify_remote_publish_live.sh --provider gitlab --mode direct --execute",
      "script/verify_remote_publish_live.sh --provider gitlab --mode review --execute",
      "```",
    ].joined(separator: "\n")
  }

  public var externalVerificationEnvironmentPreparationCommandMarkdown: String {
    [
      "# External Verification Private Env Preparation",
      "",
      "Run this before live GitHub/GitLab, StoreKit sandbox, remote recovery, screenshot, or App Store archive validation. It copies repo templates to a private directory outside the repository with restrictive permissions.",
      "",
      "```sh",
      "script/print_remaining_external_verification.sh",
      "script/prepare_external_verification_envs.sh --dry-run",
      "script/check_external_verification_envs.sh --mode template",
      "script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remaining",
      "script/check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining",
      "script/check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md",
      "script/run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remaining --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md",
      "```",
      "",
      "Fill only the files copied by the prepare command, then follow the source lines it prints. Do not copy filled values back into `docs/release-evidence/*.env.example`.",
    ].joined(separator: "\n")
  }

  public var externalVerificationEnvironmentStatusReportCommandMarkdown: String {
    [
      "# External Verification Private Env Status Report",
      "",
      "Generate this after filling the private env files. The report is written outside the repository, uses mode 600, and is redacted to file names, target names, required variable names, and validation messages.",
      "",
      "```sh",
      "script/check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md",
      "stat -f '%Lp %N' /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md",
      "sed -n '1,220p' /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md",
      "```",
      "",
      "Use the report to finish missing fields before running `script/run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target remaining --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md --execute`.",
    ].joined(separator: "\n")
  }

  public func externalVerificationEnvironmentFieldChecklistMarkdown(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> String {
    let targets = remainingExternalVerificationRunnerTargets(records: records)
    var lines = [
      "# External Verification Private Env Field Checklist",
      "",
      "Use this checklist after copying the env templates to `/private/tmp/personal-site-publisher-release-envs`. Keep real tokens, account names, repository names, sandbox account output, and App Store validation details out of the repository.",
      "",
      "## Current Targets",
      ""
    ]

    if targets.isEmpty {
      lines.append("- [x] No remaining private env targets.")
    } else {
      for target in targets {
        lines.append("- [ ] \(target.title) (`\(target.id)`) via `/private/tmp/personal-site-publisher-release-envs/\(target.environmentFilename)`")
        lines.append("  - Purpose: \(target.purpose)")
        if !target.checklistItems.isEmpty {
          lines.append("  - Checklist: \(target.checklistItems.joined(separator: "；"))")
        }
        if target.requiredEnvironmentKeys.isEmpty {
          lines.append("  - Required fields: none")
        } else {
          lines.append("  - Required fields:")
          for key in target.requiredEnvironmentKeys {
            lines.append("    - [ ] `\(key)`")
          }
        }
        lines.append("  - Dry run: `\(target.dryRunCommand)`")
        lines.append("  - Execute only after real external verification: `\(target.executeCommand)`")
        lines.append("  - Execute + checklist sync + strict gate:")
        lines.append("    ```sh")
        lines.append(contentsOf: target.executeAndFinalizeCommand.components(separatedBy: .newlines).map { "    \($0)" })
        lines.append("    ```")
      }
    }

    lines.append("")
    lines.append("## Status Report")
    lines.append("")
    lines.append("```sh")
    lines.append("script/check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md")
    lines.append("sed -n '1,220p' /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md")
    lines.append("```")
    lines.append("")
    lines.append("Do not run the `--execute` commands until the redacted status report has no placeholder or empty-value issues.")
    return lines.joined(separator: "\n")
  }

  public func remainingManualVerificationCommandMarkdown(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> String {
    let strictSummary = strictReadinessSummary(records: records)
    let checklistCoverage = appStoreChecklistCoverage(records: records)
    let externalCoverage = externalVerificationCoverage(records: records)
    var lines = [
      "# Remaining App Store Manual Verification Commands",
      "",
      "Use these commands as a release operator checklist after performing the real external checks. Do not paste tokens, authorization headers, local filesystem paths, private article text, or personal account identifiers into evidence files.",
      "",
      "## Current Status",
      "",
      "- Strict readiness: \(strictSummary.title)",
      "- Screenshots: \(capturedScreenshotRequirements.count)/\(screenshotRequirements.count)",
      "- External verification: \(externalCoverage.recordedCount)/\(externalCoverage.totalCount)",
      "- App Store checklist: \(checklistCoverage.coveredCount)/\(checklistCoverage.totalCount)",
    ]

    let missingOnlinePublishItems = externalCoverage.missingItems.filter {
      $0.id == "github-direct-publish"
        || $0.id == "github-review-publish"
        || $0.id == "gitlab-direct-publish"
        || $0.id == "gitlab-review-publish"
    }
    let privateEnvRunnerTargets = remainingExternalVerificationRunnerTargets(records: records)
    if !privateEnvRunnerTargets.isEmpty {
      lines.append("")
      lines.append("## Private Env Target Runner")
      lines.append("")
      lines.append("Prepare and fill only the copied env files for targets that still need real external evidence, then run the remaining target bundle.")
      lines.append("")
      lines.append("```sh")
      lines.append("script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target remaining")
      lines.append("script/check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining")
      lines.append("script/check_external_verification_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --mode filled --target remaining --report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md")
      for target in privateEnvRunnerTargets {
        lines.append(target.dryRunCommand)
        lines.append(target.executeCommand)
      }
      lines.append("```")

      lines.append("")
      lines.append("## Target Checklist Map")
      lines.append("")
      for target in privateEnvRunnerTargets {
        let checklistText = target.checklistItems.isEmpty
          ? "No mapped checklist item."
          : target.checklistItems.joined(separator: "; ")
        lines.append("- \(target.title) (`\(target.id)`): \(checklistText)")
      }

      lines.append("")
      lines.append("## Env Field Checklist")
      lines.append("")
      for target in privateEnvRunnerTargets {
        let requiredKeys = target.requiredEnvironmentKeys.isEmpty
          ? "No target-specific required fields."
          : target.requiredEnvironmentKeys.map { "`\($0)`" }.joined(separator: ", ")
        lines.append("- \(target.environmentFilename): \(requiredKeys)")
      }

      lines.append("")
      lines.append("## Private Env Status Report")
      lines.append("")
      lines.append(externalVerificationEnvironmentStatusReportCommandMarkdown)
    }

    if releaseGateItemStatus(id: "clean-runtime-evidence") != .passed {
      lines.append("")
      lines.append("## Clean Runtime Evidence")
      lines.append("")
      lines.append(cleanRuntimeEvidenceRecordingCommandMarkdown)
    }

    if releaseGateItemStatus(id: "app-store-archive-readiness") != .passed {
      lines.append("")
      lines.append("## App Store Archive Validation")
      lines.append("")
      lines.append(appStoreArchiveValidationRecordingCommandMarkdown)
    }

    if !missingScreenshotRequirements.isEmpty
      || externalCoverage.missingItems.contains(where: { $0.id == "app-store-screenshots" }) {
      lines.append("")
      lines.append("## App Store Screenshots")
      lines.append("")
      lines.append(appStoreScreenshotEvidenceRecordingCommandMarkdown)
    }

    if !missingOnlinePublishItems.isEmpty {
      lines.append("")
      lines.append("## GitHub/GitLab Live Publish Matrix")
      lines.append("")
      lines.append(remotePublishLiveVerificationCommandMarkdown)
    }

    let missingExternalRecordItems = externalCoverage.missingItems.filter { item in
      item.id != "app-store-screenshots"
    }
    if !missingExternalRecordItems.isEmpty {
      lines.append("")
      lines.append("## Missing External Evidence Records")
      for item in missingExternalRecordItems {
        lines.append("")
        lines.append(externalVerificationRecordingCommandMarkdown(for: item.id))
      }
    }

    if !checklistCoverage.isFullyCoveredByChecklistOrEvidence {
      lines.append("")
      lines.append("## App Store Checklist Sync")
      lines.append("")
      lines.append("```sh")
      lines.append("script/sync_app_store_checklist.sh --dry-run")
      lines.append("script/sync_app_store_checklist.sh --execute")
      lines.append("```")
    }

    lines.append("")
    lines.append("## Final Strict Gate")
    lines.append("")
    lines.append("```sh")
    lines.append(strictSummary.strictCommand)
    lines.append("```")
    return lines.joined(separator: "\n")
  }

  public func remainingExternalVerificationRunnerTargets(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> [ReleaseExternalVerificationRunnerTarget] {
    let externalCoverage = externalVerificationCoverage(records: records)
    let missingOnlinePublishItems = externalCoverage.missingItems.filter {
      $0.id == "github-direct-publish"
        || $0.id == "github-review-publish"
        || $0.id == "gitlab-direct-publish"
        || $0.id == "gitlab-review-publish"
    }
    var targetIDs: [String] = []
    if releaseGateItemStatus(id: "app-store-archive-readiness") != .passed {
      targetIDs.append("app-store-archive")
    }
    if !missingOnlinePublishItems.isEmpty {
      targetIDs.append("remote-publish")
    }
    if externalCoverage.missingItems.contains(where: { $0.id == "storekit-sandbox" }) {
      targetIDs.append("storekit")
    }
    if externalCoverage.missingItems.contains(where: { $0.id == "remote-conflict-deployment-rollback" }) {
      targetIDs.append("remote-recovery")
    }
    if externalCoverage.missingItems.contains(where: { $0.id == "app-store-screenshots" }) {
      targetIDs.append("app-store-screenshots")
    }
    return targetIDs.compactMap(externalVerificationRunnerTarget(for:))
  }

  private func externalVerificationRunnerTarget(
    for id: String
  ) -> ReleaseExternalVerificationRunnerTarget? {
    let metadata: (
      title: String,
      purpose: String,
      env: String,
      checklistItems: [String],
      requiredEnvironmentKeys: [String]
    )
    switch id {
    case "app-store-archive":
      metadata = (
        "App Store 归档验证",
        "记录 clean Release archive、distribution signing/hardened runtime 和 Transporter/App Store Connect 验证。",
        "app-store-archive-validation.env",
        [
          "Confirm distribution signing team and hardened runtime on the archived app.",
          "Produce a clean Release archive from a clean checkout.",
          "Validate the archive with App Store Connect or Transporter before upload.",
        ],
        [
          "APP_STORE_ARCHIVE_CLEAN_RELEASE_SUMMARY",
          "APP_STORE_ARCHIVE_SIGNING_RUNTIME_SUMMARY",
          "APP_STORE_ARCHIVE_TRANSPORTER_SUMMARY",
        ]
      )
    case "remote-publish":
      metadata = (
        "GitHub/GitLab 实测发布",
        "用一次 target 覆盖 GitHub direct/PR 与 GitLab direct/MR 的 disposable repository 实测。",
        "remote-publish-live.env",
        [
          "Verify GitHub direct commit and PR publishing with a least-privilege token.",
          "Verify GitLab direct commit and MR publishing with a least-privilege token.",
        ],
        [
          "REMOTE_VERIFY_GITHUB_TOKEN",
          "REMOTE_VERIFY_GITHUB_OWNER",
          "REMOTE_VERIFY_GITHUB_REPO",
          "REMOTE_VERIFY_GITHUB_DIRECT_RELEASE_LEDGER",
          "REMOTE_VERIFY_GITHUB_REVIEW_RELEASE_LEDGER",
          "REMOTE_VERIFY_GITLAB_TOKEN",
          "REMOTE_VERIFY_GITLAB_OWNER",
          "REMOTE_VERIFY_GITLAB_REPO",
          "REMOTE_VERIFY_GITLAB_DIRECT_RELEASE_LEDGER",
          "REMOTE_VERIFY_GITLAB_REVIEW_RELEASE_LEDGER",
        ]
      )
    case "storekit":
      metadata = (
        "StoreKit Sandbox",
        "记录产品加载、购买、恢复、免费额度和 Pro 边界事件 sandbox 证据。",
        "storekit-sandbox.env",
        [
          "Verify StoreKit product ID, purchase, restore, and free quota behavior in sandbox.",
        ],
        [
          "STOREKIT_PRODUCT_ID",
          "STOREKIT_SANDBOX_PRODUCT_LOOKUP_SUMMARY",
          "STOREKIT_SANDBOX_PURCHASE_SUMMARY",
          "STOREKIT_SANDBOX_RESTORE_SUMMARY",
          "STOREKIT_SANDBOX_FREE_QUOTA_SUMMARY",
          "STOREKIT_SANDBOX_BOUNDARY_EVENTS_SUMMARY",
        ]
      )
    case "remote-recovery":
      metadata = (
        "远端冲突/部署/回滚",
        "记录远端冲突预览、pending/offline 状态、部署重试和回滚包证据。",
        "remote-recovery.env",
        [
          "Verify remote conflict preview, pending/offline states, deployment checks, and rollback guidance.",
        ],
        [
          "REMOTE_RECOVERY_CONFLICT_PREVIEW_SUMMARY",
          "REMOTE_RECOVERY_PENDING_OFFLINE_SUMMARY",
          "REMOTE_RECOVERY_DEPLOYMENT_RETRY_SUMMARY",
          "REMOTE_RECOVERY_ROLLBACK_PACKAGE_SUMMARY",
        ]
      )
    case "app-store-screenshots":
      metadata = (
        "App Store 截图证据",
        "记录上架截图、截图隐私门禁和严格截图门禁证据。",
        "app-store-screenshots.env",
        [
          "Capture writing, AI chat, sync/API publish, SEO/social preview, deployment status, maintenance, general drafts, Pro, privacy lock, and release gate screens.",
          "Verify screenshots contain no private content, local tokens, or personal paths.",
        ],
        [
          "APP_STORE_SCREENSHOT_SET_SUMMARY",
          "APP_STORE_SCREENSHOT_PRIVACY_GATE_SUMMARY",
          "APP_STORE_SCREENSHOT_STRICT_GATE_SUMMARY",
        ]
      )
    default:
      return nil
    }

    let baseCommand = "script/run_external_verification_from_envs.sh --env-dir /private/tmp/personal-site-publisher-release-envs --target \(id) --env-status-report-file /private/tmp/personal-site-publisher-release-envs/ENV_STATUS.md"
    return ReleaseExternalVerificationRunnerTarget(
      id: id,
      title: metadata.title,
      purpose: metadata.purpose,
      environmentFilename: metadata.env,
      checklistItems: metadata.checklistItems,
      requiredEnvironmentKeys: metadata.requiredEnvironmentKeys,
      dryRunCommand: baseCommand,
      executeCommand: "\(baseCommand) --execute"
    )
  }

  public func externalVerificationRecordingCommandMarkdown(for itemID: String) -> String {
    guard let item = externalVerificationItems.first(where: { $0.id == itemID }) else {
      return "# External Verification Recording Command\n\nUnknown external verification item: \(itemID)"
    }

    var lines = [
      "# \(item.title) Evidence Recording Command",
      "",
      "Fill the placeholders with redacted evidence from disposable test repositories, sandbox accounts, or App Store validation output. Do not paste tokens, authorization headers, local filesystem paths, private article text, or personal account identifiers.",
      "",
    ]
    if let envTemplate = externalVerificationEnvironmentTemplatePath(for: itemID) {
      let privateEnvFilename = externalVerificationPrivateEnvironmentFilename(for: envTemplate)
      let targetArgument = externalVerificationEnvironmentPreparationTarget(for: itemID)
        .map { " --target \($0)" } ?? ""
      lines.append("Optional private env setup: run `script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs\(targetArgument)` to copy `\(envTemplate)`, then fill and source `\(privateEnvFilename)` outside the repository.")
      lines.append("")
    }
    lines.append(contentsOf: [
      "## Validate Recorder",
      "",
      "```sh",
      "script/record_external_verification_evidence.sh --dry-run",
      "```",
      "",
      "## Record This Item",
      "",
      "```sh",
    ])
    lines.append(contentsOf: externalVerificationRecordingCommandLines(for: itemID))
    lines.append("```")
    lines.append("")
    lines.append("## Verify")
    lines.append("")
    lines.append("```sh")
    lines.append("script/check_external_verification_evidence.sh")
    lines.append("script/check_release_gate.sh --strict")
    lines.append("```")
    return lines.joined(separator: "\n")
  }

  public func externalVerificationEnvironmentTemplatePath(for itemID: String) -> String? {
    switch itemID {
    case "github-direct-publish",
         "github-review-publish",
         "gitlab-direct-publish",
         "gitlab-review-publish":
      return "docs/release-evidence/remote-publish-live.env.example"
    case "remote-conflict-deployment-rollback":
      return "docs/release-evidence/remote-recovery.env.example"
    case "storekit-sandbox":
      return "docs/release-evidence/storekit-sandbox.env.example"
    case "app-store-screenshots":
      return "docs/release-evidence/app-store-screenshots.env.example"
    default:
      return nil
    }
  }

  private func externalVerificationPrivateEnvironmentFilename(for templatePath: String) -> String {
    let templateFilename = templatePath.split(separator: "/").last.map(String.init) ?? templatePath
    return templateFilename.replacingOccurrences(of: ".env.example", with: ".env")
  }

  private func externalVerificationEnvironmentPreparationTarget(for itemID: String) -> String? {
    switch itemID {
    case "github-direct-publish",
         "github-review-publish",
         "gitlab-direct-publish",
         "gitlab-review-publish":
      return "remote-publish"
    case "remote-conflict-deployment-rollback":
      return "remote-recovery"
    case "storekit-sandbox":
      return "storekit"
    case "app-store-screenshots":
      return "app-store-screenshots"
    default:
      return nil
    }
  }

  private func externalVerificationRecordingCommandLines(for itemID: String) -> [String] {
    switch itemID {
    case "github-direct-publish":
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item github-direct-publish \\",
        "  --summary \"GitHub direct publish verified on disposable test repository.\" \\",
        "  --token-scope \"Least-privilege contents write token was confirmed by GitHub API.\" \\",
        "  --commit-sha \"<redacted-test-commit-sha>\" \\",
        "  --deployment-status \"GitHub Pages, Actions, or custom endpoint reached the expected state.\" \\",
        "  --release-ledger \"Release ledger contains the GitHub online direct publish entry and deployment check.\" \\",
        "  --evidence-url \"https://github.com/<owner>/<repo>/commit/<sha>\" \\",
        "  --execute",
      ]
    case "github-review-publish":
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item github-review-publish \\",
        "  --summary \"GitHub PR publish verified on disposable test repository.\" \\",
        "  --pr-url \"https://github.com/<owner>/<repo>/pull/<number>\" \\",
        "  --provider-review-artifact \"GitHub Pull Request API returned number #<number>, state open, draft=false.\" \\",
        "  --review-branch \"<review-branch>\" \\",
        "  --target-branch \"<target-branch>\" \\",
        "  --file-changes \"Redacted disposable article files changed through the GitHub API.\" \\",
        "  --deployment-status \"GitHub Pages, Actions, or custom endpoint result was reviewed for the PR branch.\" \\",
        "  --release-ledger \"Release ledger contains the GitHub PR publish entry, review branch, and deployment check.\" \\",
        "  --rollback-draft \"Rollback PR draft includes branch, files, and revert path.\" \\",
        "  --execute",
      ]
    case "gitlab-direct-publish":
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item gitlab-direct-publish \\",
        "  --summary \"GitLab direct publish verified on disposable test project.\" \\",
        "  --token-scope \"Least-privilege project write token was confirmed by GitLab API.\" \\",
        "  --commit-sha \"<redacted-test-commit-sha>\" \\",
        "  --deployment-status \"GitLab Pipeline, Pages, or custom endpoint reached the expected state.\" \\",
        "  --release-ledger \"Release ledger contains the GitLab online direct publish entry and deployment check.\" \\",
        "  --evidence-url \"https://gitlab.com/<group>/<project>/-/commit/<sha>\" \\",
        "  --execute",
      ]
    case "gitlab-review-publish":
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item gitlab-review-publish \\",
        "  --summary \"GitLab MR publish verified on disposable test project.\" \\",
        "  --mr-url \"https://gitlab.com/<group>/<project>/-/merge_requests/<number>\" \\",
        "  --provider-review-artifact \"GitLab Merge Request API returned iid !<iid>, state opened, merge status available.\" \\",
        "  --source-branch \"<source-branch>\" \\",
        "  --target-branch \"<target-branch>\" \\",
        "  --file-changes \"Redacted disposable article files changed through the GitLab API.\" \\",
        "  --deployment-status \"GitLab Pipeline, Pages, or custom endpoint result was reviewed for the MR branch.\" \\",
        "  --release-ledger \"Release ledger contains the GitLab MR publish entry, source branch, and deployment check.\" \\",
        "  --rollback-draft \"Rollback MR draft includes branch, files, and revert path.\" \\",
        "  --execute",
      ]
    case "remote-conflict-deployment-rollback":
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item remote-conflict-deployment-rollback \\",
        "  --summary \"Remote conflict preview, pending deployment, retry, and rollback flow verified on disposable content.\" \\",
        "  --remote-conflict-preview \"Same-path remote edit was detected and direct publish was blocked or previewed before publish.\" \\",
        "  --pending-offline-state \"Failed or unknown deployment state stayed pending for retry in the release ledger.\" \\",
        "  --deployment-retry \"Deployment polling or manual retry refreshed the provider status.\" \\",
        "  --rollback-package \"Rollback package included branch, files, and PR/MR draft URL.\" \\",
        "  --execute",
      ]
    case "storekit-sandbox":
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item storekit-sandbox \\",
        "  --summary \"StoreKit sandbox purchase, restore, entitlement, and free quota boundary verified.\" \\",
        "  --storekit-product-lookup \"Sandbox loaded product personal.site.publisher.pro with localized price and copy.\" \\",
        "  --storekit-purchase \"Purchase completed and entitlement source changed to StoreKit.\" \\",
        "  --storekit-restore \"Restore reapplied Pro entitlement after clearing local state.\" \\",
        "  --storekit-free-quota \"Free quota boundary showed upgrade copy before purchase and no quota consumption after Pro unlock.\" \\",
        "  --storekit-boundary-events \"Recent Pro boundary events showed free-plan block before purchase and Pro no-quota allow after unlock.\" \\",
        "  --execute",
      ]
    case "app-store-screenshots":
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item app-store-screenshots \\",
        "  --summary \"Ten App Store screenshots captured and strict screenshot/privacy gates passed.\" \\",
        "  --screenshot-set \"Captured writing, AI chat, sync/API publish, SEO/social preview, deployment, maintenance, general drafts, Pro, privacy lock, and release readiness screens.\" \\",
        "  --screenshot-privacy-gate \"check_screenshot_privacy.sh passed with no local paths, tokens, or private article text.\" \\",
        "  --screenshot-strict-gate \"STRICT_SCREENSHOTS=1 check_screenshots.sh and strict release gate output were reviewed.\" \\",
        "  --execute",
      ]
    default:
      return [
        "script/record_external_verification_evidence.sh \\",
        "  --item \(itemID) \\",
        "  --summary \"<redacted verification summary>\" \\",
        "  --execute",
      ]
    }
  }

  public func externalVerificationEvidenceMarkdown(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> String {
    let recordsByItemID = Dictionary(grouping: records, by: \.itemID)
    let coverage = externalVerificationCoverage(records: records)
    var lines = [
      "# 外部发布验收证据",
      "",
      "- 项目：\(projectRootPath)",
      "- 已记录：\(coverage.recordedCount)/\(coverage.totalCount)",
      "- 状态：\(coverage.title)",
      "- 说明：\(coverage.message)",
      "",
    ]

    for item in externalVerificationItems {
      lines.append("## \(item.title)")
      if let itemRecords = recordsByItemID[item.id], !itemRecords.isEmpty {
        lines.append(contentsOf: itemRecords.sorted { $0.recordedAt > $1.recordedAt }.map(\.checklistLine))
      } else {
        lines.append("- [ ] 尚未记录验收证据。")
      }
      lines.append("")
    }

    return lines.joined(separator: "\n")
  }

  public func externalVerificationEvidenceFileMarkdown(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> String {
    let recordsByItemID = Dictionary(grouping: records, by: \.itemID)
    var lines = [
      "# External Verification Evidence",
      "",
      "Record only redacted evidence. Do not paste tokens, authorization headers, local filesystem paths, private article text, or personal account identifiers.",
      "",
      "## Required Evidence",
      "",
    ]

    for item in externalVerificationItems {
      let itemRecords = recordsByItemID[item.id]?.sorted { $0.recordedAt > $1.recordedAt } ?? []
      let marker = itemRecords.isEmpty ? " " : "x"
      let latestSummary = itemRecords.first?.summaryLines.first?.nilIfEmpty
      let evidence = latestSummary ?? item.evidenceToCollect
      lines.append("- [\(marker)] `\(item.id)` - \(item.title): \(evidence)")
    }

    lines.append("")
    lines.append("## Evidence Notes")
    lines.append("")

    if records.isEmpty {
      lines.append("Paste short redacted summaries below each completed item before changing `[ ]` to `[x]`.")
    } else {
      for item in externalVerificationItems {
        let itemRecords = recordsByItemID[item.id]?.sorted { $0.recordedAt > $1.recordedAt } ?? []
        guard !itemRecords.isEmpty else { continue }
        lines.append("### \(item.title)")
        for record in itemRecords {
          let summaryLines = record.summaryLines
          if let firstLine = summaryLines.first {
            let url = record.evidenceURL?.nilIfEmpty.map { " \($0)" } ?? ""
            lines.append("- \(firstLine)\(url)")
          }
          for line in summaryLines.dropFirst() {
            lines.append("- \(line)")
          }
        }
        lines.append("")
      }
    }

    return lines.joined(separator: "\n")
  }

  public func localReleaseEvidenceBundleMarkdown(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> String {
    let externalCoverage = externalVerificationCoverage(records: records)
    let checklistCoverage = appStoreChecklistCoverage(records: records)
    let strictSummary = strictReadinessSummary(records: records)
    let redactedProjectRoot = releaseEvidenceRedacted(projectRootPath).nilIfEmpty ?? "<unset>"
    var lines = [
      "# Local Release Evidence Bundle",
      "",
      "- Generated at: \(generatedAt)",
      "- Project: \(redactedProjectRoot)",
      "- Scope: local automated evidence and redacted manual evidence records",
      "- Privacy: local filesystem paths, token-like strings, and authorization headers are redacted.",
      "",
      "## Current Strict-Release Gaps",
      "",
      "- Blocking items: \(blockingItems.count)",
      "- Warning items: \(warningItems.count)",
      "- Screenshot images: \(capturedScreenshotRequirements.count)/\(screenshotRequirements.count) captured",
      "- External verification evidence: \(externalCoverage.recordedCount)/\(externalCoverage.totalCount) completed",
      "- App Store checklist coverage: \(checklistCoverage.coveredCount)/\(checklistCoverage.totalCount)",
      "- External evidence file: \(releaseEvidenceRedacted(externalVerificationEvidenceFileStatus.message))",
      "- Final strict command: `./script/check_release_gate.sh --strict`",
      "",
      "This bundle does not replace the required live GitHub/GitLab, StoreKit sandbox, screenshot, or App Store upload validation evidence.",
      "",
      "## Local Gate Items",
      "",
    ]

    if items.isEmpty {
      lines.append("- No release gate items were generated.")
    } else {
      for item in items {
        lines.append("- [\(item.status.displayName)] \(item.title): \(releaseEvidenceRedacted(item.message))")
        if let evidence = item.evidence?.nilIfEmpty {
          lines.append("  Evidence: \(releaseEvidenceRedacted(evidence))")
        }
      }
    }

    lines.append("")
    lines.append("## Screenshot Status")
    lines.append("")
    if screenshotRequirements.isEmpty {
      lines.append("- No screenshot requirements were generated.")
    } else {
      for requirement in screenshotRequirements {
        let marker = requirement.isCaptured ? "x" : " "
        let path = requirement.capturedFilePath ?? requirement.targetRelativePath
        lines.append("- [\(marker)] \(requirement.id): \(releaseEvidenceRedacted(path))")
      }
    }

    lines.append("")
    lines.append("## External Verification Status")
    lines.append("")
    let recordsByItemID = Dictionary(grouping: records, by: \.itemID)
    if externalVerificationItems.isEmpty {
      lines.append("- No external verification items were generated.")
    } else {
      for item in externalVerificationItems {
        let itemRecords = recordsByItemID[item.id]?.sorted { $0.recordedAt > $1.recordedAt } ?? []
        let marker = itemRecords.isEmpty ? " " : "x"
        let summary = itemRecords.first?.summaryLines.joined(separator: " / ").nilIfEmpty
          ?? item.evidenceToCollect
        lines.append("- [\(marker)] `\(item.id)` - \(item.title): \(releaseEvidenceRedacted(summary))")
      }
    }

    lines.append("")
    lines.append("## App Store Checklist Coverage")
    lines.append("")
    if appStoreChecklistTasks.isEmpty {
      lines.append("- No App Store checklist tasks were found.")
    } else {
      lines.append("- Checked: \(checklistCoverage.checkedCount)")
      lines.append("- Evidence backed: \(checklistCoverage.evidenceBackedTasks.count)")
      lines.append("- Missing: \(checklistCoverage.missingTasks.count)")
      for task in checklistCoverage.missingTasks.prefix(12) {
        lines.append("- [ ] \(releaseEvidenceRedacted(task.title))")
      }
    }

    lines.append("")
    lines.append("## Next Actions")
    lines.append("")
    if strictSummary.actions.isEmpty {
      lines.append("- Run `\(strictSummary.strictCommand)` for final confirmation.")
    } else {
      for action in strictSummary.actions {
        lines.append("- \(action.title): \(releaseEvidenceRedacted(action.message))")
        if let command = action.command {
          lines.append("  Command: `\(releaseEvidenceRedacted(command))`")
        }
      }
    }

    lines.append("")
    lines.append("## Evidence Files To Complete")
    lines.append("")
    lines.append("- `docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md`")
    lines.append("- `docs/release-evidence/APP_STORE_ARCHIVE_VALIDATION.md`")
    lines.append("- `docs/release-evidence/CLEAN_RUNTIME_VALIDATION.md`")
    lines.append("- `docs/release-evidence/app-store-archive-validation.env.example`")
    lines.append("- `docs/release-evidence/remote-publish-live.env.example`")
    lines.append("- `docs/release-evidence/remote-recovery.env.example`")
    lines.append("- `docs/release-evidence/storekit-sandbox.env.example`")
    lines.append("- `docs/release-evidence/app-store-screenshots.env.example`")
    lines.append("- `docs/app-store-screenshots/SCREENSHOT_MANIFEST.md`")
    lines.append("- `APP_STORE_CHECKLIST.md`")

    return lines.joined(separator: "\n")
  }

  public var cleanRuntimeEvidenceRecordingCommandMarkdown: String {
    [
      "# Clean Runtime Evidence Recording Commands",
      "",
      "Use these commands only after the clean macOS account or equivalent test-user run has actually been performed.",
      "",
      "```sh",
      "script/record_clean_runtime_evidence.sh --dry-run",
      "script/record_clean_runtime_evidence_bundle.sh --dry-run",
      "",
      "script/record_clean_runtime_evidence_bundle.sh \\",
      "  --clean-launch \"Clean test user launched the app through build_and_run --verify and reached the main workspace without migration or permission failures.\" \\",
      "  --privacy-settings-workspace \"First launch, privacy lock, settings, and workspace switching were verified with sample data and redacted screenshots only.\" \\",
      "  --accessibility-keyboard-smoke \"Keyboard navigation, visible focus, VoiceOver labels, and primary menu commands were smoke checked in the running app.\" \\",
      "  --execute",
      "```",
    ].joined(separator: "\n")
  }

  public var appStoreArchiveValidationRecordingCommandMarkdown: String {
    [
      "# App Store Archive Validation Recording Commands",
      "",
      "Use these commands only after the clean archive, signing/runtime inspection, and Transporter or App Store Connect validation have actually been performed.",
      "",
      "Optional private env setup: run `script/prepare_external_verification_envs.sh --output-dir /private/tmp/personal-site-publisher-release-envs --target app-store-archive` to copy `docs/release-evidence/app-store-archive-validation.env.example`, then fill and source `app-store-archive-validation.env` outside the repository.",
      "",
      "```sh",
      "script/record_app_store_archive_validation_evidence.sh --dry-run",
      "script/record_app_store_archive_validation_bundle.sh --dry-run",
      "",
      "script/record_app_store_archive_validation_bundle.sh \\",
      "  --clean-release-archive \"Clean Release archive produced from a fresh checkout and reproducible release command.\" \\",
      "  --distribution-signing-runtime \"Distribution signature verified and hardened runtime flag confirmed on the archive.\" \\",
      "  --transporter-validation \"Archive validated successfully in Transporter before upload; no private account identifiers recorded.\" \\",
      "  --execute",
      "```",
    ].joined(separator: "\n")
  }

  private func releaseEvidenceRedacted(_ value: String) -> String {
    value
      .replacingOccurrences(
        of: #"(/Users|/Volumes)/[^ \n`)]+"#,
        with: "<redacted-local-path>",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"(github_pat_|ghp_|glpat-|sk-)[A-Za-z0-9_-]{8,}"#,
        with: "<redacted-token>",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"Authorization:[ \t]*Bearer[ \t]+[A-Za-z0-9._-]+"#,
        with: "Authorization: Bearer <redacted>",
        options: .regularExpression
      )
  }

  public func externalVerificationEvidenceRecords(
    fromFileMarkdown markdown: String,
    recordedAt: Date = Date()
  ) -> [ReleaseExternalVerificationEvidenceRecord] {
    let lines = markdown.components(separatedBy: "\n")
    return externalVerificationItems.compactMap { item in
      guard let summary = externalVerificationEvidenceSummary(itemID: item.id, in: markdown) else {
        return nil
      }
      guard externalVerificationSummaryIsChecklistEligible(itemID: item.id, summary: summary) else {
        return nil
      }
      return ReleaseExternalVerificationEvidenceRecord(
        itemID: item.id,
        summary: summary,
        evidenceURL: externalVerificationEvidenceURL(for: item, markdown: markdown, lines: lines),
        recordedAt: recordedAt
      )
    }
  }

  private func externalVerificationEvidenceSummary(itemID: String, in markdown: String) -> String? {
    let escapedID = NSRegularExpression.escapedPattern(for: itemID)
    let lines = markdown.components(separatedBy: "\n")
    for (index, rawLine) in lines.enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.range(
        of: #"^- \[[xX]\]\s+`\#(escapedID)`"#,
        options: .regularExpression
      ) != nil else {
        continue
      }

      var summary: String?
      if let separatorRange = line.range(of: " - ") {
        let detail = String(line[separatorRange.upperBound...]).trimmedForPublishing
        if let colonRange = detail.range(of: ":") {
          summary = String(detail[colonRange.upperBound...]).trimmedForPublishing.nilIfEmpty ?? detail
        } else {
          summary = detail.nilIfEmpty
        }
      } else {
        summary = itemID
      }

      let details = externalVerificationStructuredDetailLines(
        itemID: itemID,
        lines: lines,
        checkedLineIndex: index
      )
      if details.isEmpty {
        return summary
      }
      return ([summary].compactMap { $0?.nilIfEmpty } + details).joined(separator: "\n")
    }
    return nil
  }

  private func externalVerificationEvidenceURL(
    for item: ReleaseExternalVerificationItem,
    markdown: String,
    lines: [String]
  ) -> String? {
    if let url = externalVerificationEvidenceURLInMarkdownSection(for: item, markdown: markdown) {
      return url
    }

    let normalizedTitle = item.title.trimmedForPublishing
    if let headingIndex = lines.firstIndex(where: { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      return line == "### \(normalizedTitle)" || (line.hasPrefix("### ") && line.contains(normalizedTitle))
    }), let url = firstURLAfterHeading(headingIndex, lines: lines) {
      return url
    }

    let escapedID = NSRegularExpression.escapedPattern(for: item.id)
    guard let checkedLineIndex = lines.firstIndex(where: { rawLine in
      rawLine.trimmingCharacters(in: .whitespaces).range(
        of: #"^- \[[xX]\]\s+`\#(escapedID)`"#,
        options: .regularExpression
      ) != nil
    }) else {
      return nil
    }

    return firstURLAfterHeading(checkedLineIndex, lines: lines)
  }

  private func externalVerificationEvidenceURLInMarkdownSection(
    for item: ReleaseExternalVerificationItem,
    markdown: String
  ) -> String? {
    let heading = "### \(item.title.trimmedForPublishing)"
    guard let headingRange = markdown.range(of: heading) else {
      return nil
    }
    let tail = String(markdown[headingRange.upperBound...])
    let section: String
    if let nextHeadingRange = tail.range(of: "\n### ") {
      section = String(tail[..<nextHeadingRange.lowerBound])
    } else {
      section = tail
    }
    return firstURL(in: section)
  }

  private func firstURLAfterHeading(_ index: Int, lines: [String]) -> String? {
    for rawLine in lines.dropFirst(index + 1) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("### ") { break }
      if let url = firstURL(in: line) {
        return url
      }
    }
    return nil
  }

  private func firstURL(in text: String) -> String? {
    guard let range = text.range(of: #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#, options: .regularExpression) else {
      return nil
    }
    return String(text[range])
      .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
      .nilIfEmpty
  }

  private func externalVerificationStructuredDetailLines(
    itemID: String,
    lines: [String],
    checkedLineIndex: Int
  ) -> [String] {
    let labels = requiredExternalVerificationStructuredLabels(for: itemID)
    guard !labels.isEmpty else { return [] }

    var searchStart = checkedLineIndex + 1
    if let title = externalVerificationItems.first(where: { $0.id == itemID })?.title {
      let heading = "### \(title)"
      if let headingIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) {
        searchStart = headingIndex + 1
      }
    }

    var details: [String] = []
    for rawLine in lines.dropFirst(searchStart) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("### ") { break }
      for label in labels where line.hasPrefix("- \(label)") {
        details.append(String(line.dropFirst(2)).trimmedForPublishing)
      }
    }
    return details
  }

  private func requiredExternalVerificationStructuredLabels(for itemID: String) -> [String] {
    switch itemID {
    case "github-direct-publish":
      return [
        "Token scope:",
        "Commit SHA:",
        "Deployment status:",
        "Release ledger:",
      ]
    case "github-review-publish":
      return [
        "PR URL:",
        "Provider review artifact:",
        "Review branch:",
        "Target branch:",
        "File changes:",
        "Deployment status:",
        "Release ledger:",
        "Rollback draft:",
      ]
    case "gitlab-direct-publish":
      return [
        "Token scope:",
        "Commit SHA:",
        "Pipeline or Pages status:",
        "Release ledger:",
      ]
    case "gitlab-review-publish":
      return [
        "MR URL:",
        "Provider review artifact:",
        "Source branch:",
        "Target branch:",
        "File changes:",
        "Deployment status:",
        "Release ledger:",
        "Rollback draft:",
      ]
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

  private func externalVerificationSummaryIsChecklistEligible(
    itemID: String,
    summary: String
  ) -> Bool {
    let labels = requiredExternalVerificationStructuredLabels(for: itemID)
    guard !labels.isEmpty else { return true }
    return labels.allSatisfy { externalVerificationSummaryHasFilledLabel($0, in: summary) }
      && externalVerificationSummaryHasNoPendingEvidencePlaceholders(itemID: itemID, summary: summary)
      && externalVerificationSummaryHasReleaseLedgerCoverage(itemID: itemID, summary: summary)
  }

  private func externalVerificationSummaryHasReleaseLedgerCoverage(
    itemID: String,
    summary: String
  ) -> Bool {
    guard let releaseLedger = externalVerificationSummaryLabelDetail("Release ledger:", in: summary)?
      .lowercased() else {
      return true
    }
    switch itemID {
    case "github-direct-publish", "gitlab-direct-publish":
      return releaseLedger.contains("direct") || releaseLedger.contains("直接")
    case "github-review-publish":
      return releaseLedger.contains("pr")
        || releaseLedger.contains("pull request")
        || releaseLedger.contains("review branch")
    case "gitlab-review-publish":
      return releaseLedger.contains("mr")
        || releaseLedger.contains("merge request")
        || releaseLedger.contains("source branch")
    default:
      return true
    }
  }

  private func externalVerificationSummaryHasNoPendingEvidencePlaceholders(
    itemID: String,
    summary: String
  ) -> Bool {
    let lowercasedSummary = summary.lowercased()
    switch itemID {
    case "github-direct-publish", "github-review-publish", "gitlab-direct-publish", "gitlab-review-publish":
      let pendingPhrases = [
        "todo",
        "pending",
        "not verified",
        "not checked",
        "not confirmed",
        "waiting for",
        "missing",
        "待填写",
        "待验证",
        "待确认",
        "未验证",
        "未确认",
      ]
      return !pendingPhrases.contains { lowercasedSummary.contains($0) }
    case "storekit-sandbox":
      let pendingPhrases = [
        "pending sandbox purchase",
        "pending restore check",
        "pending sandbox",
        "confirm app store sandbox",
        "confirm entitlement source changes",
        "confirm pro unlock",
        "use the pro settings purchase button",
        "use restore purchase",
        "待核验",
        "待验证",
      ]
      return !pendingPhrases.contains { lowercasedSummary.contains($0) }
    case "app-store-screenshots":
      let pendingPhrases = [
        "pending capture",
        "pending screenshot",
        "pending privacy",
        "pending strict",
        "todo",
        "not captured",
        "missing screenshot",
        "waiting for screenshot",
        "待采集",
        "待截图",
        "待验证",
      ]
      return !pendingPhrases.contains { lowercasedSummary.contains($0) }
    case "remote-conflict-deployment-rollback":
      let pendingPhrases = [
        "todo",
        "not verified",
        "not checked",
        "not confirmed",
        "waiting for",
        "missing rollback",
        "missing deployment",
        "missing conflict",
        "待填写",
        "待验证",
        "未验证",
        "未确认",
      ]
      return !pendingPhrases.contains { lowercasedSummary.contains($0) }
    default:
      return true
    }
  }

  private func externalVerificationSummaryHasFilledLabel(
    _ label: String,
    in summary: String
  ) -> Bool {
    summary.components(separatedBy: .newlines).contains { rawLine in
      let line = rawLine.trimmedForPublishing
      guard line.hasPrefix(label) else {
        return false
      }
      let detail = String(line.dropFirst(label.count)).trimmedForPublishing
      guard !detail.isEmpty else {
        return false
      }
      let lowercasedDetail = detail.lowercased()
      return !lowercasedDetail.hasPrefix("todo")
        && !lowercasedDetail.contains("待填写")
        && !lowercasedDetail.contains("<")
    }
  }

  private func externalVerificationSummaryLabelDetail(
    _ label: String,
    in summary: String
  ) -> String? {
    for rawLine in summary.components(separatedBy: .newlines) {
      let line = rawLine.trimmedForPublishing
      guard line.hasPrefix(label) else {
        continue
      }
      let detail = String(line.dropFirst(label.count)).trimmedForPublishing
      return detail.isEmpty ? nil : detail
    }
    return nil
  }

  func isChecklistEligibleExternalVerificationRecord(
    _ record: ReleaseExternalVerificationEvidenceRecord
  ) -> Bool {
    externalVerificationSummaryIsChecklistEligible(
      itemID: record.itemID,
      summary: record.summary
    )
  }

  public func externalVerificationRequiredSummaryLabels(for itemID: String) -> [String] {
    requiredExternalVerificationStructuredLabels(for: itemID)
  }

  public func externalVerificationEvidenceTemplate(for itemID: String) -> String {
    guard let item = externalVerificationItems.first(where: { $0.id == itemID }) else {
      return ""
    }

    let labels = requiredExternalVerificationStructuredLabels(for: itemID)
    var lines = [
      "\(item.title) verified with redacted external evidence.",
    ]

    if labels.isEmpty {
      lines.append("Evidence: TODO: \(item.evidenceToCollect)")
    } else {
      let hints = externalVerificationTemplateHints(for: itemID)
      lines.append(contentsOf: labels.map { label in
        "\(label) TODO: \(hints[label] ?? "Add redacted verification detail.")"
      })
    }

    lines.append("")
    lines.append("Next command: ./script/check_external_verification_evidence.sh")
    lines.append("Final command: ./script/check_release_gate.sh --strict")
    return lines.joined(separator: "\n")
  }

  public func missingExternalVerificationSummaryLabels(
    itemID: String,
    summary: String
  ) -> [String] {
    requiredExternalVerificationStructuredLabels(for: itemID).filter { label in
      !externalVerificationSummaryHasFilledLabel(label, in: summary)
    }
  }

  public func isExternalVerificationSummaryChecklistEligible(
    itemID: String,
    summary: String
  ) -> Bool {
    externalVerificationSummaryIsChecklistEligible(itemID: itemID, summary: summary)
  }

  private func externalVerificationTemplateHints(for itemID: String) -> [String: String] {
    switch itemID {
    case "github-direct-publish":
      return [
        "Token scope:": "least-privilege contents write token confirmed by GitHub API, without pasting the token.",
        "Commit SHA:": "redacted test commit SHA or short SHA.",
        "Deployment status:": "GitHub Pages, Actions, or custom endpoint reached the expected state.",
        "Release ledger:": "ledger contains the online direct publish entry and deployment check.",
      ]
    case "github-review-publish":
      return [
        "PR URL:": "test Pull Request URL.",
        "Provider review artifact:": "GitHub API returned PR number, state, and draft flag.",
        "Review branch:": "review branch created by the app.",
        "Target branch:": "target branch used for the PR.",
        "File changes:": "redacted disposable file paths changed through the API.",
        "Deployment status:": "Pages, Actions, or custom endpoint result for the review branch.",
        "Release ledger:": "ledger contains the PR publish entry, review branch, and deployment check.",
        "Rollback draft:": "rollback PR draft includes branch, files, and revert path.",
      ]
    case "gitlab-direct-publish":
      return [
        "Token scope:": "least-privilege project write token confirmed by GitLab API, without pasting the token.",
        "Commit SHA:": "redacted test commit SHA or short SHA.",
        "Pipeline or Pages status:": "GitLab Pipeline, Pages, or custom endpoint reached the expected state.",
        "Release ledger:": "ledger contains the GitLab direct publish entry and deployment check.",
      ]
    case "gitlab-review-publish":
      return [
        "MR URL:": "test Merge Request URL.",
        "Provider review artifact:": "GitLab API returned MR iid, state, and merge status.",
        "Source branch:": "source branch created by the app.",
        "Target branch:": "target branch used for the MR.",
        "File changes:": "redacted disposable file paths changed through the API.",
        "Deployment status:": "Pipeline, Pages, or custom endpoint result for the MR branch.",
        "Release ledger:": "ledger contains the MR publish entry, source branch, and deployment check.",
        "Rollback draft:": "rollback MR draft includes branch, files, and revert path.",
      ]
    case "remote-conflict-deployment-rollback":
      return [
        "Remote conflict preview:": "same-path remote edit was detected and blocked or previewed before publish.",
        "Pending/offline state:": "failed or unknown deployment state stayed pending for retry.",
        "Deployment retry:": "manual retry or polling refreshed provider status.",
        "Rollback package:": "rollback package includes branch, files, and PR/MR draft.",
      ]
    case "storekit-sandbox":
      return [
        "StoreKit product lookup:": "sandbox loaded personal.site.publisher.pro.",
        "StoreKit purchase:": "purchase completed and entitlement source changed to StoreKit.",
        "StoreKit restore:": "restore reapplied Pro after clearing local state.",
        "StoreKit free quota:": "free quota boundary showed upgrade copy before purchase and stopped consuming after Pro.",
        "StoreKit boundary events:": "recent boundary events include free-plan block and Pro no-quota allow.",
      ]
    case "app-store-screenshots":
      return [
        "Screenshot set:": "all ten required App Store screens were captured.",
        "Screenshot privacy gate:": "privacy gate passed with no tokens, local paths, or private content.",
        "Screenshot strict gate:": "strict screenshot gate and release gate output were reviewed.",
      ]
    default:
      return [:]
    }
  }

  public func externalVerificationCoverage(
    records: [ReleaseExternalVerificationEvidenceRecord]
  ) -> ReleaseExternalVerificationCoverageSummary {
    let recordedItemIDs = Set(records.filter(isChecklistEligibleExternalVerificationRecord).map(\.itemID))
    let missingItems = externalVerificationItems.filter { !recordedItemIDs.contains($0.id) }
    let recordedCount = externalVerificationItems.count - missingItems.count
    return ReleaseExternalVerificationCoverageSummary(
      totalCount: externalVerificationItems.count,
      recordedCount: max(0, recordedCount),
      missingItems: missingItems
    )
  }

}
