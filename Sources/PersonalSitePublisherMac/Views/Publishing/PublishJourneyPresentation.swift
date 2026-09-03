import Foundation
import PublishingWorkbenchCore

public enum PublishJourneyStepStatus: Equatable {
  case upcoming
  case active
  case complete
  case blocked
}

public struct PublishJourneyStep: Identifiable, Equatable {
  public let id: String
  public let title: String
  public let detail: String
  public let status: PublishJourneyStepStatus
  public let systemImage: String

  public init(
    id: String, title: String, detail: String, status: PublishJourneyStepStatus, systemImage: String
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
    self.systemImage = systemImage
  }
}

public enum PublishJourneySettingsTarget: Equatable {
  case repository
  case deployment
}

public struct PublishJourneyPresentation: Equatable {
  public let title: String
  public let detail: String
  public let steps: [PublishJourneyStep]
  public let settingsTarget: PublishJourneySettingsTarget?
  public let settingsActionTitle: String?
  public let configurationMessage: String?
  public let isPrimaryActionEnabled: Bool
  public let primaryActionTitle: String
  public let primaryActionHint: String

  public init(
    title: String, detail: String, steps: [PublishJourneyStep],
    settingsTarget: PublishJourneySettingsTarget?, settingsActionTitle: String?,
    configurationMessage: String?, isPrimaryActionEnabled: Bool, primaryActionTitle: String,
    primaryActionHint: String
  ) {
    self.title = title
    self.detail = detail
    self.steps = steps
    self.settingsTarget = settingsTarget
    self.settingsActionTitle = settingsActionTitle
    self.configurationMessage = configurationMessage
    self.isPrimaryActionEnabled = isPrimaryActionEnabled
    self.primaryActionTitle = primaryActionTitle
    self.primaryActionHint = primaryActionHint
  }

  public static func make(
    profile: SiteProfile, preview: RemoteRepositoryPublishPreview, isWebsiteDraft: Bool,
    isPreparing: Bool, isPublishing: Bool, progressStage: RemoteRepositoryPublishProgressStage?,
    latestRecord: ReleaseRecord?, deploymentSnapshot: DeploymentStatusSnapshot?
  ) -> Self {
    let repoMissing =
      profile.repoOwner.trimmedForPublishing.isEmpty
      || profile.repoName.trimmedForPublishing.isEmpty
    let tokenMissing = !preview.hasToken || preview.tokenAccessFailureMessage != nil
    let accessDenied = preview.accessCheck?.canWrite == false
    let conflict = preview.mode == .directCommit && preview.remoteRiskState == .conflict
    let repositoryBlocked = repoMissing || tokenMissing || accessDenied
    let contentBlocked = !preview.blockingIssues.isEmpty || conflict
    let deploymentIssues = DeploymentConfigurationReadiness(profile: profile).issues
    let remoteWriteEnabled = !repositoryBlocked && !contentBlocked
    let settingsTarget: PublishJourneySettingsTarget? =
      repositoryBlocked ? .repository : (deploymentIssues.isEmpty ? nil : .deployment)
    let configurationMessage =
      deploymentIssues.isEmpty
      ? nil
      : String(
        format: String(localized: "可以推送，但无法把部署检查当成生产页面证明：%@"),
        deploymentIssues.joined(separator: "、")
      )

    let failedProgress = progressStage == .failed || latestRecord?.kind == .remotePublishFailure
    let remoteRecordComplete =
      latestRecord.map {
        [.remoteDirectCommit, .remotePreviewBranch, .remoteReviewRequest].contains($0.kind)
          && $0.commitSHA?.trimmedForPublishing.nilIfEmpty != nil
      } ?? false
    let prepareStatus: PublishJourneyStepStatus =
      repositoryBlocked || contentBlocked
      ? .blocked
      : (isPreparing
        ? .active
        : (remoteWriteEnabled && (!preview.changedPaths.isEmpty || remoteRecordComplete)
          ? .complete : .upcoming))
    let uploadStatus: PublishJourneyStepStatus =
      failedProgress
      ? .blocked
      : (remoteRecordComplete
        ? .complete : (isPublishing && progressStage != .completed ? .active : .upcoming))

    var steps = [
      PublishJourneyStep(
        id: "prepare",
        title: String(localized: "准备"),
        detail: repositoryBlocked
          ? String(localized: "仓库连接或写入权限尚未就绪。")
          : contentBlocked
            ? String(localized: "发布前检查未通过。")
            : String(localized: "检查仓库、权限与文章内容。"),
        status: prepareStatus,
        systemImage: "checklist"
      ),
      PublishJourneyStep(
        id: "upload",
        title: String(localized: "推送"),
        detail: failedProgress
          ? String(localized: "远端推送失败。")
          : remoteRecordComplete
            ? String(localized: "内容已推送到远端仓库。")
            : String(localized: "把文章文件写入远端仓库。"),
        status: uploadStatus,
        systemImage: "arrow.up.circle"
      ),
    ]

    if !isWebsiteDraft {
      let reviewStatus: PublishJourneyStepStatus
      let reviewDetail: String
      if preview.mode == .directCommit {
        reviewStatus =
          latestRecord?.kind == .remoteDirectCommit
            && latestRecord?.commitSHA?.trimmedForPublishing.nilIfEmpty != nil
          ? .complete : .upcoming
        reviewDetail =
          reviewStatus == .complete
          ? String(localized: "目标分支已写入提交。")
          : String(localized: "目标分支直接提交，不经过 PR/MR。")
      } else if let state = latestRecord?.reviewStatus?.state {
        switch state {
        case .open, .locked:
          reviewStatus = .active
          reviewDetail = String(localized: "PR/MR 已创建，等待合并。")
        case .merged:
          reviewStatus = .complete
          reviewDetail = String(localized: "PR/MR 已合并到目标分支。")
        case .closedWithoutMerge:
          reviewStatus = .blocked
          reviewDetail = String(localized: "PR/MR 已关闭且未合并。")
        }
      } else {
        reviewStatus = .upcoming
        reviewDetail = String(localized: "等待 PR/MR 创建或合并。")
      }
      steps.append(
        PublishJourneyStep(
          id: "reviewOrTarget",
          title: preview.mode == .directCommit
            ? String(localized: "目标分支")
            : String(localized: "合并"),
          detail: reviewDetail,
          status: reviewStatus,
          systemImage: preview.mode == .directCommit ? "checkmark.seal" : "arrow.triangle.merge"
        )
      )

      let deployStatus: PublishJourneyStepStatus
      let deployDetail: String
      if deploymentSnapshot?.level == .failed {
        deployStatus = .blocked
        deployDetail = String(localized: "部署检查失败。")
      } else if deploymentSnapshot?.level == .success
        && deploymentSnapshot?.attributionVerified == true
      {
        deployStatus = .complete
        deployDetail = String(localized: "部署提交已匹配，生产页面验证完成。")
      } else if latestRecord?.deploymentCommitSHA != nil
        || latestRecord?.reviewStatus?.state == .merged
      {
        deployStatus = .active
        deployDetail = String(localized: "已推送或合并，等待部署提交与页面验证。")
      } else {
        deployStatus = .upcoming
        deployDetail = String(localized: "部署后核对提交归因和线上页面。")
      }
      steps.append(
        PublishJourneyStep(
          id: "onlineVerification",
          title: String(localized: "部署验证"),
          detail: deployDetail,
          status: deployStatus,
          systemImage: "globe"
        )
      )
    }

    let enabled =
      remoteWriteEnabled && preview.blockingIssues.isEmpty && !conflict && !isPreparing
      && !isPublishing
    let settingsActionTitle: String?
    switch settingsTarget {
    case .repository:
      settingsActionTitle = String(localized: "配置代码仓库")
    case .deployment:
      settingsActionTitle = String(localized: "完善部署验证")
    case nil:
      settingsActionTitle = nil
    }
    return Self(
      title: isWebsiteDraft
        ? String(localized: "同步网站草稿")
        : String(localized: "发布到网站"),
      detail: isWebsiteDraft
        ? String(localized: "只推送草稿分支，不代表生产站点已部署。")
        : String(localized: "推送、合并、部署验证分别显示，线上可达不等于发布完成。"),
      steps: steps,
      settingsTarget: settingsTarget,
      settingsActionTitle: settingsActionTitle,
      configurationMessage: configurationMessage,
      isPrimaryActionEnabled: enabled,
      primaryActionTitle: isWebsiteDraft
        ? String(localized: "同步网站草稿…")
        : String(localized: "发布到网站…"),
      primaryActionHint: enabled
        ? isWebsiteDraft
          ? String(localized: "将草稿同步到远端分支")
          : String(localized: "开始远端发布流程")
        : String(localized: "请先完成发布前检查")
    )
  }
}
