import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeCollectionNavigationView: View {
  @ObservedObject var knowledge: KnowledgeStore
  let onCreateFolder: () -> Void
  let onRenameFolder: (KnowledgeFolder) -> Void
  let onDeleteFolder: (KnowledgeFolder) -> Void

  @AppStorage("knowledgeSavedCollectionsV1") private var savedCollectionsJSON = "[]"
  @AppStorage("knowledgeFavoriteCollectionIDsV1") private var favoriteIDsJSON = "[]"
  @AppStorage("knowledgeFavoriteCollectionOrderV1") private var favoriteOrderJSON = "[]"
  @AppStorage("knowledgeCollectionNavigationExpandedV2") private var isNavigationExpanded = false
  @State private var isCollectionBuilderPresented = false
  @State private var expandedSmartKinds = Set<String>()
  @State private var hoveredCollectionItemID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button {
          isNavigationExpanded.toggle()
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Label(
              "资料整理",
              systemImage: isNavigationExpanded ? "chevron.down" : "chevron.right"
            )
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            if !isNavigationExpanded {
              Text("当前：\(selectedNavigationItem.title) · \(selectedNavigationItem.count) 条")
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isNavigationExpanded ? "收起资料整理" : "展开资料整理")
        .accessibilityLabel(isNavigationExpanded ? "收起资料整理" : "展开资料整理")
        .accessibilityValue(
          String(
            localized: "当前范围：\(selectedNavigationItem.title)，\(selectedNavigationItem.count) 条资料"
          )
        )
        Spacer()
        Button(action: onCreateFolder) {
          Image(systemName: "folder.badge.plus")
            .font(.system(size: 15, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("新建资料文件夹")
        .accessibilityLabel("新建资料文件夹")
        Button {
          isCollectionBuilderPresented = true
        } label: {
          Image(systemName: "wand.and.stars.inverse")
            .font(.system(size: 15, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("保存组合智能集合")
        .accessibilityLabel("新建组合智能集合")
      }
      .padding(.horizontal, 10)

      if isNavigationExpanded {
        ScrollView(.vertical, showsIndicators: true) {
          LazyVStack(alignment: .leading, spacing: 2) {
          if !favoriteItems.isEmpty {
            collectionSectionTitle("收藏", systemImage: "star.fill")
            ForEach(Array(favoriteItems.enumerated()), id: \.element.id) { index, item in
              collectionRow(item, favoriteIndex: index)
            }
          }

          collectionSectionTitle("文件夹", systemImage: "folder")
          collectionRow(allItem)
          collectionRow(unfiledItem)
          ForEach(folderItems) { item in
            collectionRow(item)
          }

          if !savedItems.isEmpty {
            collectionSectionTitle("已存集合", systemImage: "bookmark")
            ForEach(savedItems) { item in
              collectionRow(item)
            }
          }

          if visibleSmartCollectionKinds.contains(where: { !smartItems(kind: $0).isEmpty }) {
            collectionSectionTitle("智能集合", systemImage: "wand.and.stars")
            ForEach(visibleSmartCollectionKinds) { kind in
              let items = smartItems(kind: kind)
              if !items.isEmpty {
                DisclosureGroup(
                  isExpanded: Binding(
                    get: { expandedSmartKinds.contains(kind.id) },
                    set: { isExpanded in
                      if isExpanded {
                        expandedSmartKinds.insert(kind.id)
                      } else {
                        expandedSmartKinds.remove(kind.id)
                      }
                    }
                  )
                ) {
                  ForEach(items) { item in
                    collectionRow(item, isIndented: true)
                  }
                } label: {
                  Label(kind.localizedDisplayName, systemImage: kind.systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
              }
            }
          }
          }
          .padding(.vertical, 4)
        }
      }
    }
    .frame(
      minHeight: isNavigationExpanded ? 110 : 38,
      idealHeight: isNavigationExpanded ? 160 : 38,
      maxHeight: isNavigationExpanded ? 190 : 38
    )
    .sheet(isPresented: $isCollectionBuilderPresented) {
      KnowledgeSavedCollectionBuilderView(
        collections: knowledge.smartCollections,
        onSave: saveCollection
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("资料文件夹与智能集合")
  }

  private func collectionSectionTitle(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 10)
      .padding(.top, 5)
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder
  private func collectionRow(
    _ item: CollectionNavigationItem,
    favoriteIndex: Int? = nil,
    isIndented: Bool = false
  ) -> some View {
    let isHovered = hoveredCollectionItemID == item.id
    Button {
      knowledge.setFolderScope(item.scope)
    } label: {
      HStack(spacing: 7) {
        Image(systemName: item.systemImage)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(knowledge.folderScope == item.scope ? Color.accentColor : Color.secondary)
          .frame(width: 18)
          .accessibilityHidden(true)
        Text(item.title)
          .font(.body)
          .lineLimit(1)
        Spacer(minLength: 2)
        Text(item.count.formatted())
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
        if isFavorite(item.id) {
          Image(systemName: "star.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }
      .padding(.leading, isIndented ? 14 : 0)
      .padding(.horizontal, 8)
      .padding(.vertical, KnowledgeSidebarMetrics.collectionRowVerticalPadding)
      .frame(minHeight: KnowledgeSidebarMetrics.collectionRowMinimumHeight)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(
            knowledge.folderScope == item.scope
              ? Color.accentColor.opacity(0.12)
              : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
          )
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredCollectionItemID = hovering ? item.id : nil
    }
    .contextMenu {
      Button(isFavorite(item.id) ? "取消收藏" : "加入收藏") {
        toggleFavorite(item.id)
      }
      if let favoriteIndex {
        Button("上移") { moveFavorite(at: favoriteIndex, offset: -1) }
          .disabled(favoriteIndex == 0)
        Button("下移") { moveFavorite(at: favoriteIndex, offset: 1) }
          .disabled(favoriteIndex == favoriteItems.count - 1)
      }
      if let folder = item.folder {
        Divider()
        Button("重命名文件夹…") { onRenameFolder(folder) }
        Button("删除文件夹…", role: .destructive) { onDeleteFolder(folder) }
      }
      if let savedCollection = item.savedCollection {
        Divider()
        Button("删除已存集合", role: .destructive) {
          deleteSavedCollection(savedCollection)
        }
      }
    }
    .accessibilityLabel("\(item.title)，\(item.count) 条资料")
    .accessibilityAddTraits(knowledge.folderScope == item.scope ? [.isSelected] : [])
  }

  private var allItem: CollectionNavigationItem {
    CollectionNavigationItem(
      id: "all",
      title: "全部资料",
      systemImage: "books.vertical",
      count: knowledge.documents.count,
      scope: .all
    )
  }

  private var unfiledItem: CollectionNavigationItem {
    CollectionNavigationItem(
      id: "unfiled",
      title: "未分类",
      systemImage: "tray",
      count: knowledge.documents.count { $0.folderID == nil },
      scope: .unfiled
    )
  }

  private var folderItems: [CollectionNavigationItem] {
    knowledge.folders.map { folder in
      CollectionNavigationItem(
        id: "folder:\(folder.id.uuidString)",
        title: folder.name,
        systemImage: "folder",
        count: knowledge.documents.count { $0.folderID == folder.id },
        scope: .folder(folder.id),
        folder: folder
      )
    }
  }

  private func smartItems(kind: KnowledgeSmartCollectionKind) -> [CollectionNavigationItem] {
    knowledge.smartCollections(kind: kind).map { collection in
      CollectionNavigationItem(
        id: "smart:\(collection.rule.id)",
        title: collection.rule.localizedDisplayName,
        systemImage: collection.rule.systemImage,
        count: collection.documentCount,
        scope: .smartCollection(collection.rule)
      )
    }
  }

  private var savedItems: [CollectionNavigationItem] {
    savedCollections.map { collection in
      CollectionNavigationItem(
        id: "saved:\(collection.id.uuidString)",
        title: collection.name,
        systemImage: "bookmark",
        count: knowledge.documentCount(for: collection),
        scope: .savedCollection(collection),
        savedCollection: collection
      )
    }
  }

  private var allItems: [CollectionNavigationItem] {
    [allItem, unfiledItem] + folderItems
      + visibleSmartCollectionKinds.flatMap(smartItems)
      + savedItems
  }

  private var visibleSmartCollectionKinds: [KnowledgeSmartCollectionKind] {
    KnowledgeSmartCollectionKind.allCases
  }

  private var selectedNavigationItem: CollectionNavigationItem {
    allItems.first(where: { $0.scope == knowledge.folderScope }) ?? allItem
  }

  private var favoriteItems: [CollectionNavigationItem] {
    let itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
    let ordered = favoriteOrder.compactMap { itemsByID[$0] }
    let orderedIDs = Set(ordered.map(\.id))
    let remainder = allItems.filter {
      favoriteIDs.contains($0.id) && !orderedIDs.contains($0.id)
    }
    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    return ordered + remainder
  }

  private var savedCollections: [KnowledgeSavedCollection] {
    allSavedCollections
  }

  private var allSavedCollections: [KnowledgeSavedCollection] {
    decode([KnowledgeSavedCollection].self, from: savedCollectionsJSON) ?? []
  }

  private var favoriteIDs: Set<String> {
    Set(decode([String].self, from: favoriteIDsJSON) ?? [])
  }

  private var favoriteOrder: [String] {
    decode([String].self, from: favoriteOrderJSON) ?? []
  }

  private func isFavorite(_ id: String) -> Bool {
    favoriteIDs.contains(id)
  }

  private func toggleFavorite(_ id: String) {
    var ids = favoriteIDs
    var order = favoriteOrder
    if ids.remove(id) != nil {
      order.removeAll { $0 == id }
    } else {
      ids.insert(id)
      order.append(id)
    }
    favoriteIDsJSON = encode(Array(ids).sorted())
    favoriteOrderJSON = encode(order)
  }

  private func moveFavorite(at index: Int, offset: Int) {
    var ids = favoriteItems.map(\.id)
    let destination = index + offset
    guard ids.indices.contains(index), ids.indices.contains(destination) else { return }
    ids.swapAt(index, destination)
    favoriteOrderJSON = encode(ids)
  }

  private func saveCollection(
    name: String,
    rules: [KnowledgeSmartCollectionRule],
    matchMode: KnowledgeSmartCollectionMatchMode
  ) {
    let collection = KnowledgeSavedCollection(name: name, rules: rules, matchMode: matchMode)
    var collections = allSavedCollections
    collections.append(collection)
    savedCollectionsJSON = encode(collections)
    knowledge.setFolderScope(.savedCollection(collection))
  }

  private func deleteSavedCollection(_ collection: KnowledgeSavedCollection) {
    var collections = allSavedCollections
    collections.removeAll { $0.id == collection.id }
    savedCollectionsJSON = encode(collections)
    let itemID = "saved:\(collection.id.uuidString)"
    if isFavorite(itemID) { toggleFavorite(itemID) }
    if case .savedCollection(let selected) = knowledge.folderScope,
       selected.id == collection.id {
      knowledge.setFolderScope(.all)
    }
  }

  private func decode<Value: Decodable>(_ type: Value.Type, from value: String) -> Value? {
    try? JSONDecoder().decode(type, from: Data(value.utf8))
  }

  private func encode<Value: Encodable>(_ value: Value) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }
}

private struct CollectionNavigationItem: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let count: Int
  let scope: KnowledgeFolderScope
  var folder: KnowledgeFolder? = nil
  var savedCollection: KnowledgeSavedCollection? = nil
}

private struct KnowledgeSavedCollectionBuilderView: View {
  @Environment(\.dismiss) private var dismiss
  let collections: [KnowledgeSmartCollection]
  let onSave: (String, [KnowledgeSmartCollectionRule], KnowledgeSmartCollectionMatchMode) -> Void
  @State private var name = ""
  @State private var matchMode = KnowledgeSmartCollectionMatchMode.all
  @State private var selectedRuleIDs = Set<String>()

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("新建组合智能集合", systemImage: "wand.and.stars")
          .font(.headline)
        Spacer()
      }
      .padding(14)
      Divider()

      VStack(alignment: .leading, spacing: 14) {
        TextField("集合名称", text: $name)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("智能集合名称")

        Picker("规则关系", selection: $matchMode) {
          Text("同时满足全部规则").tag(KnowledgeSmartCollectionMatchMode.all)
          Text("满足任一规则").tag(KnowledgeSmartCollectionMatchMode.any)
        }
        .pickerStyle(.segmented)

        Text("选择规则")
          .font(.callout.weight(.semibold))

        List {
          ForEach(visibleSmartCollectionKinds) { kind in
            let kindCollections = collections.filter { $0.rule.kind == kind }
            if !kindCollections.isEmpty {
              Section(kind.localizedDisplayName) {
                ForEach(kindCollections) { collection in
                  Toggle(isOn: ruleSelection(collection.rule)) {
                    HStack {
                      Label(collection.rule.localizedDisplayName, systemImage: collection.rule.systemImage)
                      Spacer()
                      Text("\(collection.documentCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                  }
                  .toggleStyle(.checkbox)
                }
              }
            }
          }
        }
        .listStyle(.inset)

        Text("组合集合会随作者、标签、来源和时间变化自动更新。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(18)

      Divider()
      HStack {
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("保存集合") {
          let selectedRules = collections.map(\.rule).filter { selectedRuleIDs.contains($0.id) }
          onSave(name, selectedRules, matchMode)
          dismiss()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedRuleIDs.isEmpty)
      }
      .padding(14)
    }
    .frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 650)
    .accessibilityIdentifier("knowledge-saved-collection-builder")
  }

  private func ruleSelection(_ rule: KnowledgeSmartCollectionRule) -> Binding<Bool> {
    Binding(
      get: { selectedRuleIDs.contains(rule.id) },
      set: { isSelected in
        if isSelected {
          selectedRuleIDs.insert(rule.id)
        } else {
          selectedRuleIDs.remove(rule.id)
        }
      }
    )
  }

  private var visibleSmartCollectionKinds: [KnowledgeSmartCollectionKind] {
    KnowledgeSmartCollectionKind.allCases
  }
}
