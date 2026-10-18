import Foundation
import PublishingWorkbenchCore
import SwiftUI

/// Error badges show the shared actionable checklist count, while their
/// severity and reason describe the strongest outstanding condition.
enum WorkspacePublishToolbarBadge: Equatable {
  case none
  case blockingCount(Int)
  case warningDot

  static func make(severity: PublishingStatusSeverity, count: Int?) -> Self {
    guard let count, count > 0 else { return .none }
    switch severity {
    case .error:
      return .blockingCount(count)
    case .warning:
      return .warningDot
    case .ready, .pending, .information, .active:
      return .none
    }
  }
}

private enum WorkspacePublishToolbarBadgeStyle {
  /// A fine white outline separates the risk fill from the green action fill.
  static let outlineWidth: CGFloat = 1
  /// A white-backed warning tint stays visible on the dark green action fill.
  static let warningTintOpacity = 0.35
}

/// The primary publish action carries the current article's readiness summary.
/// The menu beside it explicitly offers the repository-wide operation.
struct WorkspacePreparePublishToolbarButton: View {
  let store: WorkbenchStore
  @ObservedObject private var statusState: WorkbenchPublishStatusFeatureFacade
  @AppStorage("autoRunPreflight") private var autoRunPreflight = true
  @Environment(\.colorScheme) private var colorScheme
  let selectedDraftID: UUID?
  let commandAction: PublishCommandAction?
  let showChecksAction: (() -> Void)?
  let action: () -> Void

  init(
    store: WorkbenchStore, selectedDraftID: UUID?, commandAction: PublishCommandAction? = nil,
    showChecksAction: (() -> Void)? = nil, action: @escaping () -> Void
  ) {
    self.store = store
    _statusState = ObservedObject(wrappedValue: store.publishStatus)
    self.selectedDraftID = selectedDraftID
    self.commandAction = commandAction
    self.showChecksAction = showChecksAction
    self.action = action
  }

  init(
    store: WorkbenchStore, windowSession: WorkspaceWindowSession,
    commandAction: PublishCommandAction? = nil, showChecksAction: (() -> Void)? = nil,
    action: @escaping () -> Void
  ) {
    self.init(
      store: store, selectedDraftID: windowSession.selectedDraftID,
      commandAction: commandAction, showChecksAction: showChecksAction, action: action)
  }

  var body: some View {
    HStack(spacing: WorkbenchSpacing.tight / 2) {
      publishButton
      if let commandAction {
        Menu {
          Button(String(localized: "发布这篇…")) { commandAction.publishCurrentArticle() }
            .disabled(!commandAction.canPublishCurrentArticle)
          Button(String(localized: "发布全部…")) { commandAction.publishAll() }
            .disabled(!commandAction.canPublishAll)
          if let showChecksAction {
            Divider()
            Button(String(localized: "查看发布检查"), action: showChecksAction)
          }
        } label: {
          // An AppKit-backed menu button takes its name from the label, not
          // from an accessibility modifier, so the icon must carry the title.
          Label(String(localized: "发布方式"), systemImage: "chevron.down")
            .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "选择发布这篇文章或发布全部变更"))
        .accessibilityIdentifier("workspace-publish-menu")
      }
    }
  }

  private var publishButton: some View {
    let status = draftStatus
    let actionTitle = Self.primaryActionTitle(
      isPublished: explicitDraft?.articleState == .published)

    return Button(action: action) {
      HStack(spacing: WorkbenchSpacing.icon) {
        Label(actionTitle, systemImage: "paperplane.fill")

        switch WorkspacePublishToolbarBadge.make(severity: status.severity, count: status.count) {
        case .blockingCount(let count):
          Text(count, format: .number)
            .font(.workbenchMetadata.weight(.bold).monospacedDigit())
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .padding(.horizontal, WorkbenchSpacing.tight)
            .padding(.vertical, WorkbenchSpacing.tight / 4)
            .background(WorkbenchTheme.risk, in: Capsule())
            .overlay {
              Capsule()
                .strokeBorder(
                  Color.white,
                  lineWidth: WorkspacePublishToolbarBadgeStyle.outlineWidth
                )
            }
            .accessibilityHidden(true)
        case .warningDot:
          Circle()
            .fill(
              WorkbenchTheme.warning.opacity(WorkspacePublishToolbarBadgeStyle.warningTintOpacity)
            )
            .background(Color.white, in: Circle())
            .frame(width: WorkbenchIconSize.indicator, height: WorkbenchIconSize.indicator)
            .accessibilityHidden(true)
        case .none:
          EmptyView()
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
    .disabled(!Self.isPrimaryActionEnabled(commandAction))
    .help(publishHelp(for: status))
    .accessibilityLabel(actionTitle)
    .accessibilityValue("\(status.value)，\(status.detail)")
    .accessibilityHint(String(localized: "确认后只提交并推送这篇文章"))
    .accessibilityIdentifier("workspace-prepare-publish")
    .articlePreflightRefresh(store: store, draftID: selectedDraftID, isEnabled: autoRunPreflight)
  }

  static func primaryActionTitle(isPublished: Bool) -> String {
    isPublished ? String(localized: "更新文章") : String(localized: "发布这篇")
  }

  static func isPrimaryActionEnabled(_ commandAction: PublishCommandAction?) -> Bool {
    commandAction?.currentArticleID != nil && commandAction?.isBusy != true
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
        value: String(localized: "仅本地草稿，未绑定站点"),
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

  /// The status retains `attention.pendingCount`, the publish panel's complete
  /// checklist count. The badge distinguishes blockers from warning-only items.
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
        DraftPublishStatus.Issue(
          severity: $0.severity, title: $0.title,
          isOptionalOptimization: $0.isOptionalOptimization
        )
      },
      pendingCount: attention.meaningfulPendingCount,
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
        count: decision.pendingCount > 0 ? decision.pendingCount : nil
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
        count: decision.pendingCount > 0 ? decision.pendingCount : nil
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
        value: String(localized: "可发布"),
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
    guard commandAction?.currentArticleID != nil else { return String(localized: "选择文章后可发布这篇文章。") }
    if let count = status.count, count > 0 {
      return String(localized: "发布前需处理：\(status.detail)。点击发布这篇文章。")
    }
    return String(localized: "\(status.value)：\(status.detail)。点击发布这篇文章。")
  }
}
