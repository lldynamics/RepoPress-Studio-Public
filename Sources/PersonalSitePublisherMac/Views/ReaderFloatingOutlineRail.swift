import PublishingWorkbenchCore
import SwiftUI

struct ReaderFloatingOutlineRail: View {
  let markdownText: String
  let onSelectHeading: (MarkdownOutlineItem) -> Void
  @State private var outlineItems: [MarkdownOutlineItem] = []
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if isExpanded {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text("文章大纲")
              .font(.caption.weight(.bold))
              .foregroundStyle(.secondary)
            Spacer()
            Button {
              withAnimation(.spring(response: 0.3)) {
                isExpanded = false
              }
            } label: {
              Image(systemName: "xmark")
                .font(.caption2)
            }
            .buttonStyle(.plain)
          }
          .padding(.bottom, 4)

          if outlineItems.isEmpty {
            Text("暂无章节标题")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          } else {
            ScrollView(.vertical, showsIndicators: true) {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(outlineItems) { item in
                  Button {
                    onSelectHeading(item)
                  } label: {
                    HStack(spacing: 4) {
                      Rectangle()
                        .fill(item.level == 1 ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: item.level == 1 ? 3 : 2, height: 12)
                      Text(item.title)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(item.level == 1 ? .primary : .secondary)
                    }
                    .padding(.leading, CGFloat((item.level - 1) * 8))
                  }
                  .buttonStyle(.plain)
                }
              }
            }
            .frame(maxHeight: 240)
          }
        }
        .padding(10)
        .frame(width: 200)
        .workbenchGlassSurface(
          material: .regularMaterial,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 3)
      } else {
        Button {
          withAnimation(.spring(response: 0.3)) {
            isExpanded = true
          }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "list.bullet.indent")
            Text("目录 (\(outlineItems.count))")
          }
          .font(.caption.weight(.medium))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .workbenchGlassSurface(
            material: .regularMaterial,
            in: Capsule()
          )
          .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
      }
    }
    .onAppear {
      parseOutline()
    }
    .onChange(of: markdownText) { _, _ in
      parseOutline()
    }
  }

  private func parseOutline() {
    let service = MarkdownOutlineService()
    self.outlineItems = service.outline(in: markdownText)
  }
}
