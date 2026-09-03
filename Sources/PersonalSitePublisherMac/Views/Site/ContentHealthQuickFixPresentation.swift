import Foundation
import PublishingWorkbenchCore

enum ContentHealthQuickFixKind: Equatable, Sendable {
  case generateImageAlt(attachmentID: UUID)
  case normalizeSlug(proposedSlug: String)
  case repairRelativePath(target: String)
}

struct ContentHealthQuickFixPresentation: Equatable, Sendable {
  let kind: ContentHealthQuickFixKind
  let title: String
  let systemImage: String
  let help: String
}

extension PreflightIssue {
  func contentHealthQuickFix(for draft: ArticleDraft) -> ContentHealthQuickFixPresentation? {
    switch category {
    case .missingMediaAlt:
      guard
        let rawID = relatedValue,
        let attachmentID = UUID(uuidString: rawID),
        let attachment = draft.attachments.first(where: { $0.id == attachmentID }),
        !attachment.relativePublishPath.trimmedForPublishing.isEmpty
      else { return nil }
      return ContentHealthQuickFixPresentation(
        kind: .generateImageAlt(attachmentID: attachmentID),
        title: String(localized: "生成并回填 Alt"),
        systemImage: "sparkles.rectangle.stack",
        help: String(localized: "使用当前本地或远端视觉模型分析这张图片，并只回填缺失的 Alt。")
      )

    case .nonStandardSlug:
      guard
        let proposedSlug = relatedValue?.trimmedForPublishing.nilIfEmpty,
        proposedSlug != draft.slug.trimmedForPublishing
      else { return nil }
      return ContentHealthQuickFixPresentation(
        kind: .normalizeSlug(proposedSlug: proposedSlug),
        title: String(localized: "标准化 Slug"),
        systemImage: "textformat.abc",
        help: String(localized: "将 Slug 转为小写拼音/ASCII；旧路径会进入现有 Slug 变更保护流程。")
      )

    case .brokenInternalLink:
      guard
        let target = relatedValue?.trimmedForPublishing.nilIfEmpty,
        Self.looksLikeRepairableRelativePath(target)
      else { return nil }
      return ContentHealthQuickFixPresentation(
        kind: .repairRelativePath(target: target),
        title: String(localized: "选择资源并修复路径"),
        systemImage: "folder.badge.questionmark",
        help: String(localized: "选择仓库内的正确文件，并精确替换正文中的失效目标。")
      )

    default:
      return nil
    }
  }

  private static func looksLikeRepairableRelativePath(_ target: String) -> Bool {
    guard
      !target.hasPrefix("/"),
      !target.hasPrefix("#"),
      !target.hasPrefix("//"),
      URLComponents(string: target)?.scheme == nil
    else { return false }

    let pathBeforeFragment =
      target
      .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
      .map(String.init) ?? ""
    let path =
      pathBeforeFragment
      .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
      .map(String.init) ?? ""
    return path.contains("/") || !URL(fileURLWithPath: path).pathExtension.isEmpty
  }
}
