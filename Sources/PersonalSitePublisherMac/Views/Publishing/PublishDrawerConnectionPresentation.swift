import Foundation
import PublishingWorkbenchCore

struct PublishDrawerConnectionPresentation {
  enum Remedy: Equatable {
    case account
    case refresh
    case issue(PreflightIssue)
  }

  let canStart: Bool
  let message: String
  let remedy: Remedy?

  static func isDeferredRemoteIssue(_ issue: PreflightIssue) -> Bool {
    issue.field == "remoteBaseline"
      || (issue.field == "repository"
        && (issue.title == String(localized: "远端同路径变更")
          || issue.title == String(localized: "远端状态待确认")))
  }

  static func make(
    preview: RemoteRepositoryPublishPreview?,
    isChecking: Bool = false,
    isPublishing: Bool = false
  ) -> Self {
    if isPublishing {
      return Self(canStart: false, message: String(localized: "当前操作完成后可继续发布。"), remedy: nil)
    }
    if isChecking {
      return Self(canStart: false, message: String(localized: "正在检查发布连接…"), remedy: nil)
    }
    guard let preview else {
      return Self(canStart: false, message: String(localized: "发布预览尚未准备好，请刷新检查。"), remedy: .refresh)
    }
    if let failure = preview.tokenAccessFailureMessage {
      return Self(canStart: false, message: failure, remedy: .account)
    }
    if !preview.hasToken {
      return Self(
        canStart: false, message: String(localized: "尚未配置发布凭据，请先连接 GitHub 或 GitLab 账户。"),
        remedy: .account)
    }
    if let issue = preview.blockingIssues.first(where: { !isDeferredRemoteIssue($0) }) {
      return Self(
        canStart: false, message: issue.title + "：" + issue.message, remedy: .issue(issue))
    }
    if preview.accessCheck?.canWrite == false {
      return Self(
        canStart: false, message: String(localized: "当前账户没有仓库写入权限，请检查发布凭据。"), remedy: .account)
    }
    return Self(
      canStart: true,
      message: String(localized: "可以进入发布确认；权限和远端变化将在确认前再次检查。"),
      remedy: nil
    )
  }
}

enum PublishReadinessIssueGrouping {
  /// Coalesce the same actionable cause, retaining all distinct explanations
  /// and the strongest severity. Different paths and unclassified findings
  /// remain separate even when their titles happen to match.
  static func coalesced(_ issues: [PreflightIssue]) -> [PreflightIssue] {
    struct Key: Hashable {
      let title: String
      let field: String?
      let relatedValue: String?
      let unclassifiedMessage: String?
    }
    var result: [PreflightIssue] = []
    var indices: [Key: Int] = [:]
    var messages: [Key: [String]] = [:]
    for issue in issues {
      let key = Key(
        title: issue.title, field: issue.field, relatedValue: issue.relatedValue,
        unclassifiedMessage: issue.field == nil ? issue.message : nil)
      if let index = indices[key] {
        if !(messages[key] ?? []).contains(issue.message) {
          messages[key, default: []].append(issue.message)
          result[index].message = messages[key, default: []].joined(separator: "\n")
        }
        if issue.severity.sortRank < result[index].severity.sortRank {
          result[index].severity = issue.severity
        }
      } else {
        indices[key] = result.count
        messages[key] = [issue.message]
        result.append(issue)
      }
    }
    return result
  }
}
