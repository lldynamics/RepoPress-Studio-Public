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
      .font(.workbenchMetadata.weight(.semibold))
      .foregroundStyle(.workbenchSecondary)

      Spacer(minLength: 0)

      Menu {
        bulkDraftOwnershipActions
      } label: {
        Label(String(localized: "管理归属"), systemImage: "arrow.triangle.branch")
      }
      .controlSize(.small)
      .help(String(localized: "批量移入当前站点或转为仅本地草稿"))

      if store.draftListContentScope == .general {
        Menu {
          generalDraftFolderMenu(for: Array(selectedDraftIDs))
        } label: {
          Label("移动到文件夹", systemImage: "folder")
        }
        .controlSize(.small)
      }

      Button {
        isMetadataBatchMaintenancePresented = true
      } label: {
        Label(String(localized: "维护标签与分类"), systemImage: "tag")
      }
      .controlSize(.small)
      .help(String(localized: "逐篇预览后批量添加、移除、重命名或合并标签和分类"))

      Button {
        isAIBatchMaintenancePresented = true
      } label: {
        Label("AI 批量维护", systemImage: "sparkles.rectangle.stack")
      }
      .controlSize(.small)
      .accessibilityIdentifier("writing-ai-batch-maintenance")

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
    .padding(.horizontal, WorkbenchSpacing.control)
    .padding(.vertical, WorkbenchSpacing.icon)
    .background(
      workbenchAccentColor.opacity(WorkbenchOpacity.accentBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  @MainActor
  func exportGeneralDraft(_ draft: ArticleDraft) {
    store.flushDraftBodyEditorBuffer(for: draft.id)
    guard let currentDraft = store.draft(for: draft.id) else {
      store.setPublishActionMessage(
        String(localized: "仅本地草稿已不存在，未执行导出。"),
        status: .warning
      )
      return
    }
    Task { @MainActor in
      do {
        let document = try GeneralDraftExportService().document(
          for: currentDraft,
          profile: store.profile(for: currentDraft)
        )
        guard let destinationURL = try await GeneralDraftExportPanel.export(document) else {
          return
        }
        store.setPublishActionMessage(
          String(
            format: String(localized: "仅本地草稿已导出：%@"),
            destinationURL.lastPathComponent
          ),
          status: .success
        )
      } catch {
        store.setPublishActionMessage(
          String(
            format: String(localized: "仅本地草稿导出失败：%@"),
            error.localizedDescription
          ),
          status: .failure
        )
      }
    }
  }

  @ViewBuilder
  func draftOwnershipActions(for draft: ArticleDraft) -> some View {
    let renderedDraft = liveDraft(for: draft) ?? draft
    let isBatch = transferDraftIDs(for: renderedDraft).count > 1

    if renderedDraft.isGeneralDraft {
      if let site = currentSiteTransferTarget {
        Button {
          guard let currentDraft = liveDraft(for: renderedDraft) else { return }
          presentDraftOwnershipTransfer(
            draftIDs: transferDraftIDs(for: currentDraft),
            operation: .moveToSite,
            targetProfileID: site.id
          )
        } label: {
          Label(
            isBatch
              ? String(localized: "批量移入当前站点")
              : String(localized: "移入当前站点"),
            systemImage: "arrow.right.doc.on.clipboard"
          )
        }
      }
    } else {
      Button {
        guard let currentDraft = liveDraft(for: renderedDraft) else { return }
        presentDraftOwnershipTransfer(
          draftIDs: transferDraftIDs(for: currentDraft),
          operation: .moveToGeneral
        )
      } label: {
        Label(
          isBatch
            ? String(localized: "批量转为仅本地草稿")
            : String(localized: "转为仅本地草稿"),
          systemImage: "tray.and.arrow.down"
        )
      }
    }

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
        Label(String(localized: "批量转为仅本地草稿"), systemImage: "tray.and.arrow.down")
      }
    } else if selectedDrafts.allSatisfy(\.isGeneralDraft), let site = currentSiteTransferTarget {
      Button {
        presentDraftOwnershipTransfer(
          draftIDs: Array(selectedDraftIDs),
          operation: .moveToSite,
          targetProfileID: site.id
        )
      } label: {
        Label(String(localized: "批量移入当前站点"), systemImage: "arrow.right.doc.on.clipboard")
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
