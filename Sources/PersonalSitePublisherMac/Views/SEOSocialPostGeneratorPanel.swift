import PublishingWorkbenchCore
import SwiftUI

struct SEOSocialPostGeneratorPanel: View {
  let draft: ArticleDraft
  let profile: SiteProfile
  let store: WorkbenchStore
  @Environment(\.dismiss) private var dismiss
  @State private var selectedPlatform: SocialPlatform = .xiaohongshu
  @State private var generatedText = ""
  @State private var isGeneratingText = false
  @State private var isGeneratingCover = false
  @State private var coverImage: NSImage?
  @State private var coverPNGData: Data?
  @State private var statusMessage: String?

  enum SocialPlatform: String, CaseIterable, Identifiable {
    case xiaohongshu = "小红书"
    case twitter = "Twitter / X"
    case linkedin = "LinkedIn"
    case wechat = "微信公众号"

    var id: String { rawValue }
    var systemImage: String {
      switch self {
      case .xiaohongshu: "text.quote"
      case .twitter: "bubble.left.and.bubble.right"
      case .linkedin: "briefcase"
      case .wechat: "paperplane"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      headerBar
      Divider()

      HStack(spacing: 0) {
        leftPreviewColumn
        Divider()
        rightControlColumn
      }

      Divider()
      footerBar
    }
    .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 620)
    .onAppear {
      generateDefaultCoverPreview()
    }
  }

  private var headerBar: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text("AI 社交媒体卡片与封面生成器")
          .font(.title2.weight(.semibold))
        Text("一键生成适应不同社交平台的推广文案，并合成高清 OpenGraph 文章封面图。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("完成") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(WorkbenchSpacing.page)
  }

  private var leftPreviewColumn: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("动态 OpenGraph 封面图预览 (1200 × 630)")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)

      ZStack {
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(nsColor: .controlBackgroundColor))
          .overlay(
            RoundedRectangle(cornerRadius: 12)
              .stroke(Color.primary.opacity(0.1), lineWidth: 1)
          )

        if let coverImage {
          Image(nsImage: coverImage)
            .resizable()
            .scaledToFit()
            .cornerRadius(10)
            .padding(8)
        } else {
          VStack(spacing: 8) {
            ProgressView()
            Text("正在渲染 OpenGraph 封面...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(height: 230)

      HStack {
        Text("平台推广文案编辑与预览 (\(selectedPlatform.rawValue))")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Spacer()
        Text("可在此直接编辑文案")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }

      ZStack(alignment: .topLeading) {
        RoundedRectangle(cornerRadius: 10)
          .fill(Color(nsColor: .textBackgroundColor))
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.primary.opacity(0.1), lineWidth: 1)
          )

        if isGeneratingText {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("AI 正在针对 \(selectedPlatform.rawValue) 提取核心卖点与撰写文案...")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(14)
        } else {
          TextEditor(text: $generatedText)
            .font(.callout)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity)
  }

  private var rightControlColumn: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("生成参数")
        .font(.headline)

      Picker("目标平台", selection: $selectedPlatform) {
        ForEach(SocialPlatform.allCases) { platform in
          Label(platform.rawValue, systemImage: platform.systemImage).tag(platform)
        }
      }
      .pickerStyle(.segmented)
      .onChange(of: selectedPlatform) { _, _ in
        generateSocialPostText()
      }

      VStack(alignment: .leading, spacing: 10) {
        Button {
          generateSocialPostText()
        } label: {
          Label("用 AI 提炼社交平台文案", systemImage: "sparkles")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isGeneratingText)

        Button {
          generateDefaultCoverPreview()
        } label: {
          Label("刷新 OG 封面图", systemImage: "photo.artframe")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }

      Divider()

      VStack(alignment: .leading, spacing: 8) {
        Text("当前文章信息")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Text("标题：\(draft.title)")
          .font(.caption)
          .lineLimit(2)
        Text("站点：\(profile.name)")
          .font(.caption)
          .foregroundStyle(.secondary)
        if !draft.categories.isEmpty {
          Text("分类：\(draft.categories.joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let statusMessage {
        Text(statusMessage)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.success)
      }

      Spacer()
    }
    .padding(16)
    .frame(width: 280)
  }

  private var footerBar: some View {
    HStack {
      Button("复制文案") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(generatedText, forType: .string)
        statusMessage = "文案已复制到剪贴板"
      }
      .disabled(generatedText.isEmpty)

      Spacer()

      Button("应用封面图至草稿") {
        applyCoverImageToDraft()
      }
      .buttonStyle(.borderedProminent)
      .disabled(coverPNGData == nil)
    }
    .padding(WorkbenchSpacing.page)
  }

  private var defaultPlaceholderText: String {
    "点击“用 AI 提炼社交平台文案”，将根据当前文章自动生成包含核心看点、Emoji 与 Hashtag 的\(selectedPlatform.rawValue)推广文案。"
  }

  private func generateDefaultCoverPreview() {
    let service = OpenGraphCoverGeneratorService()
    let authorName = draft.authors.first ?? profile.defaultAuthor
    let categoryName = draft.categories.first ?? "Blog"
    let dateStr = draft.date.formatted(date: .abbreviated, time: .omitted)

    if let data = service.generateCoverPNGData(
      title: draft.title.isEmpty ? "未命名文章" : draft.title,
      author: authorName,
      category: categoryName,
      dateString: dateStr,
      siteName: profile.name
    ), let nsImage = NSImage(data: data) {
      self.coverPNGData = data
      self.coverImage = nsImage
    }
  }

  private func generateSocialPostText() {
    isGeneratingText = true
    generatedText = ""
    Task {
      let prompt = "请为以下博文生成一段适合在【\(selectedPlatform.rawValue)】发布的宣传推文/笔记，包含吸引人的勾子、简短看点、Emoji 排版和推荐 Hashtag。\n\n标题：\(draft.title)\n正文梗概：\n\(draft.bodyMarkdown.prefix(800))"
      let result = await store.ai.performAction(
        .rewriteSelection,
        draft: draft,
        selectedText: prompt
      )
      await MainActor.run {
        isGeneratingText = false
        if let content = result?.content, !content.isEmpty {
          generatedText = content
        } else {
          generatedText = "【\(draft.title)】\n最近写了一篇新文章，分享了关于相关主题的深入思考与实战经验。欢迎阅读！\n\n#技术分享 #个人博客 #\(selectedPlatform.rawValue)"
        }
      }
    }
  }

  private func applyCoverImageToDraft() {
    guard let coverPNGData else { return }
    let filename = "og-cover-\(draft.id.uuidString.prefix(8)).png"
    do {
      let url = try PastedImageFileStore().storePNG(coverPNGData)
      let relativePath = profile.publicImagePath(filename: filename, draft: draft)
      var updated = draft
      updated.attachments.append(DraftAttachment(
        id: UUID(),
        originalFilename: filename,
        relativePublishPath: relativePath,
        repositoryPath: profile.imageRepositoryPath(filename: filename, draft: draft),
        byteSize: Int64(coverPNGData.count),
        sourceFilePath: url.path
      ))
      store.updateDraft(updated)
      statusMessage = "封面图已关联并生成存储文件"
    } catch {
      statusMessage = "封面保存失败：\(error.localizedDescription)"
    }
  }
}
