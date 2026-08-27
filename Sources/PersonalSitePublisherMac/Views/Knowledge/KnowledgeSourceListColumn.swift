import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeSourceListColumn: View {
  @EnvironmentObject private var sceneCommandRouter: WorkspaceSceneCommandRouter
  @State private var sceneCommandOwnerID = UUID()
  let store: WorkbenchStore
  @ObservedObject var knowledge: KnowledgeStore
  @EnvironmentObject private var browserBridge: KnowledgeBrowserBridge
  @Environment(\.openSettings) var openSettings
  @AppStorage("settingsRequestedTabID") var requestedSettingsTabID = ""
  @AppStorage("dataManagementRequestedSection") var dataManagementRequestedSection = DataManagementSection.backup.rawValue
  @State var searchText = ""
  @State var isImportPresented = false
  @State var isBrowserExtensionPresented = false
  @State var folderEditorMode: FolderEditorMode = .create
  @State var folderName = ""
  @State var isFolderEditorPresented = false
  @State var folderPendingDeletion: KnowledgeFolder?
  @State var isFolderDeleteConfirmationPresented = false
  @State var documentPendingDeletion: KnowledgeDocument?
  @State var isDocumentDeleteConfirmationPresented = false
  @State var selectedDocumentIDs = Set<UUID>()
  @State var isRecycleBinPresented = false
  @State var isHealthPresented = false
  @State var isSettingsPresented = false
  @State var isBatchRecycleConfirmationPresented = false
  @State var isBatchTagEditorPresented = false
  @State var batchTags = ""
  @State var hoveredDocumentID: UUID?
  @State var listPresentation: KnowledgeSourceListPresentationSnapshot
  @FocusState var isSearchFocused: Bool

  init(store: WorkbenchStore, knowledge: KnowledgeStore) {
    self.store = store
    self.knowledge = knowledge
    _listPresentation = State(
      initialValue: KnowledgeSourceListPresentationSnapshot.make(knowledge: knowledge)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      knowledgeHeader
        .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
        .padding(.vertical, WorkspaceSidebarMetrics.headerVerticalPadding)

      knowledgeInsertionActions
        .padding(.bottom, 4)

      KnowledgeCollectionNavigationView(
        knowledge: knowledge,
        onCreateFolder: beginCreatingFolder,
        onRenameFolder: beginRenamingFolder,
        onDeleteFolder: requestFolderDeletion
      )
      .padding(.top, 4)
      .padding(.bottom, 6)
      .background(WorkbenchBackgroundStyle.card)

      knowledgeListToolbar
        .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 8)

      documentList
    }
    .sheet(isPresented: $isImportPresented) {
      KnowledgeImportAssistantView(knowledge: knowledge)
    }
    .sheet(isPresented: $isBrowserExtensionPresented) {
      BrowserExtensionConnectionView()
        .environmentObject(browserBridge)
    }
    .sheet(isPresented: $isRecycleBinPresented) {
      KnowledgeRecycleBinView(knowledge: knowledge)
    }
    .sheet(isPresented: $isHealthPresented) {
      KnowledgeLibraryHealthView(knowledge: knowledge)
    }
    .sheet(isPresented: $isSettingsPresented) {
      KnowledgeSettingsView(
        store: store,
        knowledge: knowledge,
        browserBridge: browserBridge,
        onOpenLibrary: {
          isSettingsPresented = false
        }
      )
      .workbenchSheetSize(.detail)
    }
    .alert(folderEditorTitle, isPresented: $isFolderEditorPresented) {
      TextField(String(localized: "文件夹名称"), text: $folderName)
        .accessibilityLabel("文件夹名称")
      Button(folderEditorActionTitle) {
        commitFolderEditor()
      }
      .disabled(folderName.trimmedForPublishing.isEmpty)
      Button("取消", role: .cancel) {}
    } message: {
      Text("文件夹仅用于整理本机资料，不会改变原始文件。")
    }
    .confirmationDialog(
      String(localized: "删除资料文件夹？"),
      isPresented: $isFolderDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      if let folderPendingDeletion {
        Button(
          String(
            format: String(localized: "删除“%@”"),
            folderPendingDeletion.name
          ),
          role: .destructive
        ) {
          knowledge.deleteFolder(id: folderPendingDeletion.id)
          self.folderPendingDeletion = nil
        }
      }
      Button("取消", role: .cancel) {
        folderPendingDeletion = nil
      }
    } message: {
      Text("文件夹中的资料不会被删除，而是移到“未分类”。")
    }
    .confirmationDialog(
      documentDeletionConfirmationTitle,
      isPresented: $isDocumentDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("移到回收站", role: .destructive) {
        confirmDocumentDeletion()
      }
      Button("取消", role: .cancel) {
        documentPendingDeletion = nil
      }
    } message: {
      Text("资料会移到回收站并停止参与搜索与 AI 检索；本地副本会保留，之后可以恢复。")
    }
    .alert("批量添加标签", isPresented: $isBatchTagEditorPresented) {
      TextField("标签，用逗号分隔", text: $batchTags)
        .accessibilityLabel("批量标签")
      Button("添加") { confirmBatchTags() }
        .disabled(parsedBatchTags.isEmpty)
      Button("取消", role: .cancel) { batchTags = "" }
    } message: {
      Text("新标签会追加到所选资料，已有标签不会被删除。")
    }
    .confirmationDialog(
      "将所选资料移到回收站？",
      isPresented: $isBatchRecycleConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("移到回收站", role: .destructive) {
        confirmBatchRecycle()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("共 \(selectedDocumentIDs.count) 条资料。移入后可以从回收站恢复。")
    }
    .onAppear {
      refreshListPresentationSnapshot()
      synchronizeListSelection()
    }
    .onChange(of: knowledge.selectedDocumentID) { _, _ in
      synchronizeListSelection()
    }
    .onChange(of: knowledge.folderScope) { _, _ in
      retainVisibleBatchSelection()
    }
    .onChange(of: knowledge.listPresentationRevision) { _, _ in
      refreshListPresentationSnapshot()
      retainVisibleBatchSelection()
    }
    .onChange(of: knowledge.isSearching) { wasSearching, isSearching in
      guard wasSearching, !isSearching,
            !searchText.trimmedForPublishing.isEmpty else { return }
      refreshListPresentationSnapshot()
      let documentCount = Set(listPresentation.searchResults.map { $0.document.id }).count
      EditorAccessibilityAnnouncementCenter.announce(
        listPresentation.searchResults.isEmpty
          ? "搜索完成，没有匹配资料。"
          : "搜索完成，共 \(documentCount) 条资料、\(listPresentation.searchResults.count) 个命中片段。",
        priority: .medium
      )
    }
    .onExitCommand(perform: exitBatchSelection)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("knowledge-source-list")
    .onAppear {
      sceneCommandRouter.registerKnowledgeLibrary(
        commandActions,
        owner: sceneCommandOwnerID
      )
    }
    .onDisappear {
      sceneCommandRouter.unregisterKnowledgeLibrary(owner: sceneCommandOwnerID)
    }
  }
}
