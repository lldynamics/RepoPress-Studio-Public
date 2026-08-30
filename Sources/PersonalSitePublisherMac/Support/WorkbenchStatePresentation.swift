import Foundation
import SwiftUI

/// The semantic state shown when a workbench surface cannot show its usual content.
///
/// These cases are intentionally typed. Callers must select the state they mean instead
/// of deriving appearance or accessibility behavior from a display string.
enum WorkbenchStateKind: Equatable, Sendable {
  case loading(progress: Double? = nil, detail: String? = nil)
  case empty
  case success(detail: String)
  case failure(reason: String)
  case partialSuccess(detail: String)
  case awaitingConfirmation(detail: String)
  case unavailable(reason: String)

  var titleKey: String {
    switch self {
    case .loading:
      return "正在加载"
    case .empty:
      return "暂无内容"
    case .success:
      return "已完成"
    case .failure:
      return "失败"
    case .partialSuccess:
      return "部分完成"
    case .awaitingConfirmation:
      return "等待确认"
    case .unavailable:
      return "当前操作暂不可用"
    }
  }

  var defaultSystemImage: String {
    switch self {
    case .loading:
      return "arrow.triangle.2.circlepath"
    case .empty:
      return "tray"
    case .success:
      return "checkmark.circle"
    case .failure:
      return "xmark.octagon"
    case .partialSuccess:
      return "exclamationmark.triangle"
    case .awaitingConfirmation:
      return "hand.raised"
    case .unavailable:
      return "nosign"
    }
  }

  var tone: WorkbenchStateTone {
    switch self {
    case .loading:
      return .progress
    case .empty:
      return .neutral
    case .success:
      return .success
    case .failure:
      return .risk
    case .partialSuccess, .awaitingConfirmation, .unavailable:
      return .warning
    }
  }

  var reason: String? {
    switch self {
    case .loading, .empty, .success, .partialSuccess, .awaitingConfirmation:
      return nil
    case .failure(let reason), .unavailable(let reason):
      return Self.normalized(reason)
    }
  }

  var verbatimDetail: String? {
    switch self {
    case .loading(_, let detail):
      return detail.flatMap(Self.normalized)
    case .success(let detail), .partialSuccess(let detail), .awaitingConfirmation(let detail):
      return Self.normalized(detail)
    case .empty, .failure, .unavailable:
      return nil
    }
  }

  var loadingProgress: Double? {
    guard case .loading(let progress?, _) = self else { return nil }
    guard progress.isFinite else { return 0 }
    return min(max(progress, 0), 1)
  }

  private static func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum WorkbenchStateTone: Equatable, Sendable {
  case neutral
  case progress
  case success
  case warning
  case risk
}

/// State surfaces remain silent by default because their content is already exposed in
/// the current accessibility hierarchy. A caller may opt into an announcement without
/// asking the component to move VoiceOver focus.
enum WorkbenchStateAnnouncementPolicy: Equatable, Sendable {
  case silent
  case announce

  var shouldAnnounce: Bool {
    self == .announce
  }

  var shouldMoveAccessibilityFocus: Bool {
    false
  }
}

/// The value object consumed by `WorkbenchStateView`.
struct WorkbenchStatePresentation: Equatable, Sendable {
  let kind: WorkbenchStateKind
  /// An optional caller-supplied replacement for the semantic SF Symbol.
  let icon: String?
  let announcementPolicy: WorkbenchStateAnnouncementPolicy

  init(
    kind: WorkbenchStateKind,
    icon: String? = nil,
    announcementPolicy: WorkbenchStateAnnouncementPolicy = .silent
  ) {
    self.kind = kind
    self.icon = icon
    self.announcementPolicy = announcementPolicy
  }

  var titleKey: String {
    kind.titleKey
  }

  var title: LocalizedStringKey {
    LocalizedStringKey(titleKey)
  }

  var localizedTitle: String {
    switch kind {
    case .loading:
      return String(localized: "正在加载")
    case .empty:
      return String(localized: "暂无内容")
    case .success:
      return String(localized: "已完成")
    case .failure:
      return String(localized: "失败")
    case .partialSuccess:
      return String(localized: "部分完成")
    case .awaitingConfirmation:
      return String(localized: "等待确认")
    case .unavailable:
      return String(localized: "当前操作暂不可用")
    }
  }

  var tone: WorkbenchStateTone {
    kind.tone
  }

  var systemImage: String {
    icon ?? kind.defaultSystemImage
  }

  /// Keeps dynamic diagnostic text verbatim while consistently identifying it as a reason.
  var formattedReason: String? {
    guard let reason = kind.reason else { return nil }
    let format = String(localized: "原因：%@")
    let canonicalPrefix = String(format: format, "")
    let semanticPrefixes = [
      canonicalPrefix,
      canonicalPrefix.replacingOccurrences(of: "：", with: ":"),
      canonicalPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
      "\(localizedTitle)：",
      "\(localizedTitle):",
    ]
    var normalizedReason = reason
    while let prefix = semanticPrefixes.first(where: {
      !$0.isEmpty && normalizedReason.hasPrefix($0)
    }) {
      normalizedReason = String(normalizedReason.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !normalizedReason.isEmpty else { return nil }
    return String(format: format, normalizedReason)
  }

  var verbatimDetail: String? {
    kind.verbatimDetail
  }

  var loadingProgress: Double? {
    kind.loadingProgress
  }

  /// Includes the semantic kind so identical text from different states does not collide.
  var announcementIdentity: String {
    let payload = kind.reason ?? kind.verbatimDetail ?? ""
    return "\(kindIdentity)|\(payload)"
  }

  var announcementText: String {
    [localizedTitle, formattedReason ?? verbatimDetail]
      .compactMap { $0 }
      .joined(separator: "\n")
  }

  var announcementSeverity: AccessibleStatusSeverity {
    switch kind {
    case .loading, .empty:
      return .info
    case .success:
      return .success
    case .partialSuccess, .awaitingConfirmation, .unavailable:
      return .warning
    case .failure:
      return .error
    }
  }

  private var kindIdentity: String {
    switch kind {
    case .loading:
      return "loading"
    case .empty:
      return "empty"
    case .success:
      return "success"
    case .failure:
      return "failure"
    case .partialSuccess:
      return "partialSuccess"
    case .awaitingConfirmation:
      return "awaitingConfirmation"
    case .unavailable:
      return "unavailable"
    }
  }
}

/// A deliberately bounded action set for state surfaces. It supports zero, one, or two
/// actions without erasing the action view types.
struct WorkbenchStateActions {
  let primary: WorkbenchStateAction?
  let secondary: WorkbenchStateAction?

  init(
    primary: WorkbenchStateAction? = nil,
    secondary: WorkbenchStateAction? = nil
  ) {
    self.primary = primary
    self.secondary = secondary
  }

  static var none: WorkbenchStateActions {
    WorkbenchStateActions()
  }
}

struct WorkbenchStateAction {
  let title: LocalizedStringKey
  let systemImage: String
  let role: ButtonRole?
  let isEnabled: Bool
  let action: () -> Void

  init(
    title: LocalizedStringKey,
    systemImage: String = "arrow.right.circle",
    role: ButtonRole? = nil,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.role = role
    self.isEnabled = isEnabled
    self.action = action
  }
}
