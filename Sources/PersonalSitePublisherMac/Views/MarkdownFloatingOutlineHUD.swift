import PublishingWorkbenchCore
import SwiftUI

struct MarkdownFloatingOutlineHUD: View {
  let items: [MarkdownOutlineItem]
  let onSelect: (MarkdownOutlineItem) -> Void
  @State private var isExpanded = true
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      HStack(spacing: 6) {
        if isExpanded {
          Label("文章大纲 (HUD)", systemImage: "list.bullet.indent")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
        }

        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            isExpanded.toggle()
          }
        } label: {
          Image(systemName: isExpanded ? "sidebar.right" : "list.bullet.indent")
            .font(.caption)
            .padding(5)
            .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收拢 HUD 大纲" : "展开 HUD 大纲")
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)

      if isExpanded && !items.isEmpty {
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
              Button {
                onSelect(item)
              } label: {
                outlineRow(for: item)
              }
              .buttonStyle(.plain)
              .background(
                RoundedRectangle(cornerRadius: 4)
                  .fill(Color.primary.opacity(0.05))
                  .opacity(0)
              )
            }
          }
          .padding(.horizontal, 8)
          .padding(.bottom, 8)
        }
        .frame(maxHeight: 280)
      }
    }
    .frame(width: isExpanded ? 210 : 36)
    .background(
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(.ultraThinMaterial)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(Color.primary.opacity(0.12), lineWidth: 1)
      }
    )
    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
    .opacity(isHovered || isExpanded ? 0.95 : 0.45)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.15)) {
        isHovered = hovering
      }
    }
    .padding(.trailing, 16)
    .padding(.top, 16)
  }

  private func outlineRow(for item: MarkdownOutlineItem) -> some View {
    HStack(spacing: 5) {
      Text(String(repeating: "#", count: item.level))
        .font(.workbenchMetadata.monospaced())
        .foregroundStyle(Color.accentColor)
      Text(item.title)
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(.primary)
    }
    .padding(.leading, CGFloat(max(0, item.level - 1)) * 10)
    .padding(.vertical, 3)
    .padding(.horizontal, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}
