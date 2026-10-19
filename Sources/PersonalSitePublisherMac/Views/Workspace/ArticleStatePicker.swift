import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

struct ArticleStatePicker: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  @State private var transferPlan: DraftOwnershipTransferPlan?

  private var stateBinding: Binding<ArticleState> {
    Binding(
      get: { draft.articleState },
      set: { state in
        store.setArticleState(state, for: draft.id)
      }
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("状态")
          .font(.workbenchMetadata)
          .foregroundStyle(.workbenchSecondary)
        Spacer()
        Picker("状态", selection: stateBinding) {
          ForEach(Self.availableStates(for: draft)) { state in
            Label(
              state.workbenchLocalizedDisplayName,
              systemImage: state == .published && draft.isPrivate ? "lock.fill" : state.systemImage
            )
            .tag(state)
            .disabled(state != .draft && state != .ready)
          }
        }
        .labelsHidden()
        .accessibilityLabel("文章状态")
        .accessibilityValue(draft.articleState.workbenchLocalizedDisplayName)
        .accessibilityIdentifier("article-state-picker")
      }

      Text(stateDescription)
        .font(.workbenchMetadata)
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)

      if draft.isGeneralDraft {
        Button("移入当前站点…") {
          transferPlan = store.draftOwnershipTransferPlan(
            draftIDs: [draft.id], operation: .moveToSite, targetProfileID: store.activeProfile.id)
        }
        .buttonStyle(.link)
        .font(.workbenchMetadata)
        .disabled(store.activeProfile.purpose == .generalDraftBackup)
        .accessibilityIdentifier("article-move-to-current-site")
      } else {
        Button("移到仅本地草稿…") {
          transferPlan = store.draftOwnershipTransferPlan(
            draftIDs: [draft.id], operation: .moveToGeneral)
        }
        .buttonStyle(.link)
        .font(.workbenchMetadata)
        .accessibilityIdentifier("article-move-to-general-drafts")
      }

      if store.canUndoLatestDraftOwnershipTransfer {
        Button("撤销上次归属变更") {
          _ = store.undoLatestDraftOwnershipTransfer()
        }
        .buttonStyle(.link)
        .font(.workbenchMetadata)
      }
    }
    .sheet(item: $transferPlan) { plan in
      DraftOwnershipTransferConfirmationView(plan: plan) { confirmedPlan in
        store.applyDraftOwnershipTransfer(confirmedPlan) != nil
      }
    }
    .onChange(of: draft.id) { _, _ in transferPlan = nil }
  }

  /// Site articles can switch between 草稿 and 待发布. 已发布 is included
  /// only when backed by the current article's publication state.
  static func availableStates(for draft: ArticleDraft) -> [ArticleState] {
    if draft.isGeneralDraft { return [.localOnly] }
    return draft.articleState == .published ? [.draft, .ready, .published] : [.draft, .ready]
  }

  private var stateDescription: String {
    switch draft.articleState {
    case .draft:
      return String(localized: "继续写作；正式发布时会自动取消草稿标记。更改状态不会撤回线上版本。")
    case .ready:
      return String(localized: "已取消草稿标记，尚未发布；可改回草稿。")
    case .published:
      return String(localized: "发布结果或导入记录产生此状态，不能手动设为已发布。")
    case .localOnly:
      return String(localized: "不绑定站点；移入站点后从草稿开始。原站点文件和线上版本不会被撤回。")
    }
  }
}
