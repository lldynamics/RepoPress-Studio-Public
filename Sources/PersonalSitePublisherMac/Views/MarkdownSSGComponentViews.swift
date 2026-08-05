import PublishingWorkbenchCore
import SwiftUI

struct MarkdownSSGComponentThumbnail: View {
  let kind: MarkdownSSGComponentKind
  let title: String
  let previewText: String

  init(
    kind: MarkdownSSGComponentKind,
    title: String,
    previewText: String = ""
  ) {
    self.kind = kind
    self.title = title
    self.previewText = previewText
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.045))

      switch kind {
      case .callout:
        calloutPreview
      case .lead:
        leadPreview
      case .youtube, .bilibili:
        videoPreview
      case .githubCard:
        githubPreview
      case .figure:
        figurePreview
      case .custom:
        customPreview
      }
    }
    .frame(width: 164, height: 76)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(title)缩略预览")
    .accessibilityValue(previewText.nilIfEmpty ?? "组件模板")
  }

  private var calloutPreview: some View {
    HStack(alignment: .top, spacing: 8) {
      RoundedRectangle(cornerRadius: 2)
        .fill(WorkbenchTheme.warning)
        .frame(width: 4)
      VStack(alignment: .leading, spacing: 4) {
        Text("提示")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)
        Text(previewText.nilIfEmpty ?? "在这里输入提示内容")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(10)
  }

  private var leadPreview: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("文章导语")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.primary)
      Text(previewText.nilIfEmpty ?? "在这里输入文章导语")
        .font(.caption.italic())
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Capsule()
        .fill(Color.accentColor.opacity(0.28))
        .frame(width: 90, height: 4)
    }
    .padding(10)
  }

  private var videoPreview: some View {
    ZStack {
      LinearGradient(
        colors: [Color.black.opacity(0.72), Color.accentColor.opacity(0.55)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      VStack(spacing: 4) {
        Image(systemName: kind.systemImage)
          .font(.title3)
          .foregroundStyle(.white)
        Text(kind == .youtube ? "YouTube" : "B 站")
          .font(.caption.weight(.medium))
          .foregroundStyle(.white)
        Text(previewText.nilIfEmpty ?? "VIDEO_ID")
          .font(.workbenchMetadata.monospaced())
          .foregroundStyle(.white.opacity(0.82))
          .lineLimit(1)
      }
    }
  }

  private var githubPreview: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .foregroundStyle(.primary)
        Text("GitHub")
          .font(.caption.weight(.semibold))
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      }
      Text(previewText.nilIfEmpty ?? "owner/repo")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      HStack(spacing: 5) {
        Capsule().fill(Color.orange.opacity(0.75)).frame(width: 28, height: 4)
        Capsule().fill(Color.green.opacity(0.65)).frame(width: 44, height: 4)
      }
    }
    .padding(10)
  }

  private var figurePreview: some View {
    HStack(spacing: 9) {
      RoundedRectangle(cornerRadius: 5)
        .fill(
          LinearGradient(
            colors: [Color.accentColor.opacity(0.30), Color.accentColor.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .overlay {
          Image(systemName: "photo")
            .foregroundStyle(.tint)
        }
        .frame(width: 54, height: 54)
      VStack(alignment: .leading, spacing: 5) {
        Text("图片")
          .font(.caption.weight(.semibold))
        Text(previewText.nilIfEmpty ?? "/images/example.jpg")
          .font(.workbenchMetadata.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(10)
  }

  private var customPreview: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: kind.systemImage)
          .foregroundStyle(.tint)
        Text("自定义短代码")
          .font(.caption.weight(.semibold))
        Spacer()
      }
      Text(previewText.nilIfEmpty ?? "{{< component >}}")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Capsule()
        .fill(Color.accentColor.opacity(0.30))
        .frame(width: 72, height: 4)
    }
    .padding(10)
  }
}

struct MarkdownSSGComponentPreviewStrip: View {
  let occurrences: [MarkdownSSGComponentOccurrence]
  let onSelect: (MarkdownSSGComponentOccurrence) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Label("组件缩略预览", systemImage: "rectangle.3.group")
          .font(.caption.weight(.semibold))
        Text("点击卡片定位源码")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(occurrences.count) 个")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
      }

      ScrollView(.horizontal, showsIndicators: true) {
        HStack(alignment: .top, spacing: 9) {
          ForEach(occurrences.prefix(12)) { occurrence in
            Button {
              onSelect(occurrence)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                MarkdownSSGComponentThumbnail(
                  kind: occurrence.kind,
                  title: occurrence.title,
                  previewText: occurrence.previewText
                )
                Text("第 \(occurrence.lineNumber) 行 · \(occurrence.title)")
                  .font(.workbenchMetadata)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .frame(width: 164, alignment: .leading)
              }
            }
            .buttonStyle(.plain)
            .help("定位到第 \(occurrence.lineNumber) 行的\(occurrence.title)")
            .accessibilityLabel("定位到第 \(occurrence.lineNumber) 行的\(occurrence.title)")
          }
        }
        .padding(.vertical, 2)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("SSG 组件缩略预览，共 \(occurrences.count) 个")
  }
}
