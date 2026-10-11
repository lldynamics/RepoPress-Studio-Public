import Combine
import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SelectionEditPreviewPanel: View {
  let preview: AIPublishingSelectionEditPreview
  let onApply: (AIPublishingSelectionEditPreview) -> Void
  let onDiscard: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("\(preview.kind.localizedDisplayName)预览", systemImage: "doc.text.magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(preview.application.localizedDisplayName)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, WorkbenchSpacing.icon)
          .padding(.vertical, 2)
          .background(WorkbenchBackgroundStyle.control, in: Capsule())
        if let modelSummary = preview.modelSummary {
          Text(modelSummary)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, WorkbenchSpacing.icon)
            .padding(.vertical, 2)
            .background(WorkbenchBackgroundStyle.control, in: Capsule())
        }
        Spacer()
        Button {
          onDiscard()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("丢弃预览")
        .accessibilityLabel("丢弃 AI 预览")
      }

      HStack(alignment: .top, spacing: 10) {
        selectionPreviewColumn(
          title: preview.application == .replaceRange ? "原文" : "插入位置",
          text: preview.originalText.nilIfEmpty ?? "将在当前光标位置插入。"
        )
        selectionPreviewColumn(title: "AI 建议", text: preview.trimmedReplacementText)
      }

      HStack {
        Button {
          onApply(preview)
        } label: {
          Label("应用到选区", systemImage: "checkmark.circle")
        }
        .keyboardShortcut(.return, modifiers: [.command])

        Button {
          onDiscard()
        } label: {
          Label("丢弃", systemImage: "xmark.circle")
        }

        Spacer()
      }
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: 720)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
  }

  private func selectionPreviewColumn(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ScrollView {
        Text(text)
          .font(.caption)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 150)
      .padding(WorkbenchSpacing.control)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MarkdownShortcutHelpPanel: View {
  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var shortcutGroups: [(String, [(String, String)])] {
    var groups: [(String, [(String, String)])] = [
      (
        String(localized: "工作区与窗口"),
        moduleVisibility.primarySections.map {
          (WorkspaceNavigationRouteDescriptor.title(for: $0), $0.keyboardShortcutLabel)
        } + [
          (String(localized: "命令面板与快速打开"), "⇧⌘K"),
          (String(localized: "任务中心"), "⌥⌘L"),
          (String(localized: "搜索文章"), "⌥⌘F"),
          (String(localized: "专注模式"), "⇧⌘F"),
          (String(localized: "显示或隐藏侧栏"), "⌃⌘S"),
          (String(localized: "显示或隐藏详情栏"), "⌥⌘I"),
          (String(localized: "发布所有变更"), "⌥⌘P"),
          (String(localized: "查看快捷键说明"), "⌥⌘/"),
        ]
      ),
      (
        String(localized: "焦点导航"),
        [
          (String(localized: "移到下一个控件"), "⌃⇥"),
          (String(localized: "移到上一个控件"), "⌃⇧⇥"),
        ]
      ),
      (
        String(localized: "编辑"),
        [
          (String(localized: "查找"), "⌘F"),
          (String(localized: "查找下一个"), "⌘G"),
          (String(localized: "查找上一个"), "⇧⌘G"),
          (String(localized: "查找栏下一个 / 上一个"), "↩ / ⇧↩"),
          (String(localized: "关闭查找栏"), "Esc"),
          (String(localized: "替换当前"), String(localized: "查找栏“替换”")),
          (String(localized: "全部替换"), "⌥⌘E"),
          (String(localized: "插入图片"), "⇧⌘I"),
          (String(localized: "模板与片段"), "⌥⌘S"),
          (String(localized: "文章大纲"), "⌥⌘O"),
          (String(localized: "文章版本历史"), "⌃⌥⌘H"),
          (String(localized: "跳转到行"), "⌘L"),
          (String(localized: "文章后退"), "⌘["),
          (String(localized: "文章前进"), "⌘]"),
          (String(localized: "粘贴 URL 为链接"), String(localized: "选中文字后按 ⌘V")),
          (String(localized: "粘贴截图"), "⌘V"),
        ]
      ),
      (
        String(localized: "Markdown 智能编辑"),
        [
          (String(localized: "加粗"), "⌘B"),
          (String(localized: "斜体"), "⌘I"),
          (String(localized: "插入链接"), "⌘K"),
          (String(localized: "一级标题"), "⌥⌘1"),
          (String(localized: "二级标题"), "⌥⌘2"),
          (String(localized: "三级标题"), "⌥⌘3"),
          (String(localized: "续写列表或引用"), "Return"),
          (String(localized: "退出空列表项"), String(localized: "空项再按 Return")),
          (String(localized: "增加列表层级"), "⇥"),
          (String(localized: "减少列表层级"), "⇧⇥"),
          (String(localized: "表格、代码、图片、脚注补全"), "/表格、/代码、/图片、/脚注"),
          (String(localized: "文章链接补全"), "[[文章]]"),
          (String(localized: "代码语言补全"), "```swift"),
        ]
      ),
    ]
    groups.append(
      (
        String(localized: "AI 与工具"),
        [
          (String(localized: "请求 AI 续写"), "⌥\\"),
          (String(localized: "采纳 AI 续写"), "⇥"),
          (String(localized: "丢弃 AI 续写"), "Esc"),
          (String(localized: "改写选中文本"), "⌥⌘R"),
          (String(localized: "打开 AI 助手"), String(localized: "AI > 打开 AI 助手")),
          (String(localized: "复制上下文 Prompt"), String(localized: "AI > 复制上下文 Prompt")),
        ]
      )
    )
    groups.append(
      (
        String(localized: "RSS 阅读"),
        [
          (String(localized: "上一条 RSS 文章"), "⌃⌘←"),
          (String(localized: "下一条 RSS 文章"), "⌃⌘→"),
          (String(localized: "收藏/取消收藏 RSS 文章"), "⌃⌘B"),
        ]
      )
    )
    return groups
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("搜索命令或按键", text: $searchText)
            .textFieldStyle(.plain)
            .accessibilityLabel("搜索命令或按键")
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("清除快捷键搜索")
          }
        }
        .padding(WorkbenchSpacing.card)

        Divider()

        if filteredShortcutGroups.isEmpty {
          ContentUnavailableView.search(text: searchText)
        } else {
          Form {
            ForEach(filteredShortcutGroups.indices, id: \.self) { groupIndex in
              let group = filteredShortcutGroups[groupIndex]
              Section(group.0) {
                ForEach(group.1.indices, id: \.self) { row in
                  let shortcut = group.1[row]
                  HStack {
                    Text(shortcut.0)
                      .font(.body)
                    Spacer()
                    Text(shortcut.1)
                      .font(.body.monospacedDigit())
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
          .formStyle(.grouped)
        }
      }
      .navigationTitle("快捷键说明")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("关闭") {
            dismiss()
          }
        }
      }
    }
    .frame(width: 430, height: 360)
  }

  private var filteredShortcutGroups: [(String, [(String, String)])] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return shortcutGroups }
    return shortcutGroups.compactMap { group in
      let rows = group.1.filter {
        group.0.localizedCaseInsensitiveContains(query)
          || $0.0.localizedCaseInsensitiveContains(query)
          || $0.1.localizedCaseInsensitiveContains(query)
      }
      return rows.isEmpty ? nil : (group.0, rows)
    }
  }
}

/// Keeps persistence-state invalidation inside the title area instead of
/// rebuilding and remeasuring the complete adaptive toolbar.
struct MacMarkdownEditorTitleArea: View {
  @Binding var title: String
  let focusRequestID: UUID?
  let draftID: UUID
  let markdownPath: String
  let articleInformationToggle: MacMarkdownArticleInformationToggle?
  @StateObject private var metadata: MarkdownArticleHeaderMetadataState
  @StateObject private var saveStatus: WorkbenchMarkdownEditorSaveStatusFeatureFacade

  @FocusState private var isTitleFocused: Bool

  init(
    title: Binding<String>,
    focusRequestID: UUID?,
    store: WorkbenchStore,
    draftID: UUID,
    markdownPath: String,
    articleInformationToggle: MacMarkdownArticleInformationToggle?
  ) {
    _title = title
    self.focusRequestID = focusRequestID
    self.draftID = draftID
    self.markdownPath = markdownPath
    self.articleInformationToggle = articleInformationToggle
    _metadata = StateObject(
      wrappedValue: MarkdownArticleHeaderMetadataState(store: store, draftID: draftID)
    )
    _saveStatus = StateObject(
      wrappedValue: WorkbenchMarkdownEditorSaveStatusFeatureFacade(
        store: store,
        draftID: draftID
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      TextField(
        "文章标题",
        text: Binding(
          get: { title },
          set: { value in
            // The field may wrap visually, while article metadata remains a single title.
            title = value.replacingOccurrences(of: "\r\n", with: " ")
              .replacingOccurrences(of: "\n", with: " ")
              .replacingOccurrences(of: "\r", with: " ")
          }
        ),
        prompt: Text("未命名文章").italic().foregroundColor(.secondary),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .labelsHidden()
      .focused($isTitleFocused)
      .onChange(of: focusRequestID) { _, requestID in
        if requestID != nil { isTitleFocused = true }
      }
      .font(.title2.weight(.semibold))
      // Unsaved state is shown by the save-status control; recoloring the
      // title duplicated it and made the heading flicker while typing.
      .accessibilityLabel("文章标题")
      .accessibilityIdentifier("markdown-article-title")
      .accessibilityValue(title.nilIfEmpty ?? String(localized: "未命名文章"))
      .lineLimit(1...3)
      .help(title.nilIfEmpty ?? String(localized: "未命名文章"))

      HStack(spacing: WorkbenchSpacing.control) {
        Label(metadata.value.statusTitle, systemImage: metadata.value.status.systemImage)
          .font(.workbenchMetadata)
          .foregroundStyle(metadata.value.statusColor)
          .padding(.horizontal, WorkbenchSpacing.tight)
          .padding(.vertical, 2)
          .background(
            WorkbenchBackgroundStyle.control,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.badge)
          )
          .fixedSize()
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("文章状态")
          .accessibilityValue(metadata.value.statusTitle)
          .accessibilityIdentifier("markdown-article-status")
        if let path = metadata.value.relativePath {
          InteractiveBreadcrumbView(markdownPath: path, fileURL: metadata.value.fileURL)
        } else {
          Text("未绑定站点")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if let articleInformationToggle {
          articleInformationToggle
            .fixedSize()
        }
      }

      if let failure = saveStatus.saveFailure {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Label(
            failure.scope == .project ? String(localized: "项目保存失败") : String(localized: "保存到软件失败"),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)

          Text(failure.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(failure.message)

          if failure.canRetry {
            Button("重试") {
              saveStatus.retrySave()
            }
            .controlSize(.small)
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-editor-save-failure")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: draftID) { _, updatedDraftID in
      metadata.trackDraft(updatedDraftID)
      saveStatus.trackDraft(updatedDraftID)
    }
  }
}

/// A value projection keeps body edits and unrelated articles from invalidating
/// the header. Paths are derived from the article's owner, not the active site.
struct MarkdownArticleHeaderMetadata: Equatable {
  let status: DraftStatus
  let articleState: ArticleState
  let isGeneralDraft: Bool
  let relativePath: String?
  let fileURL: URL?

  init(draft: ArticleDraft?, profile: SiteProfile?, externalFolder: URL? = nil) {
    status = draft?.status ?? .draft
    articleState = draft?.articleState ?? .localOnly
    isGeneralDraft = draft?.isGeneralDraft ?? true
    if let source = draft?.externalDraftSource {
      relativePath = source.relativePath
      let folder =
        externalFolder
        ?? source.detachedFolderPath.map {
          URL(fileURLWithPath: $0, isDirectory: true)
        }
      fileURL = Self.fileURL(for: source.relativePath, under: folder)
    } else if let draft, !draft.isGeneralDraft, let profile, profile.id == draft.siteProfileID {
      relativePath = draft.repositoryPath?.nilIfEmpty ?? profile.markdownPath(for: draft)
      // An unbound article only has a proposed path; Finder must not pretend
      // it is already saved to a file in the repository.
      fileURL = draft.repositoryPath.flatMap {
        Self.fileURL(for: $0, under: profile.localRepositoryRootURL)
      }
    } else {
      relativePath = nil
      fileURL = nil
    }
  }

  var statusTitle: String {
    articleState.workbenchLocalizedDisplayName
  }

  var statusColor: Color {
    switch articleState {
    case .draft: WorkbenchTheme.neutral
    case .ready: WorkbenchTheme.info
    case .published: WorkbenchTheme.success
    case .localOnly: WorkbenchTheme.neutral
    }
  }

  private static func fileURL(for relativePath: String, under folder: URL?) -> URL? {
    guard let folder, !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
    let root = folder.standardizedFileURL
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    guard candidate.path.hasPrefix(root.path + "/") else { return nil }
    return candidate
  }
}

@MainActor
final class MarkdownArticleHeaderMetadataState: ObservableObject {
  @Published private(set) var value: MarkdownArticleHeaderMetadata
  private unowned let store: WorkbenchStore
  private var draftID: UUID
  private var cancellables = Set<AnyCancellable>()

  init(store: WorkbenchStore, draftID: UUID) {
    self.store = store
    self.draftID = draftID
    value = Self.project(store: store, draftID: draftID)
    // Observe public revision/profile signals, not the broad root store.
    // The editor metadata facade omits external-source-only changes and
    // general drafts can belong to a folder on an inactive site.
    store.$draftMutationRevision.map { _ in () }
      .merge(with: store.publishStatus.objectWillChange.map { _ in () })
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self else { return }
        let updated = Self.project(store: self.store, draftID: self.draftID)
        guard self.value != updated else { return }
        self.value = updated
      }
      .store(in: &cancellables)
  }

  func trackDraft(_ draftID: UUID) {
    guard self.draftID != draftID else { return }
    self.draftID = draftID
    value = Self.project(store: store, draftID: draftID)
  }

  private static func project(store: WorkbenchStore, draftID: UUID) -> MarkdownArticleHeaderMetadata
  {
    project(drafts: store.drafts, profiles: store.profiles, draftID: draftID)
  }

  private static func project(drafts: [ArticleDraft], profiles: [SiteProfile], draftID: UUID?)
    -> MarkdownArticleHeaderMetadata
  {
    let draft = drafts.first { $0.id == draftID }
    let profile = profiles.first { $0.id == draft?.siteProfileID }
    let mapping = profiles.compactMap(\.externalDraftFolder).first {
      $0.id == draft?.externalDraftSource?.mappingID
    }
    return MarkdownArticleHeaderMetadata(
      draft: draft, profile: profile, externalFolder: mapping?.directoryURL
    )
  }
}

struct MacMarkdownPublishAssetPickerPopover: View {
  @Binding var selectedAssets: Set<AIPublishingAssetKind>
  let isGenerationEnabled: Bool
  let onGenerate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("选择发布资产")
          .font(.headline)
        Text("勾选后一次生成所选资产。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(AIPublishingAssetKind.allCases) { asset in
            Toggle(asset.localizedDisplayName, isOn: selectionBinding(for: asset))
          }
        }
      }
      .frame(maxHeight: 280)

      HStack {
        Text("已选择 \(selectedAssets.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("生成所选资产") {
          onGenerate()
        }
        .workbenchProminentActionStyle()
        .disabled(selectedAssets.isEmpty || !isGenerationEnabled)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(WorkbenchSpacing.content)
    .frame(width: 320, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("选择发布资产")
    .accessibilityIdentifier("ai-publish-asset-picker")
  }

  private func selectionBinding(for asset: AIPublishingAssetKind) -> Binding<Bool> {
    Binding(
      get: { selectedAssets.contains(asset) },
      set: { isSelected in
        if isSelected {
          selectedAssets.insert(asset)
        } else {
          selectedAssets.remove(asset)
        }
      }
    )
  }
}

extension MacMarkdownEditorToolbar {
  func selectionAIActionButton(
    _ capability: AIPublishingDefaultCapability,
    kind: AIPublishingActionKind
  ) -> some View {
    let availability = actions.selectionAvailability(for: kind)
    return Button {
      actions.onPerformSelectionAIAction(kind)
    } label: {
      Label(
        capability == .translate ? kind.localizedDisplayName : capability.localizedDisplayName,
        systemImage: capability.systemImage
      )
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? capability.localizedDisplayName)
  }
}
