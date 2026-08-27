import PublishingWorkbenchCore
import SwiftUI

extension KnowledgeSourceListColumn {
  @ViewBuilder
  var documentList: some View {
    if !searchText.trimmedForPublishing.isEmpty {
      searchResultList
    } else if listPresentation.documentRows.isEmpty {
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
          ForEach(listPresentation.documentRows) { row in
            documentRow(row)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onChange(of: selectedDocumentIDs) { previous, current in
          handleListSelectionChange(previous: previous, current: current)
        }
        .onDeleteCommand(perform: requestSelectedDocumentDeletion)
        .accessibilityIdentifier("knowledge-document-list")
      }
    }
  }

  private func documentRow(_ row: KnowledgeDocumentListRowSnapshot) -> some View {
    let document = row.document
    let isHovered = hoveredDocumentID == document.id
    return HStack(spacing: 9) {
      Image(systemName: document.kind.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: KnowledgeSidebarMetrics.rowTextSpacing) {
        Text(document.title)
          .font(.workbenchItemTitle)
          .workbenchTruncatedIdentity(document.title)
        Text(row.subtitle)
          .font(.workbenchSupporting)
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(row.subtitle)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(document.title)，\(row.subtitle)")

      Spacer(minLength: 4)

      if knowledge.isPinned(document.id) {
        Image(systemName: "pin.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("已固定到 AI")
      } else if !document.allowsLocalSemanticIndex {
        Image(systemName: "slash.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("未建立本地语义索引")
      }
      if !document.allowsRemoteAIUse {
        Image(systemName: "hand.raised")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityLabel("禁止发送给远程 AI")
      }

      if isHovered || selectedDocumentIDs.contains(document.id) {
        documentActionsMenu(document)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isHovered ? Color.primary.opacity(0.05) : Color.clear,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .contentShape(Rectangle())
    .animation(WorkbenchMotion.hoverSpring, value: isHovered)
    .onHover { isHovered in
      if isHovered {
        hoveredDocumentID = document.id
      } else if hoveredDocumentID == document.id {
        hoveredDocumentID = nil
      }
    }
    .listRowInsets(KnowledgeSidebarMetrics.listRowInsets)
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
      document.allowsLocalSemanticIndex
        ? String(localized: "关闭本地语义索引")
        : String(localized: "建立本地语义索引")
    ) {
      knowledge.setAllowsLocalSemanticIndex(
        !document.allowsLocalSemanticIndex,
        documentID: document.id
      )
    }
    Button(
      knowledge.isPinned(document.id)
        ? String(localized: "取消固定")
        : String(localized: "固定到 AI 对话")
    ) {
      knowledge.setPinned(!knowledge.isPinned(document.id), documentID: document.id)
    }
    Button(
      document.allowsRemoteAIUse
        ? String(localized: "禁止发送给远程 AI")
        : String(localized: "允许发送给远程 AI")
    ) {
      knowledge.setAllowsRemoteAIUse(!document.allowsRemoteAIUse, documentID: document.id)
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
    } else if listPresentation.searchResults.isEmpty {
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
        ForEach(listPresentation.searchGroups) { group in
          Section {
            ForEach(group.results) { result in
              KnowledgeSearchResultRow(
                result: result,
                query: knowledge.searchText,
                showsDocumentTitle: false
              )
              .listRowInsets(KnowledgeSidebarMetrics.listRowInsets)
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
                .font(.workbenchMetadata.monospacedDigit())
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
      .accessibilityValue(
        String(localized: "共 \(listPresentation.searchResults.count) 个片段")
      )
      .accessibilityIdentifier("knowledge-search-result-list")
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

  var documentDeletionConfirmationTitle: String {
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

  func confirmDocumentDeletion() {
    guard let document = documentPendingDeletion else { return }
    documentPendingDeletion = nil
    if knowledge.moveToRecycleBin([document.id]) {
      EditorAccessibilityAnnouncementCenter.announce(
        "已将资料移到回收站：\(document.title)。",
        priority: .medium
      )
    }
  }
}
