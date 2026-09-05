import Foundation
import PublishingWorkbenchCore

/// The review sheet deliberately exposes only metadata that its apply action
/// can write today. Keeping parsing and mutation behind this one policy avoids
/// presenting a selectable field that will later be silently ignored.
enum ContentHealthAIFixFieldPolicy {
  static let supportedFieldKeys: Set<String> = ["title", "slug", "summary", "description", "tags"]

  static func canonicalKey(for rawKey: String) -> String {
    rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  static func supports(_ rawKey: String) -> Bool {
    supportedFieldKeys.contains(canonicalKey(for: rawKey))
  }

  static func apply(
    _ fields: [FrontMatterFixFieldItem],
    to draft: inout ArticleDraft
  ) -> ContentHealthAIFixApplicationResult {
    var appliedKeys: [String] = []
    var skippedKeys: [String] = []

    for item in fields where item.isSelected {
      switch canonicalKey(for: item.fieldKey) {
      case "title":
        draft.title = item.proposedValue
        appliedKeys.append(item.fieldKey)
      case "slug":
        draft.slug = item.proposedValue
        appliedKeys.append(item.fieldKey)
      case "summary", "description":
        draft.summary = item.proposedValue
        appliedKeys.append(item.fieldKey)
      case "tags":
        draft.tags = item.proposedValue
          .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        appliedKeys.append(item.fieldKey)
      default:
        skippedKeys.append(item.fieldKey)
      }
    }

    return ContentHealthAIFixApplicationResult(
      appliedKeys: appliedKeys,
      skippedKeys: skippedKeys
    )
  }
}

struct ContentHealthAIFixApplicationResult: Equatable {
  let appliedKeys: [String]
  let skippedKeys: [String]

  var appliedCount: Int { appliedKeys.count }
  var skippedCount: Int { skippedKeys.count }
  var didApplyChanges: Bool { appliedCount > 0 }
}

enum ContentHealthAIFixApplyFeedback: Equatable {
  case applied(ContentHealthAIFixApplicationResult)
  case failed(String)

  var message: String {
    switch self {
    case .applied(let result):
      if result.skippedCount > 0 {
        return String(
          format: String(localized: "已应用 %d 个字段，跳过 %d 个当前不支持的字段。"),
          result.appliedCount, result.skippedCount
        )
      }
      return String(format: String(localized: "已应用 %d 个字段。"), result.appliedCount)
    case .failed(let message):
      return message
    }
  }

  var isSuccess: Bool {
    if case .applied = self { return true }
    return false
  }
}
