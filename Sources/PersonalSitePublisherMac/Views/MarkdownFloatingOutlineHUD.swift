import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum MarkdownFloatingOutlineHUDPresentation {
  static func activeItem(
    items: [MarkdownOutlineItem],
    visibleRange: NSRange,
    selectedRange: NSRange
  ) -> MarkdownOutlineItem? {
    guard !items.isEmpty else { return nil }

    let hasVisibleRange = visibleRange.location >= 0 && visibleRange.length > 0
    let visibleStart = hasVisibleRange ? visibleRange.location : selectedRange.location
    let visibleEnd = hasVisibleRange
      ? NSMaxRange(visibleRange)
      : NSMaxRange(selectedRange)

    if let item = items.last(where: { $0.headingLocation <= visibleStart }) {
      return item
    }
    if let item = items.first(where: { $0.headingLocation < visibleEnd }) {
      return item
    }
    return items.first
  }

  static func activeItemID(
    items: [MarkdownOutlineItem],
    visibleRange: NSRange,
    selectedRange: NSRange
  ) -> String? {
    activeItem(
      items: items,
      visibleRange: visibleRange,
      selectedRange: selectedRange
    )?.id
  }
}

struct MarkdownFloatingOutlineHUD: View {
  let items: [MarkdownOutlineItem]
  let activeItemID: String?
  let onSelect: (MarkdownOutlineItem) -> Void
  @State private var isExpanded = true
  @State private var isHovered = false

  private var activeItem: MarkdownOutlineItem? {
    items.first { $0.id == activeItemID }
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 0) {
      header

      if isExpanded {
        Divider()
        outlineList
      }
    }
    .frame(width: isExpanded ? 244 : 174)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 4)
    .opacity(isHovered || isExpanded ? 0.97 : 0.78)
    .onHover { hovering in
      withAnimation(WorkbenchMotion.standard) {
        isHovered = hovering
      }
    }
    .padding(.trailing, 16)
    .padding(.top, 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("markdown-floating-outline-hud")
    .accessibilityLabel("文章大纲悬浮导航")
    .accessibilityValue(
      activeItem.map { "当前：\($0.title)" } ?? "没有活动标题"
    )
  }

  private var header: some View {
    HStack(spacing: 7) {
      if activeItem != nil {
        Circle()
          .fill(Color.accentColor)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }

      if isExpanded {
        Label("文章大纲", systemImage: "list.bullet.indent")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        Text(String(localized: "\(items.count) 节"))
          .font(.workbenchMetadata)
          .foregroundStyle(.tertiary)
      } else {
        Text(activeItem?.title ?? "文章大纲")
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      Button {
        withAnimation(WorkbenchMotion.gentleSpring) {
          isExpanded.toggle()
        }
      } label: {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.caption.weight(.semibold))
          .frame(width: 22, height: 22)
          .background(Color.primary.opacity(0.08), in: Circle())
      }
      .buttonStyle(.plain)
      .help(
        isExpanded ? String(localized: "收起悬浮大纲") : String(localized: "展开悬浮大纲")
      )
      .accessibilityLabel(isExpanded ? "收起悬浮大纲" : "展开悬浮大纲")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var outlineList: some View {
    if items.isEmpty {
      Text("还没有可导航的标题")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
    } else {
      ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(items) { item in
            Button {
              onSelect(item)
            } label: {
              outlineRow(for: item)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("定位到标题：\(item.title)")
            .accessibilityValue(item.id == activeItemID ? "当前标题" : "")
          }
        }
        .padding(8)
      }
      .frame(maxHeight: 280)
    }
  }

  private func outlineRow(for item: MarkdownOutlineItem) -> some View {
    let isActive = item.id == activeItemID

    return HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2)
        .fill(isActive ? Color.accentColor : Color.clear)
        .frame(width: 3)

      Text("H(item.level)")
        .font(.workbenchMetadata.monospaced().weight(.semibold))
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
        .frame(width: 24, alignment: .leading)

      Text(item.title)
        .font(.caption.weight(isActive ? .semibold : .regular))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer(minLength: 4)
    }
    .padding(.leading, CGFloat(max(0, item.level - 2)) * 12)
    .padding(.trailing, 6)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(isActive ? Color.accentColor.opacity(0.13) : Color.clear)
    )
    .contentShape(Rectangle())
  }
}
