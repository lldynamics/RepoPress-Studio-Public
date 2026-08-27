import PublishingWorkbenchCore
import SwiftUI

extension KnowledgeSourceListColumn {
  func documentFolderMenu(_ document: KnowledgeDocument) -> some View {
    Menu(String(localized: "移动到文件夹")) {
      Button {
        knowledge.moveDocument(document.id, to: nil)
      } label: {
        Label(
          String(localized: "未分类"), systemImage: document.folderID == nil ? "checkmark" : "tray")
      }
      if !knowledge.folders.isEmpty {
        Divider()
        ForEach(knowledge.folders) { folder in
          Button {
            knowledge.moveDocument(document.id, to: folder.id)
          } label: {
            Label(folder.name, systemImage: document.folderID == folder.id ? "checkmark" : "folder")
          }
        }
      }
    }
  }

  var selectedFolderTitle: String {
    switch knowledge.folderScope {
    case .all:
      String(localized: "全部资料")
    case .unfiled:
      String(localized: "未分类")
    case .folder(let folderID):
      knowledge.folder(id: folderID)?.name ?? String(localized: "资料文件夹")
    case .smartCollection(let rule):
      rule.localizedDisplayName
    case .savedCollection(let collection):
      collection.name
    }
  }

  @ViewBuilder
  var emptyFolderState: some View {
    let showsImportAction = !knowledge.documents.isEmpty
    switch knowledge.folderScope {
    case .all:
      EmptyStateView(
        title: "还没有资料",
        message: "导入资料，或从其他文件夹移动到这里。",
        systemImage: "books.vertical",
        density: .inline,
        actionTitle: showsImportAction ? "导入资料" : nil,
        actionSystemImage: "plus",
        action: showsImportAction ? { isImportPresented = true } : nil
      )
    case .unfiled:
      EmptyStateView(
        title: "没有未分类资料",
        message: "导入资料，或从其他文件夹移动到这里。",
        systemImage: "tray",
        density: .inline,
        actionTitle: showsImportAction ? "导入资料" : nil,
        actionSystemImage: "plus",
        action: showsImportAction ? { isImportPresented = true } : nil
      )
    case .folder:
      EmptyStateView(
        title: "此文件夹还没有资料",
        message: "导入资料，或从其他文件夹移动到这里。",
        systemImage: "folder",
        density: .inline,
        actionTitle: showsImportAction ? "导入资料" : nil,
        actionSystemImage: "plus",
        action: showsImportAction ? { isImportPresented = true } : nil
      )
    case .smartCollection, .savedCollection:
      EmptyStateView(
        title: "没有符合条件的资料",
        message: "智能集合会在资料元数据变化后自动更新。",
        systemImage: "wand.and.stars",
        density: .inline,
        actionTitle: "查看全部资料",
        actionSystemImage: "books.vertical",
        action: { knowledge.setFolderScope(.all) }
      )
    }
  }

  var sortFieldBinding: Binding<KnowledgeDocumentSortField> {
    Binding(
      get: { knowledge.documentSort.field },
      set: { knowledge.setDocumentSortField($0) }
    )
  }

  var sortDirectionBinding: Binding<KnowledgeSortDirection> {
    Binding(
      get: { knowledge.documentSort.direction },
      set: { knowledge.setDocumentSortDirection($0) }
    )
  }

  var searchScopeBinding: Binding<KnowledgeSearchScope> {
    Binding(
      get: { knowledge.searchFilter.scope },
      set: { knowledge.setSearchScope($0) }
    )
  }

  var searchSignalBinding: Binding<KnowledgeSearchSignalFilter> {
    Binding(
      get: { knowledge.searchFilter.signal },
      set: { knowledge.setSearchSignalFilter($0) }
    )
  }

  var searchSortBinding: Binding<KnowledgeSearchResultSort> {
    Binding(
      get: { knowledge.searchFilter.sort },
      set: { knowledge.setSearchResultSort($0) }
    )
  }

  var folderEditorTitle: String {
    switch folderEditorMode {
    case .create: String(localized: "新建资料文件夹")
    case .rename: String(localized: "重命名资料文件夹")
    }
  }

  var folderEditorActionTitle: String {
    switch folderEditorMode {
    case .create: String(localized: "创建")
    case .rename: String(localized: "保存")
    }
  }

  func beginCreatingFolder() {
    folderEditorMode = .create
    folderName = ""
    isFolderEditorPresented = true
  }

  func beginRenamingFolder(_ folder: KnowledgeFolder) {
    folderEditorMode = .rename(folder.id)
    folderName = folder.name
    isFolderEditorPresented = true
  }

  func requestFolderDeletion(_ folder: KnowledgeFolder) {
    folderPendingDeletion = folder
    isFolderDeleteConfirmationPresented = true
  }

  func commitFolderEditor() {
    switch folderEditorMode {
    case .create:
      knowledge.createFolder(name: folderName)
    case .rename(let folderID):
      knowledge.renameFolder(id: folderID, name: folderName)
    }
  }

  func openDataManagement() {
    dataManagementRequestedSection = DataManagementSection.backup.rawValue
    requestedSettingsTabID = SettingsTab.dataManagement.id
    openSettings()
  }

  var commandActions: KnowledgeLibraryCommandActions {
    KnowledgeLibraryCommandActions(
      focusSearch: {
        isSearchFocused = true
      },
      importSources: {
        isImportPresented = true
      },
      selectPreviousDocument: {
        selectRelativeDocument(offset: -1)
      },
      selectNextDocument: {
        selectRelativeDocument(offset: 1)
      }
    )
  }

  private func selectRelativeDocument(offset: Int) {
    if !searchText.trimmedForPublishing.isEmpty {
      selectRelativeSearchResult(offset: offset)
      return
    }
    let documents = listPresentation.documentRows.map(\.document)
    guard !documents.isEmpty else {
      EditorAccessibilityAnnouncementCenter.announce("资料列表为空。", priority: .low)
      return
    }
    let currentIndex = knowledge.selectedDocumentID.flatMap { selectedID in
      documents.firstIndex { $0.id == selectedID }
    }
    let baseIndex = currentIndex ?? (offset > 0 ? -1 : documents.count)
    let nextIndex = min(max(baseIndex + offset, 0), documents.count - 1)
    let document = documents[nextIndex]
    knowledge.selectDocument(document.id)
    EditorAccessibilityAnnouncementCenter.announce(
      "已选择资料：\(document.title)。第 \(nextIndex + 1) 条，共 \(documents.count) 条。",
      priority: .low
    )
  }

  private func selectRelativeSearchResult(offset: Int) {
    let results = listPresentation.searchResults
    guard !results.isEmpty else {
      EditorAccessibilityAnnouncementCenter.announce("没有搜索命中片段。", priority: .low)
      return
    }
    let currentIndex = knowledge.selectedSearchResult.flatMap { selected in
      results.firstIndex { $0.id == selected.id }
    }
    let baseIndex = currentIndex ?? (offset > 0 ? -1 : results.count)
    let nextIndex = min(max(baseIndex + offset, 0), results.count - 1)
    let result = results[nextIndex]
    knowledge.selectSearchResult(result)
    let hit = KnowledgeSearchPresentationService().presentation(
      for: result,
      query: knowledge.searchText
    )
    let reasons = hit.reasons.map { reason in
      switch reason {
      case .title: "标题命中"
      case .fullText: "全文命中"
      case .semantic: "语义命中"
      }
    }.joined(separator: "、")
    EditorAccessibilityAnnouncementCenter.announce(
      "\(result.document.title)，\(reasons)。第 \(nextIndex + 1) 个片段，共 \(results.count) 个。",
      priority: .low
    )
  }

  func refreshListPresentationSnapshot() {
    guard listPresentation.revision != knowledge.listPresentationRevision else { return }
    listPresentation = KnowledgeSourceListPresentationSnapshot.make(knowledge: knowledge)
  }
}
