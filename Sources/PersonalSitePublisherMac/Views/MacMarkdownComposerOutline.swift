import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif

enum MarkdownOutlineSectionAction {
  case moveUp
  case moveDown
  case duplicate
  case delete
  case copyAnchorLink
}
struct MarkdownOutlinePopover: View {
  let items: [MarkdownOutlineItem]
  let onSelect: (MarkdownOutlineItem) -> Void
  let onAction: (MarkdownOutlineSectionAction, MarkdownOutlineItem) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var collapsedItemIDs: Set<String> = []

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("文章大纲", systemImage: "list.bullet.indent")
          .font(.headline)

        Spacer()

        Text(String(localized: "章节 \(items.count)"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)

      Divider()

      if items.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "text.badge.plus")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.secondary)
          Text("还没有可导航的标题")
            .font(.headline)
          Text("在正文中添加 ## 或 ### 标题后，就能从这里快速跳转。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(visibleItems) { item in
              outlineRow(item)
            }
          }
          .padding(8)
        }
        .frame(maxHeight: 360)
      }
    }
    .frame(width: 320)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("markdown-outline-popover")
    .onChange(of: items.map(\.id)) { _, itemIDs in
      collapsedItemIDs.formIntersection(itemIDs)
    }
  }

  private func outlineRow(_ item: MarkdownOutlineItem) -> some View {
    HStack(spacing: 4) {
      Button {
        onSelect(item)
        dismiss()
      } label: {
        HStack(spacing: 8) {
          Text("H\(item.level)")
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, alignment: .leading)

          Text(item.title)
            .workbenchTruncatedIdentity(item.title)

          Spacer(minLength: 8)

          if !item.publicRiskSummary.isClear {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(
                item.publicRiskSummary.errorCount > 0
                  ? WorkbenchTheme.risk
                  : WorkbenchTheme.warning
              )
              .help(item.publicRiskSummary.statusTitle)
              .accessibilityHidden(true)
          }
        }
        .padding(.leading, item.level == 3 ? 16 : 0)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(String(localized: "\(item.level) 级标题：\(item.title)"))
      .accessibilityValue(item.publicRiskSummary.statusTitle)

      outlineActionMenu(for: item)
    }
  }

  private func outlineActionMenu(for item: MarkdownOutlineItem) -> some View {
    Menu {
      Button {
        onAction(.moveUp, item)
      } label: {
        Label {
          Text("章节上移")
        } icon: {
          Image(systemName: "arrow.up")
        }
      }
      .disabled(!canMove(item, direction: .up))

      Button {
        onAction(.moveDown, item)
      } label: {
        Label {
          Text("章节下移")
        } icon: {
          Image(systemName: "arrow.down")
        }
      }
      .disabled(!canMove(item, direction: .down))

      if hasChildItems(item) {
        Button {
          toggleCollapsed(item)
        } label: {
          if collapsedItemIDs.contains(item.id) {
            Label {
              Text("展开子章节")
            } icon: {
              Image(systemName: "chevron.down")
            }
          } else {
            Label {
              Text("折叠子章节")
            } icon: {
              Image(systemName: "chevron.right")
            }
          }
        }
      }

      Divider()

      Button {
        onAction(.duplicate, item)
      } label: {
        Label {
          Text("复制章节")
        } icon: {
          Image(systemName: "plus.square.on.square")
        }
      }

      Button {
        onAction(.copyAnchorLink, item)
      } label: {
        Label {
          Text("复制锚点链接")
        } icon: {
          Image(systemName: "link")
        }
      }

      Divider()

      Button(role: .destructive) {
        onAction(.delete, item)
      } label: {
        Label {
          Text("删除章节")
        } icon: {
          Image(systemName: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .foregroundStyle(.secondary)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(String(localized: "更多章节操作"))
    .accessibilityLabel(Text("更多章节操作"))
  }

  private var visibleItems: [MarkdownOutlineItem] {
    var collapsedLevel: Int?
    return items.filter { item in
      if let level = collapsedLevel {
        if item.level > level {
          return false
        }
        collapsedLevel = nil
      }
      if collapsedItemIDs.contains(item.id) {
        collapsedLevel = item.level
      }
      return true
    }
  }

  private func hasChildItems(_ item: MarkdownOutlineItem) -> Bool {
    guard let index = items.firstIndex(of: item), index + 1 < items.count else { return false }
    return items[index + 1].level > item.level
  }

  private func toggleCollapsed(_ item: MarkdownOutlineItem) {
    if !collapsedItemIDs.insert(item.id).inserted {
      collapsedItemIDs.remove(item.id)
    }
  }

  private func canMove(
    _ item: MarkdownOutlineItem,
    direction: MarkdownOutlineMoveDirection
  ) -> Bool {
    guard let itemIndex = items.firstIndex(of: item) else { return false }
    let lowerBound = stride(from: itemIndex - 1, through: 0, by: -1)
      .first(where: { items[$0].level < item.level })
      .map { $0 + 1 }
      ?? 0
    let upperBound = ((itemIndex + 1)..<items.count)
      .first(where: { items[$0].level < item.level })
      ?? items.count
    let siblingIndices = (lowerBound..<upperBound).filter { items[$0].level == item.level }
    guard let siblingPosition = siblingIndices.firstIndex(of: itemIndex) else { return false }

    switch direction {
    case .up:
      return siblingPosition > siblingIndices.startIndex
    case .down:
      return siblingIndices.index(after: siblingPosition) < siblingIndices.endIndex
    }
  }
}
