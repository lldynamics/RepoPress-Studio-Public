import PublishingWorkbenchCore
import SwiftUI

extension KnowledgeSourceListColumn {
  var knowledgeHeader: some View {
    WorkspaceContextListHeader(title: "资料") {
      if searchText.trimmedForPublishing.isEmpty {
        Text("\(listPresentation.documentRows.count) 条")
      } else {
        Text("\(listPresentation.searchGroups.count) 篇 · \(listPresentation.searchResults.count) 片段")
          .monospacedDigit()
      }
    } actions: {
      Menu {
        Button {
          isSettingsPresented = true
        } label: {
          Label("资料库设置…", systemImage: "gearshape")
        }
        Divider()
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
          openDataManagement()
        } label: {
          Label("数据管理…", systemImage: "externaldrive")
        }
      } label: {
        Label("管理与设置", systemImage: "ellipsis.circle")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .controlSize(.regular)
      .fixedSize()
      .help("资料库设置、回收站、备份与恢复")
      .accessibilityLabel("资料库管理")
      .disabled(knowledge.isBusy)
      if !knowledge.documents.isEmpty {
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
  }

  @ViewBuilder
  var knowledgeInsertionActions: some View {
    if let document = knowledge.selectedDocument {
      HStack(spacing: 8) {
        Button {
          _ = KnowledgeArticleInsertionService.insertCurrentArticle(
            document: document,
            text: knowledge.selectedDocumentText,
            into: store
          )
        } label: {
          Label("插入当前文章", systemImage: "text.insert")
        }
        .workbenchProminentActionStyle()
        .controlSize(.small)
        .disabled(knowledge.selectedDocumentText.trimmedForPublishing.isEmpty || knowledge.isBusy)
        .help("将当前资料正文插入正在编辑的文章")
        .accessibilityIdentifier("knowledge-insert-current-article")

        Button {
          _ = KnowledgeArticleInsertionService.insertCitation(
            document: document,
            selectedResult: knowledge.selectedSearchResult,
            fallbackText: knowledge.selectedDocumentText,
            into: store
          )
        } label: {
          Label("插入引用", systemImage: "quote.opening")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(knowledge.selectedDocumentText.trimmedForPublishing.isEmpty || knowledge.isBusy)
        .help("将当前选中片段作为引用插入正在编辑的文章")
        .accessibilityIdentifier("knowledge-insert-citation")

        Spacer(minLength: 0)
      }
      .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
      .padding(.vertical, 8)
      .background(WorkbenchBackgroundStyle.card)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("插入当前资料")
    }
  }

  var knowledgeListToolbar: some View {
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
          .accessibilityIdentifier("knowledge-source-search")

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
        ScrollView(.horizontal, showsIndicators: true) {
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
      ScrollView(.horizontal, showsIndicators: true) {
        HStack(spacing: 5) {
          ForEach(collection.rules, id: \.id) { rule in
            Text(rule.localizedDisplayName)
              .font(.workbenchMetadata)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(WorkbenchBackgroundStyle.card, in: Capsule())
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
    .font(.workbenchMetadata.weight(.medium))
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
}
