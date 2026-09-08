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
    to draft: inout ArticleDraft,
    baseline: [String: [String]] = [:]
  ) -> ContentHealthAIFixApplicationResult {
    var appliedKeys: [String] = []
    var skippedKeys: [String] = []
    var conflicts: [ContentHealthAIFixFieldConflict] = []

    for item in fields where item.isSelected {
      let key = canonicalKey(for: item.fieldKey)
      if let originalValue = baseline[key],
        originalValue != comparisonValue(for: draft, fieldKey: key)
      {
        conflicts.append(
          ContentHealthAIFixFieldConflict(
            fieldKey: item.fieldKey,
            currentValue: value(for: draft, fieldKey: key)
          ))
        continue
      }
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
      skippedKeys: skippedKeys,
      conflicts: conflicts
    )
  }

  static func value(for draft: ArticleDraft, fieldKey rawKey: String) -> String {
    switch canonicalKey(for: rawKey) {
    case "title": draft.title
    case "slug": draft.slug
    case "summary", "description": draft.summary
    case "tags": draft.tags.joined(separator: ", ")
    default: ""
    }
  }

  private static func comparisonValue(for draft: ArticleDraft, fieldKey: String) -> [String] {
    canonicalKey(for: fieldKey) == "tags" ? draft.tags : [value(for: draft, fieldKey: fieldKey)]
  }

  static func baseline(for draft: ArticleDraft) -> [String: [String]] {
    Dictionary(
      uniqueKeysWithValues: supportedFieldKeys.map {
        ($0, comparisonValue(for: draft, fieldKey: $0))
      })
  }
}

struct ContentHealthAIFixApplicationResult: Equatable {
  let appliedKeys: [String]
  let skippedKeys: [String]
  let conflicts: [ContentHealthAIFixFieldConflict]

  var appliedCount: Int { appliedKeys.count }
  var skippedCount: Int { skippedKeys.count }
  var conflictCount: Int { conflicts.count }
  var didApplyChanges: Bool { appliedCount > 0 }
}

struct ContentHealthAIFixFieldConflict: Equatable {
  let fieldKey: String
  let currentValue: String
}

enum ContentHealthAIFixApplyFeedback: Equatable {
  case applied(ContentHealthAIFixApplicationResult)
  case failed(String)

  var message: String {
    switch self {
    case .applied(let result):
      if result.conflictCount > 0 {
        let currentValues = result.conflicts.map { "\($0.fieldKey)：\($0.currentValue)" }
          .joined(separator: "；")
        if result.appliedCount > 0 {
          return String(
            format: String(localized: "已应用 %d 个字段；%d 个字段已在其他窗口变化，保留当前值：%@。"),
            result.appliedCount,
            result.conflictCount,
            currentValues
          )
        }
        return String(
          format: String(localized: "所选字段已在其他窗口变化，未覆盖当前值：%@。请重新生成预览。"),
          currentValues
        )
      }
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
    if case .applied(let result) = self { return result.didApplyChanges }
    return false
  }
}
