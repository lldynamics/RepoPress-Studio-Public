import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeSourceListColumn: View {
  @ObservedObject var knowledge: KnowledgeStore
  @EnvironmentObject private var browserBridge: KnowledgeBrowserBridge
  @State private var searchText = ""
  @State private var isImportPresented = false
  @State private var isBrowserExtensionPresented = false
  @State private var folderEditorMode: FolderEditorMode = .create
  @State private var folderName = ""
  @State private var isFolderEditorPresented = false
  @State private var folderPendingDeletion: KnowledgeFolder?
  @State private var isFolderDeleteConfirmationPresented = false
  @State private var documentPendingDeletion: KnowledgeDocument?
  @State private var isDocumentDeleteConfirmationPresented = false
  @State private var restorePreview: KnowledgeLibraryBackupPreview?
  @State private var selectedDocumentIDs = Set<UUID>()
  @State private var isRecycleBinPresented = false
  @State private var isHealthPresented = false
  @State private var isBatchRecycleConfirmationPresented = false
  @State private var isBatchTagEditorPresented = false
  @State private var batchTags = ""
  @State private var hoveredDocumentID: UUID?
  @AppStorage("knowledgeSidebarDensityV1") private var sidebarDensity: KnowledgeSidebarDensity = .comfortable
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      knowledgeHeader
        .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
        .padding(.vertical, WorkspaceSidebarMetrics.headerVerticalPadding)

      Divider()

      KnowledgeCollectionNavigationView(
        knowledge: knowledge,
        onCreateFolder: beginCreatingFolder,
        onRenameFolder: beginRenamingFolder,
        onDeleteFolder: requestFolderDeletion
      )

      Divider()

      knowledgeListToolbar
        .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
        .padding(.vertical, WorkspaceSidebarMetrics.toolbarVerticalPadding)

      Divider()

      documentList
    }
    .sheet(isPresented: $isImportPresented) {
      KnowledgeImportAssistantView(knowledge: knowledge)
    }
    .sheet(isPresented: $isBrowserExtensionPresented) {
      BrowserExtensionConnectionView()
        .environmentObject(browserBridge)
    }
    .sheet(item: $restorePreview) { preview in
      KnowledgeLibraryRestorePreviewView(knowledge: knowledge, preview: preview)
    }
    .sheet(isPresented: $isRecycleBinPresented) {
      KnowledgeRecycleBinView(knowledge: knowledge)
    }
    .sheet(isPresented: $isHealthPresented) {
      KnowledgeLibraryHealthView(knowledge: knowledge)
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
    .onAppear(perform: synchronizeListSelection)
    .onChange(of: knowledge.selectedDocumentID) { _, _ in
      synchronizeListSelection()
    }
    .onChange(of: knowledge.folderScope) { _, _ in
      retainVisibleBatchSelection()
    }
    .onChange(of: knowledge.documents.map(\.id)) { _, _ in
      retainVisibleBatchSelection()
    }
    .onChange(of: knowledge.isSearching) { wasSearching, isSearching in
      guard wasSearching, !isSearching,
            !searchText.trimmedForPublishing.isEmpty else { return }
      let documentCount = Set(knowledge.visibleSearchResults.map { $0.document.id }).count
      EditorAccessibilityAnnouncementCenter.announce(
        knowledge.visibleSearchResults.isEmpty
          ? "搜索完成，没有匹配资料。"
          : "搜索完成，共 \(documentCount) 条资料、\(knowledge.visibleSearchResults.count) 个命中片段。",
        priority: .medium
      )
    }
    .onExitCommand(perform: exitBatchSelection)
    .accessibilityIdentifier("knowledge-source-list")
    .focusedSceneValue(\.knowledgeLibraryCommandActions, commandActions)
  }

  private var knowledgeHeader: some View {
    WorkspaceContextListHeader(title: "资料") {
      if searchText.trimmedForPublishing.isEmpty {
        Text("\(knowledge.visibleDocuments.count) 条")
      } else {
        Text("\(searchResultGroups.count) 篇 · \(knowledge.visibleSearchResults.count) 片段")
          .monospacedDigit()
      }
    } actions: {
      Menu {
        Button {
          isBrowserExtensionPresented = true
        } label: {
          Label("连接浏览器插件", systemImage: "puzzlepiece.extension")
        }
        Divider()
        Button {
          isHealthPresented = true
        } label: {
          Label("资料库健康…", systemImage: "checkmark.shield")
        }
        Divider()
        Button {
          isRecycleBinPresented = true
        } label: {
          Label("回收站（\(knowledge.recycledDocuments.count)）", systemImage: "trash")
        }
        Divider()
        Button {
          createKnowledgeBackup()
        } label: {
          Label("完整备份…", systemImage: "externaldrive.badge.plus")
        }
        Button {
          chooseKnowledgeBackupForRestore()
        } label: {
          Label("从备份恢复…", systemImage: "arrow.counterclockwise")
        }
        Divider()
        Picker("列表密度", selection: $sidebarDensity) {
          ForEach(KnowledgeSidebarDensity.allCases) { density in
            Text(density.localizedTitle).tag(density)
          }
        }
      } label: {
        Label("管理", systemImage: "ellipsis.circle")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .controlSize(.regular)
      .fixedSize()
      .help("回收站、备份与恢复")
      .accessibilityLabel("资料库管理")
      .disabled(knowledge.isBusy)
      Button {
        isImportPresented = true
      } label: {
        Label("导入", systemImage: "plus")
      }
      .workbenchProminentActionStyle()
      .controlSize(.regular)
      .help("导入资料")
      .accessibilityLabel("导入资料")
    }
  }

  private var knowledgeListToolbar: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.footnote)

        TextField(String(localized: "搜索资料全文"), text: $searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
          .onChange(of: searchText) { _, value in
            knowledge.updateSearchText(value)
          }
          .accessibilityLabel("搜索资料全文")

        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("清除搜索")
          .accessibilityLabel("清除资料搜索")
        }

        if searchText.trimmedForPublishing.isEmpty {
          sortMenu
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )

      if searchText.trimmedForPublishing.isEmpty {
        savedCollectionRuleBar
      } else {
        searchFilterControls
      }
    }
  }

  private var searchFilterControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Menu {
          Picker("搜索范围", selection: searchScopeBinding) {
            ForEach(KnowledgeSearchScope.allCases) { scope in
              Text(scope.localizedDisplayName).tag(scope)
            }
          }
        } label: {
          Label(searchScopeTitle, systemImage: "scope")
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)

        Menu {
          Picker("命中类型", selection: searchSignalBinding) {
            ForEach(KnowledgeSearchSignalFilter.allCases) { signal in
              Text(signal.localizedDisplayName).tag(signal)
            }
          }
        } label: {
          Label(
            knowledge.searchFilter.signal.localizedDisplayName,
            systemImage: "line.3.horizontal.decrease.circle"
          )
          .lineLimit(1)
        }
        .menuStyle(.borderlessButton)

        Spacer(minLength: 0)

        Menu {
          Picker("搜索排序", selection: searchSortBinding) {
            ForEach(KnowledgeSearchResultSort.allCases) { sort in
              Text(sort.localizedDisplayName).tag(sort)
            }
          }
        } label: {
          Image(
            systemName: knowledge.searchFilter.sort == .relevance
              ? "arrow.down.to.line.compact"
              : "calendar"
          )
        }
        .menuStyle(.borderlessButton)
        .help("搜索结果排序：\(knowledge.searchFilter.sort.localizedDisplayName)")
        .accessibilityLabel("搜索结果排序")
        .accessibilityValue(knowledge.searchFilter.sort.localizedDisplayName)
      }

      if hasActiveSearchFilter {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 5) {
            if knowledge.searchFilter.scope == .currentCollection,
               knowledge.folderScope != .all {
              filterChip(selectedFolderTitle) {
                knowledge.setFolderScope(.all)
              }
            }
            if knowledge.searchFilter.scope == .allLibrary {
              filterChip("全部资料库") { knowledge.setSearchScope(.currentCollection) }
            }
            if knowledge.searchFilter.signal != .all {
              filterChip(knowledge.searchFilter.signal.localizedDisplayName) {
                knowledge.setSearchSignalFilter(.all)
              }
            }
            if knowledge.searchFilter.sort != .relevance {
              filterChip(knowledge.searchFilter.sort.localizedDisplayName) {
                knowledge.setSearchResultSort(.relevance)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var savedCollectionRuleBar: some View {
    if case .savedCollection(let collection) = knowledge.folderScope,
       !collection.rules.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 5) {
          ForEach(collection.rules, id: \.id) { rule in
            Text(rule.localizedDisplayName)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(WorkbenchBackgroundStyle.subtle, in: Capsule())
          }
        }
      }
      .accessibilityLabel("组合智能集合规则")
    }
  }

  private func filterChip(_ title: String, onRemove: @escaping () -> Void) -> some View {
    HStack(spacing: 4) {
      Text(title)
        .lineLimit(1)
      Button(action: onRemove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("移除筛选：\(title)")
    }
    .font(.caption2.weight(.medium))
    .padding(.leading, 7)
    .padding(.trailing, 5)
    .padding(.vertical, 3)
    .foregroundStyle(.tint)
    .background(Color.accentColor.opacity(0.1), in: Capsule())
  }

  private var hasActiveSearchFilter: Bool {
    (knowledge.searchFilter.scope == .currentCollection && knowledge.folderScope != .all)
      || knowledge.searchFilter.scope != .currentCollection
      || knowledge.searchFilter.signal != .all
      || knowledge.searchFilter.sort != .relevance
  }

  private var searchScopeTitle: String {
    if knowledge.searchFilter.scope == .currentCollection,
       knowledge.folderScope != .all {
      return selectedFolderTitle
    }
    return knowledge.searchFilter.scope.localizedDisplayName
  }

  private var sortMenu: some View {
    Menu {
      Picker(String(localized: "排序依据"), selection: sortFieldBinding) {
        ForEach(KnowledgeDocumentSortField.allCases) { field in
          Text(field.localizedDisplayNameKey).tag(field)
        }
      }
      Divider()
      Picker(String(localized: "顺序"), selection: sortDirectionBinding) {
        ForEach(KnowledgeSortDirection.allCases) { direction in
          Label(direction.localizedDisplayName, systemImage: direction.systemImage)
            .tag(direction)
        }
      }
    } label: {
      Image(systemName: "arrow.up.arrow.down")
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(
      Text(
        String(
          format: String(localized: "排序：%@ · %@"),
          knowledge.documentSort.field.localizedDisplayName,
          knowledge.documentSort.direction.localizedDisplayName
        )
      )
    )
    .accessibilityLabel("资料排序")
  }

  @ViewBuilder
  private var documentList: some View {
    if !searchText.trimmedForPublishing.isEmpty {
      searchResultList
    } else if knowledge.visibleDocuments.isEmpty {
      emptyFolderState
      .padding(12)
      .frame(maxHeight: .infinity, alignment: .top)
    } else {
      VStack(spacing: 0) {
        if selectedDocumentIDs.count > 1 {
          batchActionBar
          Divider()
        }
        List(selection: $selectedDocumentIDs) {
          ForEach(knowledge.visibleDocuments) { document in
            documentRow(document)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onChange(of: selectedDocumentIDs) { previous, current in
          handleListSelectionChange(previous: previous, current: current)
        }
        .onDeleteCommand(perform: requestSelectedDocumentDeletion)
      }
    }
  }

  private func documentRow(_ document: KnowledgeDocument) -> some View {
    HStack(spacing: 9) {
      Image(systemName: document.kind.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: sidebarDensity.rowTextSpacing) {
        Text(document.title)
          .font(.callout.weight(.medium))
          .workbenchTruncatedIdentity(document.title)
        Text(documentSubtitle(document))
          .font(.caption)
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(documentSubtitle(document))
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(document.title)，\(documentSubtitle(document))")

      Spacer(minLength: 4)

      if knowledge.isPinned(document.id) {
        Image(systemName: "pin.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("已固定到 AI")
      } else if !document.allowsAIUse {
        Image(systemName: "sparkles.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("不允许 AI 使用")
      }

      if hoveredDocumentID == document.id || selectedDocumentIDs.contains(document.id) {
        documentActionsMenu(document)
      }
    }
    .onHover { isHovered in
      if isHovered {
        hoveredDocumentID = document.id
      } else if hoveredDocumentID == document.id {
        hoveredDocumentID = nil
      }
    }
    .listRowInsets(sidebarDensity.listRowInsets)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .tag(document.id)
    .contextMenu {
      documentActionItems(document)
    }
  }

  private func documentActionsMenu(_ document: KnowledgeDocument) -> some View {
    Menu {
      documentActionItems(document)
    } label: {
      Image(systemName: "ellipsis.circle")
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .help("资料操作")
    .accessibilityLabel("\(document.title)的资料操作")
  }

  @ViewBuilder
  private func documentActionItems(_ document: KnowledgeDocument) -> some View {
    documentFolderMenu(document)
    Divider()
    Button(
      knowledge.isPinned(document.id)
        ? String(localized: "取消固定")
        : String(localized: "固定到 AI 对话")
    ) {
      knowledge.setPinned(!knowledge.isPinned(document.id), documentID: document.id)
    }
    Button(
      document.allowsAIUse
        ? String(localized: "不允许 AI 使用")
        : String(localized: "允许 AI 使用")
    ) {
      knowledge.setAllowsAIUse(!document.allowsAIUse, documentID: document.id)
    }
    Divider()
    Button("移到回收站…", role: .destructive) {
      requestDocumentDeletion(document)
    }
    .disabled(knowledge.isBusy)
  }

  private func requestSelectedDocumentDeletion() {
    guard !selectedDocumentIDs.isEmpty else { return }
    if selectedDocumentIDs.count > 1 {
      isBatchRecycleConfirmationPresented = true
    } else if let documentID = selectedDocumentIDs.first,
              let document = knowledge.documents.first(where: { $0.id == documentID }) {
      requestDocumentDeletion(document)
    }
  }

  @ViewBuilder
  private var searchResultList: some View {
    if knowledge.isSearching {
      VStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("正在执行全文与本地语义检索…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, 28)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("正在搜索资料全文和本地语义索引")
    } else if knowledge.visibleSearchResults.isEmpty {
      EmptyStateView(
        title: "没有匹配资料",
        message: "尝试更短的关键词或换一种说法。",
        systemImage: "magnifyingglass",
        density: .inline,
        actionTitle: "清除搜索",
        actionSystemImage: "xmark.circle",
        action: {
          searchText = ""
          knowledge.updateSearchText("")
        }
      )
      .padding(12)
      .frame(maxHeight: .infinity, alignment: .top)
    } else {
      List(selection: searchResultSelection) {
        ForEach(searchResultGroups) { group in
          Section {
            ForEach(group.results) { result in
              KnowledgeSearchResultRow(
                result: result,
                query: knowledge.searchText,
                showsDocumentTitle: false
              )
              .listRowInsets(sidebarDensity.listRowInsets)
              .listRowSeparator(.hidden)
              .tag(result.id)
              .contextMenu {
                documentFolderMenu(result.document)
                Divider()
                Button(
                  knowledge.isPinned(result.document.id)
                    ? String(localized: "取消固定")
                    : String(localized: "固定到 AI 对话")
                ) {
                  knowledge.setPinned(
                    !knowledge.isPinned(result.document.id),
                    documentID: result.document.id
                  )
                }
                Divider()
                Button("移到回收站…", role: .destructive) {
                  requestDocumentDeletion(result.document)
                }
                .disabled(knowledge.isBusy)
              }
            }
          } header: {
            HStack(spacing: 6) {
              Image(systemName: group.document.kind.systemImage)
                .accessibilityHidden(true)
              Text(group.document.title)
                .lineLimit(1)
              Spacer(minLength: 2)
              Text("\(group.results.count) 个片段")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(group.document.title)，\(group.results.count) 个命中片段")
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .accessibilityLabel("资料搜索命中片段")
      .accessibilityValue("共 \(knowledge.visibleSearchResults.count) 个片段")
    }
  }

  private var searchResultSelection: Binding<UUID?> {
    Binding(
      get: { knowledge.selectedSearchResult?.id },
      set: { resultID in
        guard let resultID,
              let result = knowledge.searchResult(id: resultID) else { return }
        knowledge.selectSearchResult(result)
        let location = result.chunk.locator?.nilIfEmpty
          ?? result.chunk.headingPath?.nilIfEmpty
          ?? "正文段落"
        EditorAccessibilityAnnouncementCenter.announce(
          "已选择\(result.document.title)的\(location)，将跳转并高亮命中段落。",
          priority: .low
        )
      }
    )
  }

  private func documentSubtitle(_ document: KnowledgeDocument) -> String {
    let size = ByteCountFormatter.string(
      fromByteCount: document.sourceByteCount,
      countStyle: .file
    )
    let date = knowledge.documentSort.field == .updatedAt
      ? document.updatedAt
      : document.importedAt
    let relativeDate = date.formatted(
      .relative(presentation: .named, unitsStyle: .abbreviated)
    )
    if knowledge.documentSort.field == .fileSize {
      return "\(size) · \(document.kind.localizedDisplayName) · \(relativeDate)"
    }
    return "\(document.kind.localizedDisplayName) · \(relativeDate) · \(size)"
  }

  private var searchResultGroups: [KnowledgeSearchDocumentGroup] {
    var groups: [KnowledgeSearchDocumentGroup] = []
    var indices: [UUID: Int] = [:]
    for result in knowledge.visibleSearchResults {
      if let index = indices[result.document.id] {
        groups[index].results.append(result)
      } else {
        indices[result.document.id] = groups.count
        groups.append(KnowledgeSearchDocumentGroup(document: result.document, results: [result]))
      }
    }
    return groups
  }

  private var documentDeletionConfirmationTitle: String {
    guard let documentPendingDeletion else { return String(localized: "移到回收站？") }
    return String(
      format: String(localized: "将“%@”移到回收站？"),
      documentPendingDeletion.title
    )
  }

  private func requestDocumentDeletion(_ document: KnowledgeDocument) {
    documentPendingDeletion = document
    isDocumentDeleteConfirmationPresented = true
  }

  private func confirmDocumentDeletion() {
    guard let document = documentPendingDeletion else { return }
    documentPendingDeletion = nil
    if knowledge.moveToRecycleBin([document.id]) {
      EditorAccessibilityAnnouncementCenter.announce(
        "已将资料移到回收站：\(document.title)。",
        priority: .medium
      )
    }
  }

  private var batchActionBar: some View {
    HStack(spacing: 6) {
      Text("已选 \(selectedDocumentIDs.count) 条")
        .font(.caption.weight(.semibold))
        .monospacedDigit()
      Spacer(minLength: 4)
      Button("完成") {
        exitBatchSelection()
      }
      .buttonStyle(.borderless)
      .help("退出批量选择（Esc）")
      .accessibilityLabel("完成批量选择")

      Menu {
        Button("未分类") {
          knowledge.moveDocuments(selectedDocumentIDs, to: nil)
          retainVisibleBatchSelection()
        }
        if !knowledge.folders.isEmpty { Divider() }
        ForEach(knowledge.folders) { folder in
          Button(folder.name) {
            knowledge.moveDocuments(selectedDocumentIDs, to: folder.id)
            retainVisibleBatchSelection()
          }
        }
      } label: {
        Image(systemName: "folder")
      }
      .help("批量移动")
      .accessibilityLabel("批量移动所选资料")

      Button {
        batchTags = ""
        isBatchTagEditorPresented = true
      } label: {
        Image(systemName: "tag")
      }
      .buttonStyle(.plain)
      .help("批量添加标签")
      .accessibilityLabel("批量添加标签")

      Menu {
        Button("允许 AI 使用") {
          knowledge.setAllowsAIUse(true, documentIDs: selectedDocumentIDs)
        }
        Button("不允许 AI 使用") {
          knowledge.setAllowsAIUse(false, documentIDs: selectedDocumentIDs)
        }
      } label: {
        Image(systemName: "sparkles")
      }
      .help("批量设置 AI 权限")
      .accessibilityLabel("批量设置 AI 权限")

      Menu {
        Button {
          exportBatchSelection()
        } label: {
          Label("导出为 Markdown…", systemImage: "square.and.arrow.up")
        }
        Button {
          let ids = selectedDocumentIDs
          Task { await knowledge.rebuildSemanticIndex(for: ids) }
        } label: {
          Label("重建语义索引", systemImage: "arrow.triangle.2.circlepath")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .help("更多批量操作")
      .accessibilityLabel("更多批量操作")

      Button(role: .destructive) {
        isBatchRecycleConfirmationPresented = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.plain)
      .help("移到回收站")
      .accessibilityLabel("将所选资料移到回收站")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.accentColor.opacity(0.06))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("批量操作，已选择 \(selectedDocumentIDs.count) 条资料")
  }

  private var parsedBatchTags: [String] {
    batchTags
      .components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private func confirmBatchTags() {
    knowledge.addTags(parsedBatchTags, to: selectedDocumentIDs)
    batchTags = ""
  }

  private func confirmBatchRecycle() {
    let count = selectedDocumentIDs.count
    guard knowledge.moveToRecycleBin(selectedDocumentIDs) else { return }
    selectedDocumentIDs = []
    EditorAccessibilityAnnouncementCenter.announce(
      "已将 \(count) 条资料移到回收站。",
      priority: .medium
    )
  }

  private func exitBatchSelection() {
    guard selectedDocumentIDs.count > 1 else { return }
    if let selectedDocumentID = knowledge.selectedDocumentID {
      selectedDocumentIDs = [selectedDocumentID]
    } else {
      selectedDocumentIDs = []
    }
    EditorAccessibilityAnnouncementCenter.announce(
      "已退出批量选择。",
      priority: .low
    )
  }

  private func exportBatchSelection() {
    guard let destinationURL = KnowledgeBatchExportSelectionPanel.chooseDestinationDirectory() else {
      return
    }
    let ids = selectedDocumentIDs
    Task {
      _ = await knowledge.exportDocuments(ids, to: destinationURL)
    }
  }

  private func handleListSelectionChange(previous: Set<UUID>, current: Set<UUID>) {
    guard !current.isEmpty else {
      knowledge.selectDocument(nil)
      return
    }
    if let selectedID = knowledge.selectedDocumentID, current.contains(selectedID) {
      return
    }
    let newlySelected = current.subtracting(previous).first ?? current.first
    knowledge.selectDocument(newlySelected)
  }

  private func synchronizeListSelection() {
    guard searchText.trimmedForPublishing.isEmpty else { return }
    guard let selectedID = knowledge.selectedDocumentID,
          knowledge.visibleDocuments.contains(where: { $0.id == selectedID }) else {
      selectedDocumentIDs = []
      return
    }
    if selectedDocumentIDs.count <= 1 || !selectedDocumentIDs.contains(selectedID) {
      selectedDocumentIDs = [selectedID]
    }
  }

  private func retainVisibleBatchSelection() {
    let visibleIDs = Set(knowledge.visibleDocuments.map(\.id))
    selectedDocumentIDs.formIntersection(visibleIDs)
    synchronizeListSelection()
  }

  private func documentFolderMenu(_ document: KnowledgeDocument) -> some View {
    Menu(String(localized: "移动到文件夹")) {
      Button {
        knowledge.moveDocument(document.id, to: nil)
      } label: {
        Label(String(localized: "未分类"), systemImage: document.folderID == nil ? "checkmark" : "tray")
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

  private var selectedFolderTitle: String {
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

  private var selectedScopeSystemImage: String {
    switch knowledge.folderScope {
    case .all: "books.vertical"
    case .unfiled: "tray"
    case .folder: "folder"
    case .smartCollection(let rule): rule.systemImage
    case .savedCollection: "bookmark"
    }
  }

  @ViewBuilder
  private var emptyFolderState: some View {
    switch knowledge.folderScope {
    case .all:
      EmptyStateView(
        title: "还没有资料",
        message: "导入资料，或从其他文件夹移动到这里。",
        systemImage: "books.vertical",
        density: .inline,
        actionTitle: "导入资料",
        actionSystemImage: "plus",
        action: { isImportPresented = true }
      )
    case .unfiled:
      EmptyStateView(
        title: "没有未分类资料",
        message: "导入资料，或从其他文件夹移动到这里。",
        systemImage: "tray",
        density: .inline,
        actionTitle: "导入资料",
        actionSystemImage: "plus",
        action: { isImportPresented = true }
      )
    case .folder:
      EmptyStateView(
        title: "此文件夹还没有资料",
        message: "导入资料，或从其他文件夹移动到这里。",
        systemImage: "folder",
        density: .inline,
        actionTitle: "导入资料",
        actionSystemImage: "plus",
        action: { isImportPresented = true }
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

  private var sortFieldBinding: Binding<KnowledgeDocumentSortField> {
    Binding(
      get: { knowledge.documentSort.field },
      set: { knowledge.setDocumentSortField($0) }
    )
  }

  private var sortDirectionBinding: Binding<KnowledgeSortDirection> {
    Binding(
      get: { knowledge.documentSort.direction },
      set: { knowledge.setDocumentSortDirection($0) }
    )
  }

  private var searchScopeBinding: Binding<KnowledgeSearchScope> {
    Binding(
      get: { knowledge.searchFilter.scope },
      set: { knowledge.setSearchScope($0) }
    )
  }

  private var searchSignalBinding: Binding<KnowledgeSearchSignalFilter> {
    Binding(
      get: { knowledge.searchFilter.signal },
      set: { knowledge.setSearchSignalFilter($0) }
    )
  }

  private var searchSortBinding: Binding<KnowledgeSearchResultSort> {
    Binding(
      get: { knowledge.searchFilter.sort },
      set: { knowledge.setSearchResultSort($0) }
    )
  }

  private var folderEditorTitle: String {
    switch folderEditorMode {
    case .create: String(localized: "新建资料文件夹")
    case .rename: String(localized: "重命名资料文件夹")
    }
  }

  private var folderEditorActionTitle: String {
    switch folderEditorMode {
    case .create: String(localized: "创建")
    case .rename: String(localized: "保存")
    }
  }

  private func beginCreatingFolder() {
    folderEditorMode = .create
    folderName = ""
    isFolderEditorPresented = true
  }

  private func beginRenamingFolder(_ folder: KnowledgeFolder) {
    folderEditorMode = .rename(folder.id)
    folderName = folder.name
    isFolderEditorPresented = true
  }

  private func requestFolderDeletion(_ folder: KnowledgeFolder) {
    folderPendingDeletion = folder
    isFolderDeleteConfirmationPresented = true
  }

  private func commitFolderEditor() {
    switch folderEditorMode {
    case .create:
      knowledge.createFolder(name: folderName)
    case .rename(let folderID):
      knowledge.renameFolder(id: folderID, name: folderName)
    }
  }

  private func createKnowledgeBackup() {
    guard let destinationURL = KnowledgeLibraryBackupSelectionPanel.chooseBackupDestination() else {
      return
    }
    Task {
      _ = await knowledge.createBackup(at: destinationURL)
    }
  }

  private func chooseKnowledgeBackupForRestore() {
    guard let backupURL = KnowledgeLibraryBackupSelectionPanel.chooseBackupForRestore() else {
      return
    }
    Task {
      restorePreview = await knowledge.backupPreview(from: backupURL)
    }
  }

  private var commandActions: KnowledgeLibraryCommandActions {
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
    let documents = knowledge.visibleDocuments
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
    let results = knowledge.visibleSearchResults
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
}

private enum FolderEditorMode {
  case create
  case rename(UUID)
}

private struct KnowledgeSearchDocumentGroup: Identifiable {
  var id: UUID { document.id }
  let document: KnowledgeDocument
  var results: [KnowledgeSearchResult]
}
