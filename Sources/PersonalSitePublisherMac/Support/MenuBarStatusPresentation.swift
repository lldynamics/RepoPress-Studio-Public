import Foundation
import PublishingWorkbenchCore

/// A compact projection of the active site's recorded state. A previous
/// successful deployment must not mask a newer release awaiting verification.
struct MenuBarStatusPresentation {
  let repositorySummary: String
  let repositoryScannedAt: Date?
  let deploymentSummary: String
  let deploymentCheckedAt: Date?

  init(profile: SiteProfile, report: RepositoryScanReport?, entries: [ReleaseLedgerEntry]) {
    if profile.localRepositoryRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      repositorySummary = String(localized: "未配置本地仓库")
      repositoryScannedAt = nil
    } else if let report {
      repositoryScannedAt = report.scannedAt
      if !report.hasGitDirectory {
        repositorySummary = String(localized: "未发现 Git 仓库")
      } else if report.changedFiles.isEmpty {
        repositorySummary = String(localized: "工作区干净")
      } else {
        repositorySummary = String(
          format: String(localized: "%lld 个未提交变更"),
          Int64(report.changedFiles.count)
        )
      }
    } else {
      repositorySummary = String(localized: "尚未扫描仓库")
      repositoryScannedAt = nil
    }

    let latestRelease =
      entries
      .filter { entry in
        switch entry.record.kind {
        case .directCommit, .remoteDirectCommit, .remoteReviewRequest, .remotePublishFailure,
          .remoteRollback:
          return true
        default:
          return false
        }
      }
      .max { $0.record.createdAt < $1.record.createdAt }
    deploymentSummary =
      latestRelease?.status.localizedDisplayName
      ?? String(localized: "尚无部署记录")
    deploymentCheckedAt = latestRelease?.deploymentStatus?.checkedAt
  }
}
