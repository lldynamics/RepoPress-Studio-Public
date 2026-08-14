import SwiftUI

struct SlashCommandItem: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let systemImage: String
  let action: () -> Void

  static func == (lhs: SlashCommandItem, rhs: SlashCommandItem) -> Bool {
    lhs.id == rhs.id
  }
}

struct MarkdownSlashCommandMenu: View {
  let filterText: String
  let items: [SlashCommandItem]
  @Binding var selectedIndex: Int
  let onSelect: (SlashCommandItem) -> Void
  let onDismiss: () -> Void

  var filteredItems: [SlashCommandItem] {
    Self.filteredItems(from: items, matching: filterText)
  }

  static func filteredItems(
    from items: [SlashCommandItem],
    matching filterText: String
  ) -> [SlashCommandItem] {
    guard !filterText.isEmpty else { return items }
    return items.filter {
      $0.title.localizedCaseInsensitiveContains(filterText)
        || $0.id.localizedCaseInsensitiveContains(filterText)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if filteredItems.isEmpty {
        Text("未找到匹配命令")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 2) {
              ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                let isSelected = index == selectedIndex
                Button {
                  onSelect(item)
                } label: {
                  HStack(spacing: 10) {
                    Image(systemName: item.systemImage)
                      .font(.system(size: 13, weight: .medium))
                      .frame(width: 24, height: 24)
                      .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                      Text(item.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)

                      Text(item.subtitle)
                        .font(.workbenchMetadata)
                        .foregroundStyle(.tertiary)
                    }

                    Spacer()
                  }
                  .padding(.horizontal, 8)
                  .padding(.vertical, 5)
                  .background(
                    RoundedRectangle(cornerRadius: 6)
                      .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                  )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.subtitle)
                .accessibilityIdentifier("markdown-slash-command-\(item.id)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .id(index)
              }
            }
            .padding(4)
          }
          .frame(maxHeight: 240)
          .onChange(of: selectedIndex) { _, index in
            guard filteredItems.indices.contains(index) else { return }
            withAnimation(.easeOut(duration: 0.12)) {
              proxy.scrollTo(index, anchor: .center)
            }
          }
        }
      }
    }
    .frame(minWidth: 220, idealWidth: 250, maxWidth: 280)
    .background(
      .thinMaterial,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("斜杠命令菜单")
    .accessibilityIdentifier("markdown-slash-command-menu")
    .accessibilityAction(named: Text("关闭菜单")) {
      onDismiss()
    }
    .onChange(of: filterText) { _, _ in
      selectedIndex = 0
    }
  }
}
