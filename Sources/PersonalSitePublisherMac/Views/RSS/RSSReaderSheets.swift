import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct RSSHighlightEditorSheet: View {
  let text: String
  let initialNote: String
  let initialTags: [String]
  let onSave: (String, [String]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var note: String
  @State private var tagsText: String

  init(
    text: String,
    initialNote: String = "",
    initialTags: [String] = [],
    onSave: @escaping (String, [String]) -> Void
  ) {
    self.text = text
    self.initialNote = initialNote
    self.initialTags = initialTags
    self.onSave = onSave
    _note = State(initialValue: initialNote)
    _tagsText = State(initialValue: initialTags.joined(separator: ", "))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("保存高亮与批注", systemImage: "highlighter")
          .font(.headline)
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
      }

      Text("高亮文字")
        .font(.subheadline.weight(.semibold))
      ScrollView {
        Text(text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(minHeight: 70, maxHeight: 150)
      .padding(10)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

      Text("批注（可选）")
        .font(.subheadline.weight(.semibold))
      TextEditor(text: $note)
        .font(.body)
        .frame(minHeight: 110)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .accessibilityLabel("高亮批注")

      TextField("标签，用逗号分隔（可选）", text: $tagsText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("高亮标签")

      HStack {
        Spacer()
        Button("保存", action: save)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 520)
    .onAppear {
      // Keep the editor fully keyboard reachable without stealing focus from
      // the selected text or the user's current navigation context.
    }
  }

  private func save() {
    let tags = tagsText
      .split { $0 == "," || $0 == "，" || $0 == "、" }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    onSave(note.trimmingCharacters(in: .whitespacesAndNewlines), tags)
  }
}

struct RSSArticleTagsSheet: View {
  let article: RSSArticle
  let onSave: ([String]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var tagsText: String

  init(article: RSSArticle, onSave: @escaping ([String]) -> Void) {
    self.article = article
    self.onSave = onSave
    _tagsText = State(initialValue: article.tags.joined(separator: ", "))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("编辑文章标签", systemImage: "tag")
          .font(.headline)
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
      }
      Text(article.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
      TextField("标签，用逗号分隔", text: $tagsText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("文章标签")
      HStack {
        Text("标签用于后续检索与资料整理。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("保存") {
          onSave(
            tagsText
              .split { $0 == "," || $0 == "，" || $0 == "、" }
              .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
              .filter { !$0.isEmpty }
          )
          dismiss()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 430)
  }
}

struct RSSReaderEmptyState: View {
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  let systemImage: String

  var body: some View {
    EmptyStateView(
      title: title,
      message: message,
      systemImage: systemImage,
      density: .fullPage
    )
  }
}

struct RSSReaderWelcomeView: View {
  let onAdd: () -> Void
  let onDiscover: (String) -> Void
  @State private var homepageURL = ""

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "dot.radiowaves.left.and.right")
        .font(.system(size: 42))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
      Text("开始阅读")
        .font(.largeTitle.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      Text("把阅读、资料和写作连接起来。订阅内容只保存在本机，不会因为阅读而上传到第三方服务。")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)

      HStack(spacing: 10) {
        Button("添加第一个订阅", action: onAdd)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("也可以粘贴博客首页，自动发现 RSS / Atom")
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          TextField("https://example.com", text: $homepageURL)
            .textFieldStyle(.roundedBorder)
            .textContentType(.URL)
            .onSubmit(submitDiscovery)
            .accessibilityLabel("博客首页或 RSS 地址")
          Button("发现并订阅", action: submitDiscovery)
            .buttonStyle(.bordered)
            .disabled(homepageURL.trimmedForPublishing.isEmpty)
        }
      }
      .frame(maxWidth: 560)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("rss-reader-welcome")
  }

  private func submitDiscovery() {
    let value = homepageURL.trimmedForPublishing
    guard !value.isEmpty else { return }
    onDiscover(value)
  }
}

struct RSSEditFeedURLSheet: View {
  @Environment(\.dismiss) private var dismiss
  let feed: RSSFeed
  let onSave: (URL) throws -> Void
  @State private var value: String
  @State private var errorMessage: String?

  init(feed: RSSFeed, onSave: @escaping (URL) throws -> Void) {
    self.feed = feed
    self.onSave = onSave
    _value = State(initialValue: feed.url.absoluteString)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("修改订阅地址")
        .font(.title2.weight(.semibold))
      Text(feed.displayTitle)
        .font(.headline)
        .lineLimit(2)
      Text("修改后会保留这个订阅的本地文章、已读状态、稍后阅读状态、标签和高亮，然后使用新地址重新刷新。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      TextField("https://example.com/feed.xml", text: $value)
        .textFieldStyle(.roundedBorder)
        .textContentType(.URL)
        .accessibilityLabel("新的 RSS 或 Atom 订阅地址")
        .onSubmit(save)

      if let errorMessage {
        Text(errorMessage)
          .font(.callout)
          .foregroundStyle(WorkbenchTheme.risk)
          .textSelection(.enabled)
          .accessibilityLabel("地址修改失败：\(errorMessage)")
      }

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存并重试", action: save)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.defaultAction)
          .disabled(value.trimmedForPublishing.isEmpty)
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(minWidth: 520)
  }

  private func save() {
    let normalized = value.trimmedForPublishing
    guard let url = URL(string: normalized) else {
      errorMessage = RSSReaderError.invalidFeedURL.localizedDescription
      return
    }
    do {
      try onSave(url)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct RSSExcerptNoteSheet: View {
  @Environment(\.dismiss) private var dismiss
  let article: RSSArticle
  let onSave: (String, String) -> Void
  @State private var excerpt: String
  @State private var note = ""

  init(article: RSSArticle, onSave: @escaping (String, String) -> Void) {
    self.article = article
    self.onSave = onSave
    _excerpt = State(initialValue: RSSArticleWorkflow.excerpt(for: article))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("摘录并添加笔记")
        .font(.title2.weight(.semibold))
      Text(article.title)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)
      Text("摘录会限制在安全长度内保存；你可以删减后再添加自己的笔记。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("摘录")
        .font(.subheadline.weight(.semibold))
      TextEditor(text: $excerpt)
        .font(.body)
        .frame(minHeight: 150)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .accessibilityLabel("要保存的文章摘录")
      Text("笔记")
        .font(.subheadline.weight(.semibold))
      TextEditor(text: $note)
        .font(.body)
        .frame(minHeight: 100)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .accessibilityLabel("关于这段摘录的笔记")

      HStack {
        Spacer()
        Button("取消", action: dismiss.callAsFunction)
          .keyboardShortcut(.cancelAction)
        Button("保存摘录和笔记") {
          onSave(excerpt, note)
          dismiss()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(
          excerpt.trimmedForPublishing.isEmpty || note.trimmedForPublishing.isEmpty
        )
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(minWidth: 560, minHeight: 520)
  }
}

struct RSSAddSubscriptionView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var value = ""
  let onAdd: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("添加 RSS 订阅")
        .font(.title2.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
      Text("输入 RSS / Atom 地址，或粘贴博客首页自动发现。文章会缓存到本机，默认不会上传到第三方服务。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      TextField("https://example.com", text: $value)
        .textFieldStyle(.roundedBorder)
        .textContentType(.URL)
        .accessibilityLabel("RSS / Atom 地址或博客首页")
        .onSubmit {
          submit()
        }

      HStack {
        Spacer()
        Button("取消") {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button("发现并添加") {
          submit()
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(value.trimmedForPublishing.isEmpty)
        .accessibilityLabel("发现 RSS / Atom 并添加")
      }
    }
    .padding(WorkbenchSpacing.spacious)
    .frame(minWidth: 500)
  }

  private func submit() {
    guard !value.trimmedForPublishing.isEmpty else { return }
    onAdd(value)
  }
}
