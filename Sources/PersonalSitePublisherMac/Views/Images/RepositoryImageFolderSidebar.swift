import PublishingDomainContracts
import SwiftUI

/// Native source-list navigation for the repository image browser.
struct RepositoryImageFolderSidebar: View {
  let inventory: RepositoryImageInventory?
  let isLoading: Bool
  let errorMessage: String?
  @Binding var scope: RepositoryImageBrowserScope
  @Binding var expandedPaths: Set<String>
  let onBrowse: () -> Void
  let onOpenMaintenance: () -> Void
  let onRefresh: () -> Void

  @State private var query = ""
  @State private var folderTree: RepositoryImageFolderTree?

  @State private var matchingPaths: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      searchField
      List {
        shortcutsSection
        folderSection
      }
      .listStyle(.sidebar)
      footer
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(String(localized: "图片目录侧边栏"))
    .onAppear(perform: rebuildTree)
    .onChange(of: inventory?.revisionID) { _, _ in rebuildTree() }
    .onChange(of: query) { _, _ in matchingPaths = folderTree?.matchingPaths(query: query) ?? [] }
    .overlay {
      if isLoading && inventory == nil {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(String(localized: "正在载入图片目录"))
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(String(localized: "搜索文件夹"), text: $query)
        .textFieldStyle(.plain)
        .accessibilityLabel(String(localized: "搜索图片文件夹名称"))
        .accessibilityIdentifier("repository-image-folder-search")
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(String(localized: "清除文件夹搜索"))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private var shortcutsSection: some View {
    Section {
      shortcutRow(
        title: String(localized: "全部图片"),
        systemImage: "photo.on.rectangle.angled",
        selected: scope == .all
      ) { select(.all) }
      shortcutRow(
        title: String(localized: "最近修改（近 30 天）"),
        systemImage: "clock.arrow.circlepath",
        selected: scope == .recent
      ) { select(.recent) }
    }
  }

  @ViewBuilder
  private var folderSection: some View {
    Section(String(localized: "图片文件夹")) {
      if folderTree != nil {
        ForEach(visibleFolders, id: \.node.id) { row in
          folderRow(row.node, depth: row.depth)
        }
      } else if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .padding(.vertical, 5)
          .accessibilityLabel(errorMessage)
      } else {
        Text(String(localized: "暂无图片目录"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.vertical, 5)
      }
    }
  }

  private var visibleFolders: [(node: RepositoryImageFolderNode, depth: Int)] {
    guard let folderTree else { return [] }
    var rows: [(node: RepositoryImageFolderNode, depth: Int)] = []
    func append(_ node: RepositoryImageFolderNode, depth: Int) {
      guard query.isEmpty || matchingPaths.contains(node.repositoryPath) else { return }
      rows.append((node, depth))
      if isExpanded(node) {
        for child in node.children { append(child, depth: depth + 1) }
      }
    }
    append(folderTree.root, depth: 0)
    return rows
  }

  private func folderRow(_ node: RepositoryImageFolderNode, depth: Int) -> some View {
    let selected = scope == .folder(node.repositoryPath)
    return
      HStack(spacing: 4) {
        Button {
          toggleExpansion(for: node.repositoryPath)
        } label: {
          Image(systemName: isExpanded(node) ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .frame(width: 18, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(node.children.isEmpty)
        .opacity(node.children.isEmpty ? 0 : 1)
        .accessibilityHidden(node.children.isEmpty)
        .accessibilityLabel(
          isExpanded(node)
            ? String(localized: "收起 ") + node.name
            : String(localized: "展开 ") + node.name
        )
        .accessibilityIdentifier("repository-image-folder-expand-" + safeID(node.repositoryPath))

        Button {
          select(.folder(node.repositoryPath))
        } label: {
          HStack(spacing: 7) {
            Image(systemName: "folder")
              .foregroundStyle(WorkbenchTheme.primary)
              .accessibilityHidden(true)
            Text(node.name)
              .lineLimit(1)
            Spacer(minLength: 4)
            Text(countLabel(node.recursiveImageCount))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .frame(minHeight: 28, alignment: .leading)
          .contentShape(Rectangle())
          .background(
            selected ? WorkbenchTheme.success.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
          )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(
          node.name + "，" + countLabel(node.recursiveImageCount) + String(localized: " 张图片")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("repository-image-folder-" + safeID(node.repositoryPath))
      }
      .padding(.leading, CGFloat(depth) * 14)
      .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
      .accessibilityElement(children: .contain)
  }

  private var footer: some View {
    VStack(spacing: 6) {
      Divider()
      HStack(spacing: 6) {
        Button(action: onOpenMaintenance) {
          Label(String(localized: "资源维护"), systemImage: "wrench.and.screwdriver")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "打开资源维护"))
        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "刷新图片目录"))
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
    }
  }

  private func shortcutRow(
    title: String,
    systemImage: String,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }
    .buttonStyle(.plain)
    .foregroundStyle(selected ? WorkbenchTheme.primary : .primary)
    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("repository-image-shortcut-" + title)
  }

  private func isExpanded(_ node: RepositoryImageFolderNode) -> Bool {
    expandedPaths.contains(node.repositoryPath)
      || (!query.isEmpty && matchingPaths.contains(node.repositoryPath))
  }

  private func toggleExpansion(for path: String) {
    if expandedPaths.contains(path) {
      expandedPaths.remove(path)
    } else {
      expandedPaths.insert(path)
    }
  }

  private func select(_ newScope: RepositoryImageBrowserScope) {
    scope = newScope
    onBrowse()
  }

  private func countLabel(_ count: Int) -> String {
    let value = inventory?.wasTruncated == true ? String(count) + "+" : String(count)
    return value
  }

  private func safeID(_ path: String) -> String {
    RepositoryAccessibilityIdentifier.token(for: path)
  }

  private func rebuildTree() {
    guard let inventory else {
      folderTree = nil
      matchingPaths = []
      return
    }
    folderTree = RepositoryImageFolderTree(
      assetRootPath: inventory.assetRootPath,
      directoryPaths: inventory.directoryPaths,
      assets: inventory.assets
    )
    matchingPaths = folderTree?.matchingPaths(query: query) ?? []
  }
}
