import PublishingWorkbenchCore
import SwiftUI

struct ProjectFileSaveRecoveryBanner: View {
  let summary: String?
  let isRetrying: Bool
  let recover: () -> Void

  var body: some View {
    if summary != nil || isRetrying {
      HStack(spacing: WorkbenchSpacing.control) {
        if isRetrying {
          ProgressView().controlSize(.small)
          Text("正在重新写入项目文件…")
        } else if let summary {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(WorkbenchTheme.warning)
            .accessibilityHidden(true)
          Text(summary)
            .lineLimit(3)
          Spacer(minLength: WorkbenchSpacing.control)
          Button("处理…", action: recover)
            .accessibilityHint("检查保存错误、更改项目目录或查看失败文件")
        }
      }
      .font(.callout)
      .padding(.horizontal, WorkbenchSpacing.content)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .top) { Divider() }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings-project-file-save-recovery")
    }
  }
}
