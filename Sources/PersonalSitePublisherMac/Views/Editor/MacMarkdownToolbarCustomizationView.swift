import SwiftUI

struct MacMarkdownToolbarCustomizationView: View {
  @Binding var configuration: MarkdownToolbarConfiguration
  let onDismiss: () -> Void

  @State private var workingConfig: MarkdownToolbarConfiguration

  init(
    configuration: Binding<MarkdownToolbarConfiguration>,
    onDismiss: @escaping () -> Void
  ) {
    _configuration = configuration
    self.onDismiss = onDismiss
    _workingConfig = State(initialValue: configuration.wrappedValue.normalized)
  }

  var body: some View {
    VStack(spacing: 16) {
      headerView

      Divider()

      ScrollView {
        VStack(spacing: 20) {
          headerSection
          formattingSection
        }
        .padding(.horizontal)
      }

      Divider()

      footerView
    }
    .padding(.vertical, 16)
    .frame(width: 520, height: 560)
    .background(.regularMaterial)
  }

  private var headerView: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("自定义写作工具栏")
          .font(.headline)
        Text("使用上下按钮调整图标顺序，勾选控制显示与隐藏")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        workingConfig = .defaultConfiguration
      } label: {
        Label("恢复默认", systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(.borderless)
      .font(.caption)
    }
    .padding(.horizontal)
  }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("顶部主工具栏按钮")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      itemList(for: .header)
    }
  }

  private var formattingSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("排版格式栏按钮")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      itemList(for: .formatting)
    }
  }

  private func itemList(for category: MarkdownToolbarCategory) -> some View {
    let allItems = MarkdownToolbarItemID.allCases.filter {
      $0.defaultCategory == category
        && (category != .header || !MarkdownArticleToolbarScope.isWorkspaceOwned($0))
    }
    let currentIDs =
      category == .header ? workingConfig.headerItemIDs : workingConfig.formattingItemIDs

    return VStack(spacing: 4) {
      ForEach(allItems) { item in
        let isPresent = currentIDs.contains(item)
        HStack(spacing: 10) {
          Toggle(
            isOn: Binding(
              get: { isPresent },
              set: { enabled in
                toggleItem(item, enabled: enabled, category: category)
              }
            )
          ) {
            HStack(spacing: 8) {
              Image(systemName: item.systemImage)
                .frame(width: 20)
                .foregroundStyle(isPresent ? Color.accentColor : Color.secondary)
              Text(item.title)
                .font(.callout)
              if item.isMandatory {
                Text("(常驻)")
                  .font(.workbenchMetadata)
                  .foregroundStyle(.tertiary)
              }
            }
          }
          .disabled(item.isMandatory)

          Spacer()

          if isPresent && !item.isMandatory {
            HStack(spacing: 2) {
              Button {
                moveItem(item, direction: .up, category: category)
              } label: {
                Image(systemName: "chevron.up")
              }
              .buttonStyle(.borderless)
              .disabled(isFirstItem(item, category: category))

              Button {
                moveItem(item, direction: .down, category: category)
              } label: {
                Image(systemName: "chevron.down")
              }
              .buttonStyle(.borderless)
              .disabled(isLastItem(item, category: category))
            }
            .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isPresent ? Color.primary.opacity(0.04) : Color.clear)
        )
      }
    }
  }

  private var footerView: some View {
    HStack {
      Spacer()
      Button("取消") {
        onDismiss()
      }
      .keyboardShortcut(.cancelAction)

      Button("保存设置") {
        configuration = workingConfig.normalized
        onDismiss()
      }
      .keyboardShortcut(.defaultAction)
      .workbenchProminentActionStyle()
    }
    .padding(.horizontal)
  }

  private enum Direction {
    case up, down
  }

  private func isFirstItem(_ item: MarkdownToolbarItemID, category: MarkdownToolbarCategory) -> Bool
  {
    let list = category == .header ? workingConfig.headerItemIDs : workingConfig.formattingItemIDs
    return list.first == item
  }

  private func isLastItem(_ item: MarkdownToolbarItemID, category: MarkdownToolbarCategory) -> Bool
  {
    let list = category == .header ? workingConfig.headerItemIDs : workingConfig.formattingItemIDs
    return list.last == item
  }

  private func toggleItem(
    _ item: MarkdownToolbarItemID, enabled: Bool, category: MarkdownToolbarCategory
  ) {
    if category == .header {
      if enabled {
        if !workingConfig.headerItemIDs.contains(item) {
          workingConfig.headerItemIDs.append(item)
        }
      } else {
        workingConfig.headerItemIDs.removeAll { $0 == item }
      }
    } else {
      if enabled {
        if !workingConfig.formattingItemIDs.contains(item) {
          workingConfig.formattingItemIDs.append(item)
        }
      } else {
        workingConfig.formattingItemIDs.removeAll { $0 == item }
      }
    }
  }

  private func moveItem(
    _ item: MarkdownToolbarItemID, direction: Direction, category: MarkdownToolbarCategory
  ) {
    var list = category == .header ? workingConfig.headerItemIDs : workingConfig.formattingItemIDs
    guard let index = list.firstIndex(of: item) else { return }

    let targetIndex = direction == .up ? index - 1 : index + 1
    guard targetIndex >= 0 && targetIndex < list.count else { return }

    list.swapAt(index, targetIndex)

    if category == .header {
      workingConfig.headerItemIDs = list
    } else {
      workingConfig.formattingItemIDs = list
    }
  }
}
