import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  var generalDraftFolderNames: [String] {
    Set(
      store.writingDrafts.compactMap { draft -> String? in
        guard draft.isGeneralDraft,
          !store.privateContentDisplay(for: draft).isMasked
        else { return nil }
        return draft.generalDraftFolderName
      }
    ).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  @ViewBuilder
  func generalDraftFolderActions(for draft: ArticleDraft) -> some View {
    Menu {
      generalDraftFolderMenu(for: transferDraftIDs(for: draft))
    } label: {
      Label("移动到文件夹", systemImage: "folder")
    }
    .disabled(store.privateContentDisplay(for: draft).isMasked)
  }

  @ViewBuilder
  func generalDraftFolderMenu(for draftIDs: [UUID]) -> some View {
    Button {
      beginCreatingGeneralFolder(for: draftIDs)
    } label: {
      Label("新建文件夹…", systemImage: "folder.badge.plus")
    }

    if !generalDraftFolderNames.isEmpty {
      Divider()
      ForEach(generalDraftFolderNames, id: \.self) { name in
        Button(name) {
          _ = store.moveGeneralDrafts(draftIDs, toFolder: name)
        }
      }
    }

    Divider()
    Button("移出文件夹") {
      _ = store.moveGeneralDrafts(draftIDs, toFolder: nil)
    }
  }

  func beginCreatingGeneralFolder(for draftIDs: [UUID]) {
    guard !draftIDs.isEmpty else { return }
    generalFolderRenameSource = nil
    generalFolderDraftIDs = draftIDs
    generalFolderNameInput = ""
    isGeneralFolderNamePresented = true
  }

  func beginRenamingGeneralFolder(_ name: String) {
    generalFolderRenameSource = name
    generalFolderDraftIDs = []
    generalFolderNameInput = name
    isGeneralFolderNamePresented = true
  }

  func commitGeneralFolderName() {
    guard let name = ArticleDraft.validGeneralDraftFolderName(generalFolderNameInput) else {
      return
    }
    let draftIDs: [UUID]
    if let source = generalFolderRenameSource {
      draftIDs = store.writingDrafts.compactMap { draft in
        draft.isGeneralDraft && draft.generalDraftFolderName == source ? draft.id : nil
      }
    } else {
      draftIDs = generalFolderDraftIDs
    }
    _ = store.moveGeneralDrafts(draftIDs, toFolder: name)
    generalFolderRenameSource = nil
    generalFolderDraftIDs = []
  }

  func moveGeneralFolderContentsToUnfiled(_ name: String) {
    let draftIDs = store.writingDrafts.compactMap { draft in
      draft.isGeneralDraft && draft.generalDraftFolderName == name ? draft.id : nil
    }
    _ = store.moveGeneralDrafts(draftIDs, toFolder: nil)
  }
}
