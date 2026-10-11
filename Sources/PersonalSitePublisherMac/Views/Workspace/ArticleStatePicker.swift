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
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Picker("状态", selection: stateBinding) {
          ForEach(Self.availableStates(for: draft)) { state in
            Label(
              state.workbenchLocalizedDisplayName,
              systemImage: state == .published && draft.isPrivate ? "lock.fill" : state.systemImage
            )
            .tag(state)
            .disabled(state == .published || state == .localOnly)
          }
        }
        .labelsHidden()
        .accessibilityLabel("文章状态")
        .accessibilityValue(draft.articleState.workbenchLocalizedDisplayName)
        .accessibilityIdentifier("article-state-picker")
      }

      Text(stateDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if draft.isGeneralDraft {
        Menu("移入站点…") {
          ForEach(store.profiles.filter { $0.purpose != .generalDraftBackup }) { profile in
            Button(profile.name) {
              transferPlan = store.draftOwnershipTransferPlan(
                draftIDs: [draft.id], operation: .moveToSite, targetProfileID: profile.id)
            }
          }
        }
        .disabled(store.profiles.allSatisfy { $0.purpose == .generalDraftBackup })
      } else {
        Button("移到通用草稿…") {
          transferPlan = store.draftOwnershipTransferPlan(
            draftIDs: [draft.id], operation: .moveToGeneral)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .accessibilityIdentifier("article-move-to-general-drafts")
      }

      if store.canUndoLatestDraftOwnershipTransfer {
        Button("撤销上次归属变更") {
          _ = store.undoLatestDraftOwnershipTransfer()
        }
        .buttonStyle(.borderless)
        .font(.caption)
      }
    }
    .sheet(item: $transferPlan) { plan in
      DraftOwnershipTransferConfirmationView(plan: plan) { confirmedPlan in
        store.applyDraftOwnershipTransfer(confirmedPlan) != nil
      }
    }
    .onChange(of: draft.id) { _, _ in transferPlan = nil }
  }

  static func availableStates(for draft: ArticleDraft) -> [ArticleState] {
    draft.isGeneralDraft ? [.localOnly] : [.draft, .ready, .published]
  }

  private var stateDescription: String {
    switch draft.articleState {
    case .draft:
      return String(localized: "继续写作；完成后改为待发布。更改状态不会撤回线上版本。")
    case .ready:
      return String(localized: "可进入发布检查；此选项不会自动发布。")
    case .published:
      return String(localized: "发布结果或导入记录产生此状态，不能手动设为已发布。")
    case .localOnly:
      return String(localized: "不绑定站点；移入站点后可设为草稿或待发布。原站点文件和线上版本不会被撤回。")
    }
  }
}
