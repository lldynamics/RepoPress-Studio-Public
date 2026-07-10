import Foundation

public enum ReleaseQualityGateStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case passed
  case warning
  case blocked

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .passed:
      return "通过"
    case .warning:
      return "需确认"
    case .blocked:
      return "阻断"
    }
  }

  public var systemImage: String {
    switch self {
    case .passed:
      return "checkmark.seal"
    case .warning:
      return "exclamationmark.triangle"
    case .blocked:
      return "xmark.octagon"
    }
  }
}

public enum ReleaseQualityGateCategory: String, Codable, CaseIterable, Identifiable, Sendable {
  case localization
  case runtime
  case screenshots
  case appStore
  case productReadiness

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .localization:
      return "本地化"
    case .runtime:
      return "UI Runtime"
    case .screenshots:
      return "截图 Gate"
    case .appStore:
      return "上架清单"
    case .productReadiness:
      return "产品边界"
    }
  }

  public var systemImage: String {
    switch self {
    case .localization:
      return "globe"
    case .runtime:
      return "macwindow"
    case .screenshots:
      return "camera.viewfinder"
    case .appStore:
      return "checklist.checked"
    case .productReadiness:
      return "shippingbox"
    }
  }
}

public struct ReleaseQualityGateItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var category: ReleaseQualityGateCategory
  public var title: String
  public var status: ReleaseQualityGateStatus
  public var message: String
  public var evidence: String?

  public init(
    id: String,
    category: ReleaseQualityGateCategory,
    title: String,
    status: ReleaseQualityGateStatus,
    message: String,
    evidence: String? = nil
  ) {
    self.id = id
    self.category = category
    self.title = title
    self.status = status
    self.message = message
    self.evidence = evidence
  }
}

public struct ReleaseQualityGateSection: Identifiable, Hashable, Sendable {
  public var category: ReleaseQualityGateCategory
  public var items: [ReleaseQualityGateItem]

  public var id: ReleaseQualityGateCategory.ID { category.id }

  public init(category: ReleaseQualityGateCategory, items: [ReleaseQualityGateItem]) {
    self.category = category
    self.items = items
  }
}

public struct ReleaseScreenshotRequirement: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var targetFileName: String
  public var screenTitle: String
  public var purpose: String
  public var manifestStatus: String
  public var capturedFilePath: String?

  public init(
    id: String,
    targetFileName: String,
    screenTitle: String,
    purpose: String,
    manifestStatus: String,
    capturedFilePath: String? = nil
  ) {
    self.id = id
    self.targetFileName = targetFileName
    self.screenTitle = screenTitle
    self.purpose = purpose
    self.manifestStatus = manifestStatus
    self.capturedFilePath = capturedFilePath
  }

  public var hasManifestTarget: Bool {
    let lowercasedTarget = targetFileName.lowercased()
    return lowercasedTarget.hasSuffix(".png")
      || lowercasedTarget.hasSuffix(".jpg")
      || lowercasedTarget.hasSuffix(".jpeg")
  }

  public var isCaptured: Bool {
    capturedFilePath?.nilIfEmpty != nil
  }

  public var gateStatus: ReleaseQualityGateStatus {
    if isCaptured {
      return .passed
    }
    return hasManifestTarget ? .warning : .blocked
  }

  public var checklistLine: String {
    let marker = isCaptured ? "x" : " "
    let target = targetFileName.nilIfEmpty ?? "未配置目标文件"
    let status = capturedFilePath ?? manifestStatus.nilIfEmpty ?? gateStatus.displayName
    return "- [\(marker)] \(id) (`\(target)`) - \(screenTitle.nilIfEmpty ?? id)：\(status)"
  }

  public var captureCommand: String {
    "./script/capture_app_screenshots.sh --only \(id)"
  }

  public var targetRelativePath: String {
    guard let target = targetFileName.nilIfEmpty else {
      return "docs/app-store-screenshots/<missing-target>"
    }
    return "docs/app-store-screenshots/\(target)"
  }

  public var privacyReminder: String {
    "截图前隐藏真实 Token、授权头、个人账号、本地路径和私密正文。"
  }

  public var capturePlanMarkdown: String {
    [
      "## \(screenTitle.nilIfEmpty ?? id)",
      "",
      "- ID：\(id)",
      "- 目标文件：\(targetRelativePath)",
      "- 状态：\(gateStatus.displayName)",
      "- 说明：\(purpose.nilIfEmpty ?? "Manifest 缺少截图说明。")",
      "- 采集命令：`\(captureCommand)`",
      "- 隐私检查：\(privacyReminder)",
    ].joined(separator: "\n")
  }
}

public struct ReleaseExternalVerificationItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var purpose: String
  public var evidenceToCollect: String
  public var steps: [String]

  public init(
    id: String,
    title: String,
    purpose: String,
    evidenceToCollect: String,
    steps: [String]
  ) {
    self.id = id
    self.title = title
    self.purpose = purpose
    self.evidenceToCollect = evidenceToCollect
    self.steps = steps
  }

  public var checklistMarkdown: String {
    var lines = [
      "## \(title)",
      "",
      "- ID：\(id)",
      "- 目标：\(purpose)",
      "- 证据：\(evidenceToCollect)",
      "",
      "### 步骤",
    ]
    lines.append(contentsOf: steps.map { "- [ ] \($0)" })
    return lines.joined(separator: "\n")
  }
}

public struct ReleaseExternalVerificationEvidenceRecord: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var itemID: String
  public var summary: String
  public var evidenceURL: String?
  public var recordedAt: Date

  public init(
    id: UUID = UUID(),
    itemID: String,
    summary: String,
    evidenceURL: String? = nil,
    recordedAt: Date = Date()
  ) {
    self.id = id
    self.itemID = itemID
    self.summary = summary
    self.evidenceURL = evidenceURL
    self.recordedAt = recordedAt
  }

  public var checklistLine: String {
    let url = evidenceURL?.nilIfEmpty.map { " \($0)" } ?? ""
    return "- [x] \(itemID)：\(summary)\(url)"
  }

  public var summaryLines: [String] {
    summary
      .components(separatedBy: .newlines)
      .map(\.trimmedForPublishing)
      .compactMap(\.nilIfEmpty)
  }
}

public struct ReleaseExternalVerificationCoverageSummary: Hashable, Sendable {
  public var totalCount: Int
  public var recordedCount: Int
  public var missingItems: [ReleaseExternalVerificationItem]

  public init(
    totalCount: Int,
    recordedCount: Int,
    missingItems: [ReleaseExternalVerificationItem]
  ) {
    self.totalCount = totalCount
    self.recordedCount = recordedCount
    self.missingItems = missingItems
  }

  public var isComplete: Bool {
    totalCount > 0 && missingItems.isEmpty
  }

  public var title: String {
    if totalCount == 0 {
      return "没有外部验收项"
    }
    if isComplete {
      return "外部验收证据齐全"
    }
    if recordedCount == 0 {
      return "尚未记录外部验收证据"
    }
    return "外部验收证据未齐全"
  }

  public var message: String {
    if totalCount == 0 {
      return "当前 release gate 没有生成外部验收计划。"
    }
    if isComplete {
      return "GitHub/GitLab、StoreKit、截图和发布回滚等外部验收项都有证据记录。"
    }
    let missing = missingItems.prefix(3).map(\.title).joined(separator: "、")
    let suffix = missingItems.count > 3 ? "…" : ""
    return "已记录 \(recordedCount)/\(totalCount)，仍缺 \(missingItems.count) 项：\(missing)\(suffix)"
  }
}

public struct ReleaseExternalVerificationRunnerTarget: Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var purpose: String
  public var environmentFilename: String
  public var checklistItems: [String]
  public var requiredEnvironmentKeys: [String]
  public var dryRunCommand: String
  public var executeCommand: String
  public var finalizeCommand: String {
    [
      "script/sync_app_store_checklist.sh --execute",
      "./script/check_release_gate.sh --strict",
    ].joined(separator: "\n")
  }

  public var executeAndFinalizeCommand: String {
    [
      executeCommand,
      finalizeCommand,
    ].joined(separator: "\n")
  }

  public init(
    id: String,
    title: String,
    purpose: String,
    environmentFilename: String,
    checklistItems: [String] = [],
    requiredEnvironmentKeys: [String] = [],
    dryRunCommand: String,
    executeCommand: String
  ) {
    self.id = id
    self.title = title
    self.purpose = purpose
    self.environmentFilename = environmentFilename
    self.checklistItems = checklistItems
    self.requiredEnvironmentKeys = requiredEnvironmentKeys
    self.dryRunCommand = dryRunCommand
    self.executeCommand = executeCommand
  }
}

public struct ReleaseExternalVerificationEnvStatusFile: Identifiable, Hashable, Sendable {
  public var envFilename: String
  public var targetID: String
  public var requiredKeys: [String]
  public var issues: [String]

  public var id: String { "\(targetID)-\(envFilename)" }

  public init(
    envFilename: String,
    targetID: String,
    requiredKeys: [String],
    issues: [String] = []
  ) {
    self.envFilename = envFilename
    self.targetID = targetID
    self.requiredKeys = requiredKeys
    self.issues = issues
  }

  public var missingOrPlaceholderKeys: [String] {
    issues.compactMap { issue in
      guard issue.hasPrefix(envFilename) else {
        return nil
      }
      if let range = issue.range(of: " for ") {
        return String(issue[range.upperBound...]).trimmedForPublishing.nilIfEmpty
      }
      if let range = issue.range(of: " variable ") {
        return String(issue[range.upperBound...]).trimmedForPublishing.nilIfEmpty
      }
      return nil
    }
  }
}

public struct ReleaseExternalVerificationEvidenceCompletion: Identifiable, Hashable, Sendable {
  public var targetID: String
  public var label: String
  public var isComplete: Bool

  public var id: String { "\(targetID)-\(label)" }

  public init(
    targetID: String,
    label: String,
    isComplete: Bool
  ) {
    self.targetID = targetID
    self.label = label
    self.isComplete = isComplete
  }
}

public struct ReleaseExternalVerificationEnvStatusReport: Hashable, Sendable {
  public var isPresent: Bool
  public var mode: String?
  public var target: String?
  public var envDirectory: String?
  public var checkedTargetCount: Int
  public var passingEnvFileCount: Int
  public var issueCount: Int
  public var files: [ReleaseExternalVerificationEnvStatusFile]
  public var evidenceCompletions: [ReleaseExternalVerificationEvidenceCompletion]
  public var nextCommands: [String]

  public init(
    isPresent: Bool = false,
    mode: String? = nil,
    target: String? = nil,
    envDirectory: String? = nil,
    checkedTargetCount: Int = 0,
    passingEnvFileCount: Int = 0,
    issueCount: Int = 0,
    files: [ReleaseExternalVerificationEnvStatusFile] = [],
    evidenceCompletions: [ReleaseExternalVerificationEvidenceCompletion] = [],
    nextCommands: [String] = []
  ) {
    self.isPresent = isPresent
    self.mode = mode
    self.target = target
    self.envDirectory = envDirectory
    self.checkedTargetCount = checkedTargetCount
    self.passingEnvFileCount = passingEnvFileCount
    self.issueCount = issueCount
    self.files = files
    self.evidenceCompletions = evidenceCompletions
    self.nextCommands = nextCommands
  }

  public var isClean: Bool {
    isPresent && issueCount == 0 && files.allSatisfy { $0.issues.isEmpty }
  }

  public var title: String {
    if !isPresent {
      return "尚未生成 env 状态报告"
    }
    if isClean {
      return "私有 env 状态已通过"
    }
    return "私有 env 仍有 \(issueCount) 个问题"
  }

  public var completedEvidenceCount: Int {
    evidenceCompletions.filter(\.isComplete).count
  }

  public var pendingEvidenceCompletions: [ReleaseExternalVerificationEvidenceCompletion] {
    evidenceCompletions.filter { !$0.isComplete }
  }

  public var evidenceCompletionMessage: String {
    guard !evidenceCompletions.isEmpty else {
      return "这份报告还没有列出外部证据完成状态。"
    }
    if pendingEvidenceCompletions.isEmpty {
      return "外部证据项已全部完成：\(completedEvidenceCount)/\(evidenceCompletions.count)。"
    }
    return "外部证据完成 \(completedEvidenceCount)/\(evidenceCompletions.count)，仍待 \(pendingEvidenceCompletions.count) 项真实验收。"
  }

  public var message: String {
    if !isPresent {
      return "先运行 env 状态报告命令，生成红acted ENV_STATUS.md 后再执行外部验收。"
    }
    if isClean {
      return "已检查 \(checkedTargetCount) 个 target，\(passingEnvFileCount) 个 env 文件通过。"
    }
    let affectedFiles = files.filter { !$0.issues.isEmpty }.map(\.envFilename)
    let affectedText = affectedFiles.prefix(3).joined(separator: "、")
    let suffix = affectedFiles.count > 3 ? "…" : ""
    return "已检查 \(checkedTargetCount) 个 target，\(passingEnvFileCount) 个 env 文件通过；需补 \(affectedFiles.count) 个文件：\(affectedText)\(suffix)"
  }

  public var summaryMarkdown: String {
    var lines = [
      "# External Verification Env Status Summary",
      "",
      "- Status: \(title)",
      "- Mode: \(mode ?? "<missing>")",
      "- Target: \(target ?? "<missing>")",
      "- Env directory: \(envDirectory ?? "<missing>")",
      "- Checked targets: \(checkedTargetCount)",
      "- Passing env files: \(passingEnvFileCount)",
      "- Issues: \(issueCount)",
      "",
      "## Files"
    ]

    if files.isEmpty {
      lines.append("- No env files were listed in the report.")
    } else {
      for file in files {
        lines.append("- `\(file.envFilename)` (`\(file.targetID)`): \(file.issues.isEmpty ? "ok" : "\(file.issues.count) issue(s)")")
        if !file.requiredKeys.isEmpty {
          lines.append("  - Required: \(file.requiredKeys.map { "`\($0)`" }.joined(separator: ", "))")
        }
        if !file.missingOrPlaceholderKeys.isEmpty {
          lines.append("  - Fill: \(file.missingOrPlaceholderKeys.map { "`\($0)`" }.joined(separator: ", "))")
        }
        for issue in file.issues.prefix(5) {
          lines.append("  - \(issue)")
        }
      }
    }

    if !evidenceCompletions.isEmpty {
      lines.append("")
      lines.append("## Evidence Completion")
      lines.append("")
      lines.append("- \(evidenceCompletionMessage)")
      for item in evidenceCompletions {
        lines.append("- [\(item.isComplete ? "x" : " ")] `\(item.targetID)`: \(item.label)")
      }
    }

    if !nextCommands.isEmpty {
      lines.append("")
      lines.append("## Next Commands")
      lines.append("")
      lines.append("```sh")
      lines.append(contentsOf: nextCommands)
      lines.append("```")
    }

    return lines.joined(separator: "\n")
  }

  public static func parse(redactedMarkdown text: String) -> ReleaseExternalVerificationEnvStatusReport {
    let trimmed = text.trimmedForPublishing
    guard !trimmed.isEmpty else {
      return ReleaseExternalVerificationEnvStatusReport()
    }

    let lines = text.components(separatedBy: .newlines)
    var mode: String?
    var target: String?
    var envDirectory: String?
    var checkedTargetCount = 0
    var passingEnvFileCount = 0
    var issueCount = 0
    var files: [ReleaseExternalVerificationEnvStatusFile] = []
    var evidenceCompletions: [ReleaseExternalVerificationEvidenceCompletion] = []
    var issues: [String] = []
    var nextCommands: [String] = []
    var section = ""
    var currentEvidenceTargetID: String?
    var isInsideCommandBlock = false

    for rawLine in lines {
      let line = rawLine.trimmedForPublishing
      if line.hasPrefix("## ") {
        section = String(line.dropFirst(3)).trimmedForPublishing
        currentEvidenceTargetID = nil
        isInsideCommandBlock = false
        continue
      }
      if section == "Evidence Completion", line.hasPrefix("### ") {
        currentEvidenceTargetID = markdownBacktickValues(in: line).first
          ?? String(line.dropFirst(4)).trimmedForPublishing.nilIfEmpty
        continue
      }
      if line == "```sh" {
        isInsideCommandBlock = true
        continue
      }
      if line == "```" {
        isInsideCommandBlock = false
        continue
      }

      if isInsideCommandBlock && section == "Next Commands", !line.isEmpty {
        nextCommands.append(line)
        continue
      }

      if line.hasPrefix("- Mode:") {
        mode = markdownBacktickValues(in: line).first
      } else if line.hasPrefix("- Target:") {
        target = markdownBacktickValues(in: line).first
      } else if line.hasPrefix("- Env directory:") {
        envDirectory = markdownBacktickValues(in: line).first
      } else if line.hasPrefix("- Checked targets:") {
        checkedTargetCount = trailingInteger(in: line)
      } else if line.hasPrefix("- Passing env files:") {
        passingEnvFileCount = trailingInteger(in: line)
      } else if line.hasPrefix("- Issues:") {
        issueCount = trailingInteger(in: line)
      } else if section == "Required Fields", line.hasPrefix("- `") {
        let values = markdownBacktickValues(in: line)
        guard values.count >= 2 else {
          continue
        }
        files.append(
          ReleaseExternalVerificationEnvStatusFile(
            envFilename: values[0],
            targetID: values[1],
            requiredKeys: Array(values.dropFirst(2))
          )
        )
      } else if section == "Issues", line.hasPrefix("- "), line != "- None." {
        issues.append(String(line.dropFirst(2)).trimmedForPublishing)
      } else if section == "Evidence Completion",
                line.hasPrefix("- ["),
                let currentEvidenceTargetID {
        let isComplete = line.hasPrefix("- [x]") || line.hasPrefix("- [X]")
        let labelStart = line.index(line.startIndex, offsetBy: min(6, line.count))
        let rawLabel = String(line[labelStart...]).trimmedForPublishing
        let label: String
        if rawLabel.hasPrefix("`"), rawLabel.hasSuffix("`"), rawLabel.count >= 2 {
          label = String(rawLabel.dropFirst().dropLast())
        } else {
          label = rawLabel
        }
        evidenceCompletions.append(
          ReleaseExternalVerificationEvidenceCompletion(
            targetID: currentEvidenceTargetID,
            label: label,
            isComplete: isComplete
          )
        )
      }
    }

    let filesWithIssues = files.map { file in
      var updated = file
      updated.issues = issues.filter { $0.hasPrefix(file.envFilename) }
      return updated
    }

    return ReleaseExternalVerificationEnvStatusReport(
      isPresent: true,
      mode: mode,
      target: target,
      envDirectory: envDirectory,
      checkedTargetCount: checkedTargetCount,
      passingEnvFileCount: passingEnvFileCount,
      issueCount: issueCount == 0 ? issues.count : issueCount,
      files: filesWithIssues,
      evidenceCompletions: evidenceCompletions,
      nextCommands: nextCommands
    )
  }

  private static func markdownBacktickValues(in line: String) -> [String] {
    var values: [String] = []
    var remainder = line[...]
    while let start = remainder.firstIndex(of: "`") {
      let afterStart = remainder.index(after: start)
      guard let end = remainder[afterStart...].firstIndex(of: "`") else {
        break
      }
      values.append(String(remainder[afterStart..<end]))
      remainder = remainder[remainder.index(after: end)...]
    }
    return values
  }

  private static func trailingInteger(in line: String) -> Int {
    line
      .split(separator: " ")
      .reversed()
      .compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "`"))) }
      .first ?? 0
  }
}

public struct ReleaseExternalVerificationEvidenceFileStatus: Codable, Hashable, Sendable {
  public var relativePath: String
  public var isPresent: Bool
  public var totalCount: Int
  public var completedItemIDs: [String]
  public var missingItemIDs: [String]
  public var privacyFindings: [String]

  public init(
    relativePath: String = "docs/release-evidence/EXTERNAL_VERIFICATION_EVIDENCE.md",
    isPresent: Bool = false,
    totalCount: Int = 0,
    completedItemIDs: [String] = [],
    missingItemIDs: [String] = [],
    privacyFindings: [String] = []
  ) {
    self.relativePath = relativePath
    self.isPresent = isPresent
    self.totalCount = totalCount
    self.completedItemIDs = completedItemIDs
    self.missingItemIDs = missingItemIDs
    self.privacyFindings = privacyFindings
  }

  public var completedCount: Int {
    completedItemIDs.count
  }

  public var isComplete: Bool {
    isPresent && totalCount > 0 && missingItemIDs.isEmpty && privacyFindings.isEmpty
  }

  public var title: String {
    if !isPresent {
      return "外部验收证据包未写入"
    }
    if !privacyFindings.isEmpty {
      return "外部验收证据包需要清理"
    }
    if isComplete {
      return "外部验收证据包齐全"
    }
    return "外部验收证据包未齐全"
  }

  public var message: String {
    if !isPresent {
      return "尚未找到 \(relativePath)。可从发布准备页写入证据包。"
    }
    if !privacyFindings.isEmpty {
      return "\(relativePath) 可能包含 \(privacyFindings.joined(separator: "、"))。"
    }
    if isComplete {
      return "\(relativePath) 已完成 \(completedCount)/\(totalCount) 项。"
    }
    let missing = missingItemIDs.prefix(3).joined(separator: "、")
    let suffix = missingItemIDs.count > 3 ? "…" : ""
    return "\(relativePath) 已完成 \(completedCount)/\(totalCount)，仍缺：\(missing)\(suffix)"
  }
}

public struct ReleaseAppStoreChecklistTask: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var sectionTitle: String?
  public var title: String
  public var isChecked: Bool

  public init(
    id: String,
    sectionTitle: String? = nil,
    title: String,
    isChecked: Bool
  ) {
    self.id = id
    self.sectionTitle = sectionTitle
    self.title = title
    self.isChecked = isChecked
  }
}

public struct ReleaseAppStoreChecklistEvidenceCoverage: Identifiable, Hashable, Sendable {
  public var task: ReleaseAppStoreChecklistTask
  public var evidence: String

  public var id: ReleaseAppStoreChecklistTask.ID { task.id }

  public init(task: ReleaseAppStoreChecklistTask, evidence: String) {
    self.task = task
    self.evidence = evidence
  }
}

public struct ReleaseAppStoreChecklistCoverageSummary: Hashable, Sendable {
  public var totalCount: Int
  public var checkedCount: Int
  public var evidenceBackedTasks: [ReleaseAppStoreChecklistEvidenceCoverage]
  public var missingTasks: [ReleaseAppStoreChecklistTask]

  public init(
    totalCount: Int,
    checkedCount: Int,
    evidenceBackedTasks: [ReleaseAppStoreChecklistEvidenceCoverage],
    missingTasks: [ReleaseAppStoreChecklistTask]
  ) {
    self.totalCount = totalCount
    self.checkedCount = checkedCount
    self.evidenceBackedTasks = evidenceBackedTasks
    self.missingTasks = missingTasks
  }

  public var evidenceBackedCount: Int {
    evidenceBackedTasks.count
  }

  public var coveredCount: Int {
    checkedCount + evidenceBackedCount
  }

  public var isFullyCoveredByChecklistOrEvidence: Bool {
    totalCount > 0 && missingTasks.isEmpty
  }

  public var title: String {
    if totalCount == 0 {
      return "没有 App Store checklist 项"
    }
    if isFullyCoveredByChecklistOrEvidence {
      return "上架清单已有证据覆盖"
    }
    if evidenceBackedCount == 0 {
      return "上架清单仍需人工验收"
    }
    return "上架清单部分已有证据"
  }

  public var message: String {
    if totalCount == 0 {
      return "当前项目没有可解析的 APP_STORE_CHECKLIST.md 任务。"
    }
    if isFullyCoveredByChecklistOrEvidence {
      return "已勾选 \(checkedCount) 项，另有 \(evidenceBackedCount) 项由自动门禁或外部验收证据覆盖。"
    }
    let missing = missingTasks.prefix(3).map(\.title).joined(separator: "；")
    let suffix = missingTasks.count > 3 ? "…" : ""
    return "已勾选 \(checkedCount) 项，证据覆盖 \(evidenceBackedCount) 项，仍缺 \(missingTasks.count) 项：\(missing)\(suffix)"
  }
}

public struct ReleaseAppStoreChecklistWritebackResult: Hashable, Sendable {
  public var markdown: String
  public var updatedCount: Int

  public init(markdown: String, updatedCount: Int) {
    self.markdown = markdown
    self.updatedCount = updatedCount
  }
}

public enum ReleaseStrictReadinessActionPriority: Int, Codable, Comparable, Sendable {
  case high = 0
  case medium = 1
  case low = 2

  public static func < (
    lhs: ReleaseStrictReadinessActionPriority,
    rhs: ReleaseStrictReadinessActionPriority
  ) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var displayName: String {
    switch self {
    case .high:
      return "优先"
    case .medium:
      return "随后"
    case .low:
      return "收尾"
    }
  }
}

public struct ReleaseStrictReadinessAction: Identifiable, Codable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var message: String
  public var command: String?
  public var priority: ReleaseStrictReadinessActionPriority

  public init(
    id: String,
    title: String,
    message: String,
    command: String? = nil,
    priority: ReleaseStrictReadinessActionPriority
  ) {
    self.id = id
    self.title = title
    self.message = message
    self.command = command
    self.priority = priority
  }
}

public struct ReleaseStrictReadinessSummary: Codable, Hashable, Sendable {
  public var title: String
  public var message: String
  public var actions: [ReleaseStrictReadinessAction]
  public var strictCommand: String

  public init(
    title: String,
    message: String,
    actions: [ReleaseStrictReadinessAction],
    strictCommand: String = "./script/check_release_gate.sh --strict"
  ) {
    self.title = title
    self.message = message
    self.actions = actions.sorted {
      if $0.priority == $1.priority {
        return $0.title < $1.title
      }
      return $0.priority < $1.priority
    }
    self.strictCommand = strictCommand
  }

  public var isReady: Bool {
    actions.isEmpty
  }

  public var commandText: String {
    let commands = actions.compactMap(\.command) + [strictCommand]
    var seen: Set<String> = []
    let uniqueCommands = commands.filter { command in
      guard !seen.contains(command) else {
        return false
      }
      seen.insert(command)
      return true
    }
    return uniqueCommands.joined(separator: "\n")
  }
}

