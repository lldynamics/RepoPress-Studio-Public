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
    do {
      let document = try GeneralDraftExportService().document(
        for: draft,
        profile: store.profile(for: draft)
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
    let draftIDs = transferDraftIDs(for: draft)

    if !draft.isGeneralDraft {
      Button {
        presentDraftOwnershipTransfer(
          draftIDs: draftIDs,
          operation: .moveToGeneral
        )
      } label: {
        Label(
          draftIDs.count > 1 ? String(localized: "批量转为通用草稿") : String(localized: "转为通用草稿"),
          systemImage: "tray.and.arrow.down"
        )
      }
    }

    Menu {
      ForEach(availableTransferProfiles(for: draft, includeCurrentSite: false)) { profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: draftIDs,
            operation: .moveToSite,
            targetProfileID: profile.id
          )
        }
      }
    } label: {
      Label(
        draftIDs.count > 1 ? String(localized: "批量移动到站点") : String(localized: "移动到站点"),
        systemImage: "arrow.right.doc.on.clipboard"
      )
    }
    .disabled(availableTransferProfiles(for: draft, includeCurrentSite: false).isEmpty)

    Menu {
      ForEach(availableTransferProfiles(for: draft, includeCurrentSite: false)) { profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: draftIDs,
            operation: .copyToSite,
            targetProfileID: profile.id
          )
        }
      }
    } label: {
      Label(
        draftIDs.count > 1 ? String(localized: "批量复制到站点") : String(localized: "复制到站点"),
        systemImage: "doc.on.doc"
      )
    }
    .disabled(availableTransferProfiles(for: draft, includeCurrentSite: false).isEmpty)

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
    let selectedDrafts = visibleDraftSnapshot.filter { selectedDraftIDs.contains($0.id) }

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
