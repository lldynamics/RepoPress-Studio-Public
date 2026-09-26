import Foundation
import PublishingPreviewCore

/// Renders an explicit publishing snapshot without reading or mutating workspace state.
enum PublishingAIPromptRenderer {
  static func render(
    draft: ArticleDraft,
    profile: SiteProfile,
    package: PublishPackage,
    issues: [PreflightIssue],
    localPreview: LocalPublishPreview?,
    sitePreview: LocalSitePreviewPlan?,
    imageReport: ImageWorkbenchReport?,
    reviewDraft: RemoteReviewDraft
  ) -> String {
    var lines: [String] = [
      "# 发布协助请求",
      "",
      "站点：\(profile.name)",
      "标题：\(draft.title)",
      "发布路径：\(package.markdownPath)",
      "",
      "## 摘要",
      draft.summary.nilIfEmpty ?? "无摘要",
      "",
      "## 发布检查",
    ]
    if issues.isEmpty {
      lines.append("- 无阻断项")
    } else {
      lines.append(
        contentsOf: issues.map { "- [\($0.severity.displayName)] \($0.title)：\($0.message)" })
    }
    lines.append(contentsOf: [
      "",
      "## 发布准备建议",
      "Mac 发布上下文：",
      "本地 diff：\(localPreview?.changedFileDiffs.count ?? 0) 个待写入变化。",
      "本地预览：\(sitePreview?.command ?? "尚未配置本地预览命令。")",
      "图片检查：\(imageReport?.items.count ?? 0) 张，缺 alt \(imageReport?.missingAltTextCount ?? 0) 张，缺源图 \(imageReport?.missingSourceCount ?? 0) 张。",
      "",
      "## PR/MR 描述草稿",
      "标题：\(reviewDraft.title)",
      reviewDraft.body,
    ])
    lines.append("")
    lines.append("## 正文")
    lines.append(draft.bodyMarkdown)
    return lines.joined(separator: "\n")
  }
}
