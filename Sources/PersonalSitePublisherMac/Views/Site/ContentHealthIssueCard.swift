import PublishingWorkbenchCore
import SwiftUI

struct ContentHealthIssueCard: View {
  let issue: PreflightIssue
  let onFocus: (() -> Void)?

  init(issue: PreflightIssue, onFocus: (() -> Void)? = nil) {
    self.issue = issue
    self.onFocus = onFocus
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      SeverityBadge(severity: issue.severity)
      Text(issue.title)
        .font(.workbenchItemTitle)
      Text(issue.message)
        .font(.workbenchSupporting)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if let onFocus {
        HStack {
          Spacer(minLength: 0)
          Button {
            onFocus()
          } label: {
            Label("定位到\(issue.contentHealthFocusTargetTitle)", systemImage: "arrow.right.circle")
          }
          .buttonStyle(.link)
          .controlSize(.small)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension PreflightIssue {
  var contentHealthFocusTargetTitle: String {
    switch structuredField {
    case .body:
      return String(localized: "正文")
    case .summary:
      return String(localized: "摘要")
    case .attachments, .cover, .coverAlt:
      return String(localized: "图片")
    case .repository, .contentRoot, .assetRoot, .markdownPathPattern, .repositoryPath:
      return String(localized: "仓库")
    default:
      return String(localized: "元数据")
    }
  }
}
