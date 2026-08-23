import PublishingWorkbenchCore
import SwiftUI

struct DefaultRulePathSection: View {
  let activeProfileBinding: Binding<SiteProfile>
  let shouldFocusPaths: Bool
  let navigationRequestID: UUID
  @FocusState private var focusedPathField: DefaultRulePathField?

  var body: some View {
    TextField("内容根目录", text: activeProfileBinding.contentRoot)
      .focused($focusedPathField, equals: .contentRoot)
      .accessibilityLabel("内容根目录")
      .accessibilityValue(activeProfile.contentRoot)

    TextField("资源根目录", text: activeProfileBinding.assetRoot)
      .accessibilityLabel("资源根目录")
      .accessibilityValue(activeProfile.assetRoot)

    TextField("Markdown 路径模板", text: activeProfileBinding.markdownPathPattern)
      .accessibilityLabel("Markdown 路径模板")
      .accessibilityValue(activeProfile.markdownPathPattern)

    pathPreviewRow(
      label: "生成文章路径示例",
      path: renderedMarkdownSample,
      icon: "doc.text"
    )

    TextField("图片路径模板", text: activeProfileBinding.imagePathPattern)
      .accessibilityLabel("图片路径模板")
      .accessibilityValue(activeProfile.imagePathPattern)

    pathPreviewRow(
      label: "生成文章资源示例",
      path: renderedImageSample,
      icon: "photo"
    )

    TextField("公开图片路径模板", text: activeProfileBinding.publicImagePathPattern)
      .accessibilityLabel("公开图片路径模板")
      .accessibilityValue(activeProfile.publicImagePathPattern)

    pathPreviewRow(
      label: "生成公开引用示例",
      path: renderedPublicImageSample,
      icon: "globe"
    )

    placeholderGuidance
      .task(id: navigationRequestID) {
        guard shouldFocusPaths else { return }
        focusedPathField = .contentRoot
      }
  }

  private var activeProfile: SiteProfile {
    activeProfileBinding.wrappedValue
  }

  private var renderedMarkdownSample: String {
    let sampleDraft = ArticleDraft(
      siteProfileID: activeProfile.id,
      title: "示例文章",
      date: Date(),
      slug: "hello-world"
    )
    return activeProfile.markdownPath(for: sampleDraft)
  }

  private var renderedImageSample: String {
    let sampleDraft = ArticleDraft(
      siteProfileID: activeProfile.id,
      title: "示例文章",
      date: Date(),
      slug: "hello-world"
    )
    return activeProfile.imageRepositoryPath(filename: "cover.png", draft: sampleDraft)
  }

  private var renderedPublicImageSample: String {
    let sampleDraft = ArticleDraft(
      siteProfileID: activeProfile.id,
      title: "示例文章",
      date: Date(),
      slug: "hello-world"
    )
    return activeProfile.publicImagePath(filename: "cover.png", draft: sampleDraft)
  }

  private func pathPreviewRow(label: String, path: String, icon: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon)
        .font(.caption2)
        .foregroundStyle(WorkbenchTheme.brand)

      Text("\(label)：")
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(path.isEmpty ? "未生成有效路径" : path)
        .font(.caption.monospaced())
        .foregroundStyle(path.isEmpty ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 8)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.6),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label)：\(path)")
  }

  private var placeholderGuidance: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("支持的占位符变量：")
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          placeholderBadge("{year}", desc: "年")
          placeholderBadge("{month}", desc: "月")
          placeholderBadge("{day}", desc: "日")
          placeholderBadge("{slug}", desc: "短链")
          placeholderBadge("{titleSlug}", desc: "标题拼音")
          placeholderBadge("{filename}", desc: "文件名")
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            placeholderBadge("{year}", desc: "年")
            placeholderBadge("{month}", desc: "月")
            placeholderBadge("{day}", desc: "日")
          }
          HStack(spacing: 6) {
            placeholderBadge("{slug}", desc: "短链")
            placeholderBadge("{titleSlug}", desc: "标题拼音")
            placeholderBadge("{filename}", desc: "文件名")
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  private func placeholderBadge(_ placeholder: String, desc: String) -> some View {
    HStack(spacing: 2) {
      Text(placeholder)
        .font(.caption2.monospaced().weight(.semibold))
        .foregroundStyle(WorkbenchTheme.brand)
      Text("(\(desc))")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      WorkbenchTheme.brand.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.chartBar)
    )
  }
}

private enum DefaultRulePathField: Hashable {
  case contentRoot
}
