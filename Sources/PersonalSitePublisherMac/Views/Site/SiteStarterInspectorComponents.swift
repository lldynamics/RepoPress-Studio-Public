import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SiteStarterInspectorState {
  let hasPreparedSite: Bool
  let hasImportedSite: Bool
  let createdFileCount: Int
  let importedDraftCount: Int
  let initializedGit: Bool
  let hasConfiguredRemote: Bool
  let deploymentGuidePath: String?
  let hasRepositoryToken: Bool
  let hasRemoteRepositoryCreationResult: Bool
  let hasVerifiedExistingRepository: Bool
  let pushBranch: String?
  let pushCommitShortSHA: String?
  let pushedFileCount: Int
  let publishActionMessage: String?

  init(store: WorkbenchStore) {
    let result = store.siteStarterResult
    let importResult = store.siteStarterImportResult
    let pushResult = store.siteStarterPushResult

    hasPreparedSite = result != nil || importResult != nil
    hasImportedSite = importResult != nil
    createdFileCount = result?.createdFilePaths.count ?? 0
    importedDraftCount = importResult?.importedDraftCount ?? 0
    initializedGit = result?.initializedGit == true
    hasConfiguredRemote = result?.configuredRemoteURL != nil
    deploymentGuidePath = result?.deploymentGuidePath
    hasRepositoryToken = store.repositoryTokenAvailability.hasToken
    hasRemoteRepositoryCreationResult = store.remoteRepositoryCreationResult.map {
      $0.provider == store.activeProfile.repositoryProvider
        && $0.repositoryName.caseInsensitiveCompare(store.activeProfile.repositoryDisplayName) == .orderedSame
    } ?? false
    hasVerifiedExistingRepository = store.activeRemoteRepositoryAccessCheck.map {
      $0.canRead && $0.canWrite
    } ?? false
    pushBranch = pushResult?.branch
    pushCommitShortSHA = pushResult.map { String($0.commitSHA.prefix(8)) }
    pushedFileCount = pushResult?.committedPaths.count ?? 0
    publishActionMessage = store.publishActionMessage
  }
}

struct SiteStarterInspectorView: View {
  let state: SiteStarterInspectorState
  @SceneStorage("siteStarterSelectedStep") private var selectedStepRaw = SiteStarterWizardStep.template.rawValue

  private var selectedStep: SiteStarterWizardStep {
    SiteStarterWizardStep(rawValue: selectedStepRaw) ?? .template
  }

  var body: some View {
    InspectorScaffold(
      title: "建站风险",
      subtitle: selectedStep.title,
      systemImage: selectedStep.systemImage
    ) {
      progressSection
      currentStepSection
      riskSection
      artifactSection
      actionMessage(state.publishActionMessage)
    }
  }

  private var progressSection: some View {
    InspectorSection("进度") {
      ForEach(SiteStarterWizardStep.allCases) { step in
        InspectorStatRow(
          title: step.title,
          value: statusTitle(for: step),
          systemImage: statusSystemImage(for: step)
        )
      }
    }
  }

  private var currentStepSection: some View {
    InspectorSection("当前步骤") {
      Text(selectedStep.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(4)

      ForEach(currentStepFacts, id: \.self) { fact in
        Label(fact, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private var riskSection: some View {
    InspectorSection("风险") {
      let risks = currentStepRisks
      if risks.isEmpty {
        Label("当前步骤没有明显阻断。", systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(risks, id: \.self) { risk in
          Label(risk, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
            .lineLimit(3)
        }
      }
    }
  }

  @ViewBuilder
  private var artifactSection: some View {
    if state.hasPreparedSite {
      InspectorSection("产物") {
        if state.hasImportedSite {
          InspectorStatRow(
            title: "方式",
            value: String(localized: "导入已有仓库"),
            systemImage: "tray.and.arrow.down"
          )
          InspectorStatRow(title: "文章", value: "\(state.importedDraftCount)", systemImage: "doc.text")
        } else {
          InspectorStatRow(title: "文件", value: "\(state.createdFileCount)", systemImage: "doc.badge.plus")
          InspectorStatRow(
            title: "Git",
            value: state.initializedGit ? String(localized: "已初始化") : String(localized: "未初始化"),
            systemImage: "externaldrive"
          )
          InspectorStatRow(
            title: "origin",
            value: state.hasConfiguredRemote ? String(localized: "已配置") : String(localized: "未配置"),
            systemImage: "point.3.connected.trianglepath.dotted"
          )
        }
        if let guide = state.deploymentGuidePath {
          Text(guide)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }

    if let pushBranch = state.pushBranch {
      InspectorSection("首次推送") {
        InspectorStatRow(title: "分支", value: pushBranch, systemImage: "arrow.triangle.branch")
        InspectorStatRow(
          title: "提交",
          value: state.pushCommitShortSHA ?? String(localized: "未知"),
          systemImage: "number"
        )
        InspectorStatRow(title: "文件", value: "\(state.pushedFileCount)", systemImage: "shippingbox")
      }
    }
  }

  private var currentStepFacts: [String] {
    switch selectedStep {
    case .template:
      return [String(localized: "新建站点提供四套现代 SSG 起点；导入模式仍会按已有站点类型读取内容目录和 Front Matter。")]
    case .localDirectory:
      return [String(localized: "目标目录必须是空文件夹；生成后会成为本地站点仓库。")]
    case .github:
      return [String(localized: "GitHub 仓库创建以向导里的所有者、仓库名和分支为准；创建前会同步到当前站点配置。")]
    case .generate:
      return [String(localized: "生成会创建模板文件、部署工作流、部署说明和初始文章草稿。")]
    case .firstPush:
      return [String(localized: "首次推送会提交 Starter 文件，并把分支推送到 origin。")]
    case .deployment:
      return [String(localized: "GitHub Pages 首次部署通常需要到仓库 Settings > Pages 确认来源。")]
    }
  }

  private var currentStepRisks: [String] {
    switch selectedStep {
    case .template:
      return []
    case .localDirectory:
      return state.hasPreparedSite
        ? []
        : [String(localized: "新建站点需要空文件夹；导入模式请选择现有仓库根目录。")]
    case .github:
      var risks: [String] = []
      if !state.hasRepositoryToken {
        risks.append(String(localized: "未检测到 GitHub 访问令牌，创建仓库会失败。"))
      }
      return risks
    case .generate:
      return state.hasPreparedSite
        ? []
        : [String(localized: "继续前请确认新建/导入方式、目录、站点名称和分支。")]
    case .firstPush:
      var risks: [String] = []
      if !state.initializedGit {
        risks.append(String(localized: "未初始化 Git，不能执行首次推送。"))
      }
      if !state.hasConfiguredRemote {
        risks.append(String(localized: "origin remote 未配置，首次推送会失败。"))
      }
      return risks
    case .deployment:
      if state.pushBranch == nil {
        return [String(localized: "还没有首次推送，GitHub Pages 不会开始构建。")]
      }
      return []
    }
  }

  private func statusTitle(for step: SiteStarterWizardStep) -> String {
    switch step {
    case .template, .localDirectory:
      return state.hasPreparedSite ? String(localized: "已完成") : String(localized: "待确认")
    case .github:
      return state.hasRemoteRepositoryCreationResult || state.hasVerifiedExistingRepository
        ? String(localized: "已完成")
        : String(localized: "未完成")
    case .generate:
      if state.hasImportedSite {
        return String(localized: "已导入")
      }
      return state.hasPreparedSite ? String(localized: "已生成") : String(localized: "未生成")
    case .firstPush:
      return state.pushBranch == nil ? String(localized: "未推送") : String(localized: "已推送")
    case .deployment:
      return state.pushBranch == nil ? String(localized: "待推送") : String(localized: "待检查")
    }
  }

  private func statusSystemImage(for step: SiteStarterWizardStep) -> String {
    switch step {
    case .template, .localDirectory:
      return state.hasPreparedSite ? "checkmark.circle" : "clock"
    case .github:
      return state.hasRemoteRepositoryCreationResult || state.hasVerifiedExistingRepository
        ? "checkmark.circle"
        : "circle"
    case .generate:
      return state.hasPreparedSite ? "checkmark.circle" : "circle"
    case .firstPush:
      return state.pushBranch == nil ? "circle" : "checkmark.circle"
    case .deployment:
      return "clock"
    }
  }
}
