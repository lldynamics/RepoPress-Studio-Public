import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// The primary publish action also carries the current article's readiness
/// summary. Clicking it still opens the existing publish drawer; the status is
/// explanatory and never starts a second preflight or publish path.
struct WorkspacePreparePublishToolbarButton: View {
  let store: WorkbenchStore
  @ObservedObject private var statusState: WorkbenchPublishStatusFeatureFacade
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  let selectedDraftID: UUID?
  let action: () -> Void

  init(store: WorkbenchStore, selectedDraftID: UUID?, action: @escaping () -> Void) {
    self.store = store
    _statusState = ObservedObject(wrappedValue: store.publishStatus)
    self.selectedDraftID = selectedDraftID
    self.action = action
  }

  init(store: WorkbenchStore, windowSession: WorkspaceWindowSession, action: @escaping () -> Void) {
    self.init(store: store, selectedDraftID: windowSession.selectedDraftID, action: action)
  }

  var body: some View {
    let status = draftStatus

    Button(action: action) {
      HStack(spacing: WorkbenchSpacing.icon) {
        Label(String(localized: "发布"), systemImage: "paperplane.fill")

        if let count = status.count, count > 0 {
          Text(count, format: .number)
            .font(.workbenchMetadata.weight(.bold).monospacedDigit())
            .padding(.horizontal, WorkbenchSpacing.tight)
            .padding(.vertical, 1)
            .background(Color.white.opacity(0.18), in: Capsule())
        }
      }
    }
    .buttonStyle(
      WorkspaceToolbarIconButtonStyle(
        isActive: false,
        showsTitle: true,
        prominence: .primaryAction
      )
    )
    .help(publishHelp(for: status))
    .accessibilityLabel(String(localized: "发布"))
    .accessibilityValue("\(status.value)，\(status.detail)")
    .accessibilityHint(String(localized: "打开本次发布清单和一键发布流程"))
    .accessibilityIdentifier("workspace-prepare-publish")
    .articlePreflightRefresh(store: store, draftID: selectedDraftID, isEnabled: autoRunPreflight)
  }

  /// The toolbar is rendered once per window, while `WorkbenchStore` keeps a
  /// shared compatibility selection for commands. Resolve the visible draft
  /// from the window's explicit identity and use draft-scoped evidence.
  private var explicitDraft: ArticleDraft? {
    selectedDraftID.flatMap(store.draft(for:))
  }

  var draftStatus: PublishingStatusPopoverItem {
    guard let draft = explicitDraft else {
      return PublishingStatusPopoverItem(
        area: .draft,
        value: String(localized: "未选择文章"),
        detail: String(localized: "选择文章后可查看其发布检查状态。"),
        statusImage: "doc.badge.questionmark",
        color: .secondary,
        severity: .pending
      )
    }

    if draft.isGeneralDraft {
      return PublishingStatusPopoverItem(
        area: .draft,
        value: String(localized: "通用草稿，未绑定站点"),
        detail: String(localized: "可继续编辑；绑定站点后才会检查发布条件。"),
        statusImage: "doc.text",
        color: .secondary,
        severity: .information
      )
    }

    guard let attention = ArticlePublishAttention.make(store: store, draftID: draft.id) else {
      // A draft of a site other than the active one has no publish panel.
      return Self.pendingStatus(draftTitle: draft.title)
    }
    // Read write/commit conditions for this window's draft, including when
    // another window owns the compatibility selection.
    return Self.status(
      attention: attention,
      publishConditions: store.cachedPublishPreview(for: draft.id)?.localPublishReadiness,
      draftTitle: draft.title
    )
  }

  /// The badge is always `attention.pendingCount`, the number the publish
  /// panel shows as 需要处理; the label and tooltip explain its most severe part.
  static func status(
    attention: ArticlePublishAttention,
    publishConditions readiness: LocalPublishReadiness?,
    draftTitle: String
  ) -> PublishingStatusPopoverItem {
    // Before the first preflight only a partial count exists; show none.
    guard !attention.readiness.isAwaitingPreflight else {
      return pendingStatus(draftTitle: draftTitle)
    }
    let decision = DraftPublishStatus(
      issues: attention.readiness.issues.map {
        DraftPublishStatus.Issue(severity: $0.severity, title: $0.title)
      },
      pendingCount: attention.pendingCount,
      accountIsBlocked: attention.isAccountBlocked,
      accountDetail: attention.account.detail,
      readiness: readiness,
      isLoading: attention.readiness.isLoading
    )
    let area = PublishingStatusArea.draft
    switch decision.state {
    case .contentBlocked:
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "\(decision.severityCount) 个阻断项"),
        detail: decision.reason ?? draftTitle.nilIfEmpty
          ?? String(localized: "当前文章存在发布阻断项。"),
        statusImage: "xmark.octagon",
        color: WorkbenchTheme.risk,
        severity: .error,
        count: decision.pendingCount
      )
    case .publishConditionsBlocked:
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "\(decision.severityCount) 个发布条件未满足"),
        detail: decision.reason ?? draftTitle.nilIfEmpty
          ?? String(localized: "当前文章存在发布阻断项。"),
        statusImage: "xmark.octagon",
        color: WorkbenchTheme.risk,
        severity: .error,
        count: decision.pendingCount
      )
    case .warning:
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "\(decision.pendingCount) 个文章警告"),
        detail: decision.reason ?? draftTitle.nilIfEmpty
          ?? String(localized: "当前文章需要审阅发布提示。"),
        statusImage: "exclamationmark.triangle",
        color: WorkbenchTheme.warning,
        severity: .warning,
        count: decision.pendingCount
      )
    case .pending:
      return pendingStatus(draftTitle: draftTitle)
    case .ready:
      return PublishingStatusPopoverItem(
        area: area,
        value: String(localized: "检查通过"),
        detail: draftTitle.nilIfEmpty ?? String(localized: "当前文章已具备写入和提交条件。"),
        statusImage: "checkmark.circle",
        color: WorkbenchTheme.success,
        severity: .ready
      )
    }
  }

  private static func pendingStatus(draftTitle: String) -> PublishingStatusPopoverItem {
    PublishingStatusPopoverItem(
      area: .draft,
      value: String(localized: "待运行检查"),
      detail: draftTitle.nilIfEmpty ?? String(localized: "请运行发布前检查。"),
      statusImage: "checklist",
      color: .secondary,
      severity: .pending
    )
  }

  private func publishHelp(for status: PublishingStatusPopoverItem) -> String {
    if let count = status.count, count > 0 {
      return String(localized: "发布前需处理：\(status.detail)。点击打开本次发布清单。")
    }
    return String(localized: "\(status.value)：\(status.detail)。点击打开本次发布清单。")
  }
}
