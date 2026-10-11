import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct ScheduledPublishTemplateSection: View {
  let profile: SiteProfile
  @State private var showsTemplate = false

  var body: some View {
    Section("定时发布") {
      Button("查看 GitHub Actions 定时模板…") { showsTemplate = true }
        .disabled(profile.repositoryProvider != .github)
        .accessibilityLabel("查看定时发布工作流模板")
      Text("将定时触发片段合并到现有部署工作流；文章到期后需要重新构建站点。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .sheet(isPresented: $showsTemplate) {
      ScheduledPublishTemplateSheet(profile: profile)
    }
  }
}

private struct ScheduledPublishTemplateSheet: View {
  let profile: SiteProfile
  @Environment(\.dismiss) private var dismiss
  private var template: ScheduledPublishWorkflowTemplate {
    ScheduledPublishWorkflowTemplate(profile: profile)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
      Text("GitHub Actions 定时触发模板").font(.headline)
      Text("把以下触发器合并到默认分支中的现有部署工作流，保留已有的 push、构建和部署步骤。")
      Text(template.triggerYAML)
        .font(.body.monospaced()).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(WorkbenchSpacing.content)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
      if template.supportsFutureContent, profile.siteKind == .jekyll {
        Text("Jekyll：设置未来的 date，并确保 _config.yml 未开启 future 且构建未使用 --future。到期后的构建才会包含文章。")
      } else if template.supportsFutureContent {
        Text("Hugo：设置未来的 publishDate 或 date，保持 draft 为 false，并确保构建未启用 buildFuture。到期后的构建才会包含文章。")
      } else {
        Text("此生成器需要额外的到期内容筛选或到期提交步骤。仅添加定时构建不能保证文章在到期前隐藏；可先使用文章到期提醒。")
      }
      Text("示例每小时第 17 分钟触发，使用 UTC。GitHub 定时任务可能延迟；公开仓库长期无活动时会自动停用。")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("复制模板") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(template.triggerYAML, forType: .string)
        }
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(width: 620)
  }
}
