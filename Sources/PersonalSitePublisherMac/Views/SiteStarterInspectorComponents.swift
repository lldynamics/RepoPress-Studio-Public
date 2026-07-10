import PublishingWorkbenchCore
import SwiftUI

@MainActor
struct SiteStarterInspectorState {
  let hasGeneratedSite: Bool
  let createdFileCount: Int
  let initializedGit: Bool
  let hasConfiguredRemote: Bool
  let deploymentGuidePath: String?
  let hasRepositoryToken: Bool
  let hasRemoteRepositoryCreationResult: Bool
  let pushBranch: String?
  let pushCommitShortSHA: String?
  let pushedFileCount: Int
  let publishActionMessage: String?

  init(store: WorkbenchStore) {
    let result = store.siteStarterResult
    let pushResult = store.siteStarterPushResult

    hasGeneratedSite = result != nil
    createdFileCount = result?.createdFilePaths.count ?? 0
    initializedGit = result?.initializedGit == true
    hasConfiguredRemote = result?.configuredRemoteURL != nil
    deploymentGuidePath = result?.deploymentGuidePath
    hasRepositoryToken = store.repositoryTokenAvailability.hasToken
    hasRemoteRepositoryCreationResult = store.remoteRepositoryCreationResult != nil
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
            .foregroundStyle(.orange)
            .lineLimit(3)
        }
      }
    }
  }

  @ViewBuilder
  private var artifactSection: some View {
    if state.hasGeneratedSite {
      InspectorSection("产物") {
        InspectorStatRow(title: "文件", value: "\(state.createdFileCount)", systemImage: "doc.badge.plus")
        InspectorStatRow(title: "Git", value: state.initializedGit ? "已初始化" : "未初始化", systemImage: "externaldrive")
        InspectorStatRow(title: "origin", value: state.hasConfiguredRemote ? "已配置" : "未配置", systemImage: "point.3.connected.trianglepath.dotted")
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
        InspectorStatRow(title: "提交", value: state.pushCommitShortSHA ?? "未知", systemImage: "number")
        InspectorStatRow(title: "文件", value: "\(state.pushedFileCount)", systemImage: "shippingbox")
      }
    }
  }

  private var currentStepFacts: [String] {
    switch selectedStep {
    case .template:
      return ["模板会决定站点框架、默认 Front Matter 和首篇文章结构。"]
    case .localDirectory:
      return ["目标目录必须是空文件夹；生成后会成为本地站点仓库。"]
    case .github:
      return ["GitHub 仓库创建以向导里的 owner/repo/branch 为准；创建前会同步到当前 Profile。"]
    case .generate:
      return ["生成会创建模板文件、部署工作流、部署说明和初始文章草稿。"]
    case .firstPush:
      return ["首次推送会提交 Starter 文件，并把分支推送到 origin。"]
    case .deployment:
      return ["GitHub Pages 首次部署通常需要到仓库 Settings > Pages 确认来源。"]
    }
  }

  private var currentStepRisks: [String] {
    switch selectedStep {
    case .template:
      return []
    case .localDirectory:
      return state.hasGeneratedSite ? [] : ["选择已有内容的目录会被拒绝；请准备空文件夹。"]
    case .github:
      var risks: [String] = []
      if !state.hasRepositoryToken {
        risks.append("未检测到 GitHub Token，创建仓库会失败。")
      }
      return risks
    case .generate:
      return state.hasGeneratedSite ? [] : ["生成前请确认模板、目录、站点名称和分支。"]
    case .firstPush:
      var risks: [String] = []
      if !state.initializedGit {
        risks.append("未初始化 Git，不能执行首次推送。")
      }
      if !state.hasConfiguredRemote {
        risks.append("origin remote 未配置，首次推送会失败。")
      }
      return risks
    case .deployment:
      if state.pushBranch == nil {
        return ["还没有首次推送，GitHub Pages 不会开始构建。"]
      }
      return []
    }
  }

  private func statusTitle(for step: SiteStarterWizardStep) -> String {
    switch step {
    case .template, .localDirectory:
      return state.hasGeneratedSite ? "已完成" : "待确认"
    case .github:
      return state.hasConfiguredRemote || state.hasRemoteRepositoryCreationResult ? "已完成" : "未完成"
    case .generate:
      return state.hasGeneratedSite ? "已生成" : "未生成"
    case .firstPush:
      return state.pushBranch == nil ? "未推送" : "已推送"
    case .deployment:
      return state.pushBranch == nil ? "待推送" : "待检查"
    }
  }

  private func statusSystemImage(for step: SiteStarterWizardStep) -> String {
    switch statusTitle(for: step) {
    case "已完成", "已生成", "已推送":
      return "checkmark.circle"
    case "未完成", "未生成", "未推送":
      return "circle"
    default:
      return "clock"
    }
  }
}
