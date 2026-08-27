import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  var bulkSelectionBar: some View {
    HStack(spacing: 8) {
      Label {
        Text(String(localized: "已选择 \(selectedDraftIDs.count) 篇"))
      } icon: {
        Image(systemName: "checkmark.circle.fill")
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)

      Spacer(minLength: 0)

      Menu {
        bulkDraftOwnershipActions
      } label: {
        Label(String(localized: "管理归属"), systemImage: "arrow.triangle.branch")
      }
      .controlSize(.small)
      .help(String(localized: "批量移动、复制或转为通用草稿"))

      Button(String(localized: "全选筛选结果")) {
        selectedDraftIDs = Set(draftListCache.filteredDraftIDs)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .help(String(localized: "选择当前筛选结果中的全部文章；⌘A 保留给文本编辑器"))
      .accessibilityLabel(String(localized: "全选筛选结果"))
      .accessibilityHint(String(localized: "选择当前筛选结果中的全部文章，不会影响文本编辑器的 ⌘A"))

      Button(String(localized: "取消选择")) {
        if let selectedDraftID {
          selectedDraftIDs = [selectedDraftID]
        } else {
          selectedDraftIDs = []
        }
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(
      Color.accentColor.opacity(WorkbenchOpacity.accentBackground),
      in: RoundedRectangle(cornerRadius: 8))
  }

  @MainActor
  func exportGeneralDraft(_ draft: ArticleDraft) {
    store.flushDraftBodyEditorBuffer(for: draft.id)
    guard let currentDraft = store.draft(for: draft.id) else {
      store.setPublishActionMessage(
        String(localized: "通用草稿已不存在，未执行导出。"),
        status: .warning
      )
      return
    }
    do {
      let document = try GeneralDraftExportService().document(
        for: currentDraft,
        profile: store.profile(for: currentDraft)
      )
      guard let destinationURL = try GeneralDraftExportPanel.export(document) else {
        return
      }
      store.setPublishActionMessage(
        String(
          format: String(localized: "通用草稿已导出：%@"),
          destinationURL.lastPathComponent
        ),
        status: .success
      )
    } catch {
      store.setPublishActionMessage(
        String(
          format: String(localized: "通用草稿导出失败：%@"),
          error.localizedDescription
        ),
        status: .failure
      )
    }
  }

  @ViewBuilder
  func draftOwnershipActions(for draft: ArticleDraft) -> some View {
    let renderedDraft = liveDraft(for: draft) ?? draft
    let availableProfiles = availableTransferProfiles(
      for: renderedDraft,
      includeCurrentSite: false
    )

    if !renderedDraft.isGeneralDraft {
      Button {
        guard let currentDraft = liveDraft(for: renderedDraft) else { return }
        presentDraftOwnershipTransfer(
          draftIDs: transferDraftIDs(for: currentDraft),
          operation: .moveToGeneral
        )
      } label: {
        Label(
          transferDraftIDs(for: renderedDraft).count > 1
            ? String(localized: "批量转为通用草稿")
            : String(localized: "转为通用草稿"),
          systemImage: "tray.and.arrow.down"
        )
      }
    }

    Menu {
      ForEach(availableProfiles) { profile in
        Button(profile.name) {
          guard let currentDraft = liveDraft(for: renderedDraft) else { return }
          presentDraftOwnershipTransfer(
            draftIDs: transferDraftIDs(for: currentDraft),
            operation: .moveToSite,
            targetProfileID: profile.id
          )
        }
      }
    } label: {
      Label(
        transferDraftIDs(for: renderedDraft).count > 1
          ? String(localized: "批量移动到站点")
          : String(localized: "移动到站点"),
        systemImage: "arrow.right.doc.on.clipboard"
      )
    }
    .disabled(availableProfiles.isEmpty)

    Menu {
      ForEach(availableProfiles) { profile in
        Button(profile.name) {
          guard let currentDraft = liveDraft(for: renderedDraft) else { return }
          presentDraftOwnershipTransfer(
            draftIDs: transferDraftIDs(for: currentDraft),
            operation: .copyToSite,
            targetProfileID: profile.id
          )
        }
      }
    } label: {
      Label(
        transferDraftIDs(for: renderedDraft).count > 1
          ? String(localized: "批量复制到站点")
          : String(localized: "复制到站点"),
        systemImage: "doc.on.doc"
      )
    }
    .disabled(availableProfiles.isEmpty)

    if store.canUndoLatestDraftOwnershipTransfer {
      Divider()
      Button {
        _ = store.undoLatestDraftOwnershipTransfer()
      } label: {
        Label(String(localized: "撤销上次归属变更"), systemImage: "arrow.uturn.backward")
      }
    }
  }

  @ViewBuilder
  private var bulkDraftOwnershipActions: some View {
    let selectedDrafts = draftListCache.renderedDrafts(for: selectedDraftIDs)

    if selectedDrafts.allSatisfy({ !$0.isGeneralDraft }) {
      Button {
        presentDraftOwnershipTransfer(
          draftIDs: Array(selectedDraftIDs),
          operation: .moveToGeneral
        )
      } label: {
        Label(String(localized: "批量转为通用草稿"), systemImage: "tray.and.arrow.down")
      }
    }

    Menu(String(localized: "批量移动到站点")) {
      ForEach(availableTransferProfiles(for: selectedDrafts.first, includeCurrentSite: false)) {
        profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: Array(selectedDraftIDs),
            operation: .moveToSite,
            targetProfileID: profile.id
          )
        }
      }
    }

    Menu(String(localized: "批量复制到站点")) {
      ForEach(availableTransferProfiles(for: selectedDrafts.first, includeCurrentSite: false)) {
        profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: Array(selectedDraftIDs),
            operation: .copyToSite,
            targetProfileID: profile.id
          )
        }
      }
    }

    if store.canUndoLatestDraftOwnershipTransfer {
      Divider()
      Button(String(localized: "撤销上次归属变更")) {
        _ = store.undoLatestDraftOwnershipTransfer()
      }
    }
  }
}
