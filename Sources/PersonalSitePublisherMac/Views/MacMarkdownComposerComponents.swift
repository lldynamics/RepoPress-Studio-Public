import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
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

struct SelectionActionBar: View {
  let isSelectionAIActionRunning: Bool
  let activeSelectionActionName: String?
  let hasLatestAssistantMessage: Bool
  let selectionActionMessage: String
  let onSelectSelectionAction: (AIPublishingActionKind) -> Void
  let onSelectConvergedSelectionAction: (AIPublishingActionConvergence) -> Void
  let onApplyLatestAIReply: () -> Void
  let onInsertImages: () -> Void
  let onCheckSelectedPublicRisk: () -> Void
  let onOpenAITemplateLibrary: () -> Void
  let availabilityForSelectionAction: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 4) {
        Image(systemName: "sparkles")
          .font(.workbenchMetadata)
          .foregroundStyle(Color.accentColor)
        Text("AI 选区魔法")
          .font(.caption.weight(.semibold))
      }

      Menu {
        convergedRewriteActions

        Menu {
          selectionActionButton(.translate, kind: .translateSelectionToChinese)
          selectionActionButton(.translate, kind: .translateSelectionToEnglish)
        } label: {
          Label(
            AIPublishingDefaultCapability.translate.localizedDisplayName,
            systemImage: AIPublishingDefaultCapability.translate.systemImage
          )
        }

        Divider()

        Button {
          onOpenAITemplateLibrary()
        } label: {
          Label("搜索模板库…", systemImage: "magnifyingglass")
        }
      } label: {
        Label(activeSelectionActionName ?? "✨ 改写选区", systemImage: "sparkles")
      }
      .disabled(isSelectionAIActionRunning)

      Button {
        onApplyLatestAIReply()
      } label: {
        Label("应用 AI 回复", systemImage: "text.badge.checkmark")
      }
      .disabled(!hasLatestAssistantMessage)

      Button {
        onInsertImages()
      } label: {
        Label("插图", systemImage: "photo.badge.plus")
      }

      Button {
        onCheckSelectedPublicRisk()
      } label: {
        Label("公开风险", systemImage: "lock.shield")
      }

      if !selectionActionMessage.isEmpty {
        Text(selectionActionMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
  }

  private func selectionActionButton(
    _ capability: AIPublishingDefaultCapability,
    kind: AIPublishingActionKind
  ) -> some View {
    let availability = availabilityForSelectionAction(kind)
    return Button {
      onSelectSelectionAction(kind)
    } label: {
      Label(
        capability == .translate ? kind.localizedDisplayName : capability.localizedDisplayName,
        systemImage: capability.systemImage
      )
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? capability.localizedDisplayName)
  }

  @ViewBuilder
  private var convergedRewriteActions: some View {
    Section("风格") {
      ForEach(AIPublishingRewriteStyle.allCases) { style in
        Button {
          onSelectConvergedSelectionAction(
            .rewriteSelection(AIPublishingRewriteConfiguration(style: style))
          )
        } label: {
          Label(style.displayName, systemImage: "wand.and.stars")
        }
        .disabled(!availabilityForSelectionAction(.rewriteSelection).isEnabled)
      }
    }
    Section("处理") {
      ForEach(AIPublishingRewriteOperation.allCases.filter { $0 != .rewrite }) { operation in
        Button {
          onSelectConvergedSelectionAction(
            .rewriteSelection(AIPublishingRewriteConfiguration(operation: operation))
          )
        } label: {
          Label(operation.displayName, systemImage: "wand.and.stars")
        }
        .disabled(!availabilityForSelectionAction(.rewriteSelection).isEnabled)
      }
    }
  }
}

struct FindReplaceBar: View {
  @Binding var findQuery: String
  @Binding var replacementText: String
  @Binding var isFindCaseSensitive: Bool
  @Binding var isFindWholeWord: Bool
  @Binding var isFindRegularExpression: Bool

  let canUseFindReplace: Bool
  let findMatchStatus: String
  let findReplaceMessage: String
  let onFindPrevious: () -> Void
  let onFindNext: () -> Void
  let onReplaceCurrentOrNext: () -> Void
  let onReplaceAll: () -> Void
  let onDismiss: () -> Void

  @FocusState private var isFindFieldFocused: Bool

  var body: some View {
    ViewThatFits(in: .horizontal) {
      wideLayout
      compactLayout
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(.bar)
    .onAppear {
      isFindFieldFocused = true
    }
    .onKeyPress(.return) {
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        onFindPrevious()
      } else {
        onFindNext()
      }
      return .handled
    }
    .onExitCommand(perform: onDismiss)
  }

  private var wideLayout: some View {
    HStack(spacing: 8) {
      findField(maxWidth: 170)
      replacementField(maxWidth: 170)
      findControls
      replaceControls

      if !findReplaceMessage.isEmpty {
        Text(findReplaceMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()
      dismissButton
    }
  }

  private var compactLayout: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        findField(maxWidth: .infinity)
        replacementField(maxWidth: .infinity)
        dismissButton
      }

      HStack(spacing: 8) {
        findControls
        replaceControls
        if !findReplaceMessage.isEmpty {
          Text(findReplaceMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func findField(maxWidth: CGFloat) -> some View {
    TextField("查找", text: $findQuery)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 100, idealWidth: 170, maxWidth: maxWidth)
      .focused($isFindFieldFocused)
      .accessibilityLabel("查找文本")
      .accessibilityValue(findQuery.nilIfEmpty ?? String(localized: "未输入"))
  }

  private func replacementField(maxWidth: CGFloat) -> some View {
    TextField("替换为", text: $replacementText)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 100, idealWidth: 170, maxWidth: maxWidth)
      .accessibilityLabel("替换文本")
      .accessibilityValue(replacementText.nilIfEmpty ?? String(localized: "未输入"))
  }

  private var findControls: some View {
    HStack(spacing: 4) {
      Text(findMatchStatus)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 38)
        .accessibilityLabel("查找匹配位置")
        .accessibilityValue(findMatchStatus)

      Button {
        onFindPrevious()
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(!canUseFindReplace)
      .help(String(localized: "查找上一个（Shift+Return）"))
      .accessibilityLabel("查找上一个")

      Button {
        onFindNext()
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(!canUseFindReplace)
      .help(String(localized: "查找下一个（Return）"))
      .accessibilityLabel("查找下一个")

      Menu {
        Toggle("区分大小写", isOn: $isFindCaseSensitive)
        Toggle("整词匹配", isOn: $isFindWholeWord)
        Toggle("正则表达式", isOn: $isFindRegularExpression)
      } label: {
        Image(systemName: "slider.horizontal.3")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help(String(localized: "查找模式"))
      .accessibilityLabel("查找模式")
    }
    .fixedSize()
  }

  private var replaceControls: some View {
    HStack(spacing: 6) {
      Button {
        onReplaceCurrentOrNext()
      } label: {
        Label("替换", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(!canUseFindReplace)
      .accessibilityLabel("替换当前匹配")

      Button {
        onReplaceAll()
      } label: {
        Label("全部替换", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(!canUseFindReplace)
      .accessibilityLabel("全部替换")
    }
    .fixedSize()
  }

  private var dismissButton: some View {
    Button {
      onDismiss()
    } label: {
      Image(systemName: "xmark")
    }
    .buttonStyle(.borderless)
    .help(String(localized: "关闭查找替换"))
    .accessibilityLabel("关闭查找替换")
  }
}

struct MarkdownPreviewPane: View {
  let draft: ArticleDraft
  let profile: SiteProfile
  let showsSynchronizedScrollingControl: Bool
  @Binding var isSynchronizedScrollingEnabled: Bool
  let scrollSyncUpdate: MarkdownScrollSyncUpdate?
  let scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  let onScrollProgressChanged: (Double) -> Void
  let onSourceLocationSelected: (Int) -> Void
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("markdownEditorPreviewTheme") private var previewThemeRaw = MarkdownPreviewTheme.system.rawValue
  @State private var htmlDocument = ""
  @State private var assetResources: [MarkdownPreviewAssetResource] = []
  @State private var renderID: UUID?
  @State private var renderTask: Task<Void, Never>?
  @State private var renderGeneration: UInt64 = 0
  @State private var isRendering = false
  @State private var renderErrorMessage: String?
  @State private var siteStyleSourcePaths: [String] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Label("预览", systemImage: "doc.richtext")
          .font(.callout.weight(.semibold))

        if isRendering {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在更新文章预览")
        }

        Spacer()

        if showsSynchronizedScrollingControl {
          ViewThatFits(in: .horizontal) {
            synchronizedScrollingToggle(showsLabel: true)
              .fixedSize()
            synchronizedScrollingToggle(showsLabel: false)
              .fixedSize()
          }
        }

        if previewTheme == .site {
          if siteStyleSourcePaths.isEmpty {
            Label("未找到站点 CSS", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Label(
              String(localized: "\(siteStyleSourcePaths.count) 个站点样式"),
              systemImage: "paintbrush"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(siteStyleSourcePaths.joined(separator: "\n"))
          }
        }

        Picker("预览主题", selection: previewThemeBinding) {
          ForEach(MarkdownPreviewTheme.allCases) { theme in
            Text(theme.title).tag(theme)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("预览主题")
        .accessibilityValue(previewThemeBinding.wrappedValue.title)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)

      Divider()

      previewContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityLabel(String(localized: "文章预览：\(draft.title)"))
    .onAppear {
      scheduleHTMLRender(immediate: true)
    }
    .onChange(of: previewRenderInput) { _, _ in
      scheduleHTMLRender()
    }
    .onDisappear {
      renderTask?.cancel()
      renderTask = nil
    }
  }

  private func synchronizedScrollingToggle(showsLabel: Bool) -> some View {
    Toggle(isOn: $isSynchronizedScrollingEnabled) {
      if showsLabel {
        Label("同步滚动", systemImage: "arrow.up.and.down.text.horizontal")
      } else {
        Image(systemName: "arrow.up.and.down.text.horizontal")
      }
    }
    .toggleStyle(.button)
    .help(
      isSynchronizedScrollingEnabled
        ? String(localized: "关闭编辑与预览同步滚动")
        : String(localized: "开启编辑与预览同步滚动")
    )
    .accessibilityLabel("编辑与预览同步滚动")
    .accessibilityValue(
      isSynchronizedScrollingEnabled ? String(localized: "开启") : String(localized: "关闭")
    )
  }

  private var previewTheme: MarkdownPreviewTheme {
    MarkdownPreviewTheme(rawValue: previewThemeRaw) ?? .system
  }

  private var previewThemeBinding: Binding<MarkdownPreviewTheme> {
    Binding(
      get: { previewTheme },
      set: { previewThemeRaw = $0.rawValue }
    )
  }

  private var previewRenderInput: MarkdownPreviewRenderInput {
    MarkdownPreviewRenderInput(
      title: draft.title.trimmedForPublishing.nilIfEmpty ?? String(localized: "未命名文章"),
      markdown: draft.bodyMarkdown,
      attachments: draft.attachments,
      profile: profile,
      theme: previewTheme,
      isDarkAppearance: colorScheme == .dark
    )
  }

  @ViewBuilder
  private var previewContent: some View {
    if htmlDocument.isEmpty {
      if isRendering {
        VStack(spacing: 10) {
          ProgressView()
          Text("正在生成预览…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在生成文章预览")
      } else if let renderErrorMessage {
        previewFailure(message: renderErrorMessage, fillsAvailableSpace: true)
      } else {
        EmptyStateView(
          title: "预览尚未生成",
          message: "正文发生变化后会自动重新生成，也可以手动重试。",
          systemImage: "doc.richtext",
          density: .inline,
          actionTitle: "生成预览",
          actionSystemImage: "arrow.clockwise",
          action: { scheduleHTMLRender(immediate: true) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    } else {
      VStack(spacing: 0) {
        if let renderErrorMessage {
          previewFailure(message: renderErrorMessage, fillsAvailableSpace: false)
          Divider()
        }
        MarkdownPreviewWebView(
          html: htmlDocument,
          renderID: renderID,
          assetResources: assetResources,
          scrollSyncUpdate: isSynchronizedScrollingEnabled ? scrollSyncUpdate : nil,
          scrollRestorationUpdate: scrollRestorationUpdate,
          onScrollProgressChanged: onScrollProgressChanged,
          onSourceLocationSelected: onSourceLocationSelected
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func previewFailure(message: String, fillsAvailableSpace: Bool) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(WorkbenchTheme.risk)
      VStack(alignment: .leading, spacing: 3) {
        Text("预览生成失败")
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("重试") {
        scheduleHTMLRender(immediate: true)
      }
      .disabled(isRendering)
    }
    .padding(12)
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableSpace ? .infinity : nil,
      alignment: fillsAvailableSpace ? .center : .topLeading
    )
    .background(WorkbenchTheme.risk.opacity(WorkbenchOpacity.warningBackground))
  }

  private func scheduleHTMLRender(immediate: Bool = false) {
    renderTask?.cancel()
    renderGeneration &+= 1
    let generation = renderGeneration
    let input = previewRenderInput
    isRendering = true
    renderErrorMessage = nil

    renderTask = Task { @MainActor in
      defer {
        if renderGeneration == generation {
          renderTask = nil
          isRendering = false
        }
      }
      if !immediate {
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return
        }
      }
      guard !Task.isCancelled else { return }
      do {
        let snapshot = try await MarkdownPreviewRenderEngine.shared.render(input)
        guard !Task.isCancelled, renderGeneration == generation else { return }
        renderID = snapshot.id
        assetResources = snapshot.assetResources
        htmlDocument = snapshot.html
        siteStyleSourcePaths = snapshot.siteStyleSourcePaths
        renderErrorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        guard renderGeneration == generation else { return }
        renderErrorMessage = error.localizedDescription
      }
    }
  }
}

private struct MarkdownPreviewRenderInput: Hashable, Sendable {
  let title: String
  let markdown: String
  let attachments: [DraftAttachment]
  let profile: SiteProfile
  let theme: MarkdownPreviewTheme
  let isDarkAppearance: Bool
}

private struct MarkdownPreviewRenderCacheKey: Hashable, Sendable {
  let input: MarkdownPreviewRenderInput
  let assetResources: [MarkdownPreviewAssetResource]
  let siteStylesheet: SitePreviewStylesheet?
}

private struct MarkdownPreviewRenderSnapshot: Sendable {
  let id: UUID
  let html: String
  let assetResources: [MarkdownPreviewAssetResource]
  let siteStyleSourcePaths: [String]
}

private actor MarkdownPreviewRenderEngine {
  static let shared = MarkdownPreviewRenderEngine()
  private var cache = MarkdownPreviewRenderCache<
    MarkdownPreviewRenderCacheKey,
    MarkdownPreviewRenderSnapshot
  >(capacity: 4)

  func render(_ input: MarkdownPreviewRenderInput) throws -> MarkdownPreviewRenderSnapshot {
    try Task.checkCancellation()
    let resources = MarkdownPreviewAssetResource.resources(for: input.attachments)
    let siteStylesheet = input.theme == .site
      ? SitePreviewStyleService.load(for: input.profile)
      : nil
    let cacheKey = MarkdownPreviewRenderCacheKey(
      input: input,
      assetResources: resources,
      siteStylesheet: siteStylesheet
    )
    if let cachedSnapshot = cache.snapshot(for: cacheKey) {
      return cachedSnapshot
    }

    try Task.checkCancellation()
    let html = try MarkdownPreviewHTMLRenderer.document(
      title: input.title,
      markdown: input.markdown,
      attachments: input.attachments,
      previewURLByAttachmentID: Dictionary(
        uniqueKeysWithValues: resources.map { ($0.attachmentID, $0.previewURLString) }
      ),
      theme: input.theme,
      isDarkAppearance: input.isDarkAppearance,
      siteStylesheet: siteStylesheet
    )
    try Task.checkCancellation()
    let snapshot = MarkdownPreviewRenderSnapshot(
      id: UUID(),
      html: html,
      assetResources: resources,
      siteStyleSourcePaths: siteStylesheet?.sourcePaths ?? []
    )
    cache.insert(snapshot, for: cacheKey)
    return snapshot
  }
}

private enum MarkdownPreviewHTMLRenderer {
  static func document(
    title: String,
    markdown: String,
    attachments: [DraftAttachment],
    previewURLByAttachmentID: [UUID: String],
    theme: MarkdownPreviewTheme,
    isDarkAppearance: Bool,
    siteStylesheet: SitePreviewStylesheet?
  ) throws -> String {
    var renderedBlocks: [String] = []
    let bodyMarkdown = MarkdownPreviewTitleService.bodyMarkdown(
      title: title,
      markdown: markdown
    )
    for block in MarkdownExtendedPreviewService.blocks(in: bodyMarkdown) {
      try Task.checkCancellation()
      switch block {
      case let .markdown(markdownBlock):
        let prepared = MarkdownPreviewAssetService.prepare(
          markdown: markdownBlock,
          attachments: attachments,
          previewURLByAttachmentID: previewURLByAttachmentID
        )
        renderedBlocks.append(restoredAssetHTML(
          MarkdownHTMLRenderingService.renderPreviewBodyAllowingSanitizedHTML(prepared.markdown),
          replacements: prepared.replacements
        ))
      case let .mermaid(diagram):
        renderedBlocks.append(mermaidHTML(for: diagram))
      }
    }
    try Task.checkCancellation()
    let body = MarkdownPreviewSourceLinkService.annotatingHeadingLinks(
      in: theme.decorate(renderedBlocks.joined(separator: "\n")),
      sourceMarkdown: bodyMarkdown
    )
    let escapedTitle = escapeHTML(title)
    let previewStyles = theme.styles(
      isDarkAppearance: isDarkAppearance,
      siteStylesheet: siteStylesheet
    )
    return """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: publisher-asset:; font-src 'none'; media-src publisher-asset:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'" />
        <title>\(escapedTitle)</title>
        <style>\(previewStyles)</style>
      </head>
      <body>
        <article class="markdown-content">
          <header class="article-header"><h1 class="article-title">\(escapedTitle)</h1></header>
          <div class="article-body">\(body)</div>
        </article>
      </body>
    </html>
    """
  }

  private static func markdownHTMLBody(for markdown: String) -> String {
    MarkdownHTMLRenderingService.renderBody(markdown)
  }

  private static func preformattedFallback(from markdown: String) -> String {
    "<pre><code>\(escapeHTML(markdown))</code></pre>"
  }

  private static func restoredAssetHTML(
    _ html: String,
    replacements: [MarkdownPreviewAssetHTMLReplacement]
  ) -> String {
    replacements.reduce(html) { partialResult, replacement in
      partialResult.replacingOccurrences(of: replacement.token, with: replacement.html)
    }
  }

  private static func mermaidHTML(for diagram: MarkdownMermaidDiagram) -> String {
    guard !diagram.nodes.isEmpty else {
      return "<section class=\"mermaid-diagram mermaid-fallback\"><strong>Mermaid 基础流程图预览</strong><span class=\"mermaid-note\">当前不是完整 Mermaid 渲染。</span>\(preformattedFallback(from: diagram.source))</section>"
    }

    let nodeWidth = 180.0
    let nodeHeight = 48.0
    let gap = 54.0
    let padding = 34.0
    let isHorizontal = diagram.direction == .leftRight
    let width = isHorizontal
      ? padding * 2 + Double(diagram.nodes.count) * nodeWidth + Double(max(0, diagram.nodes.count - 1)) * gap
      : padding * 2 + nodeWidth
    let height = isHorizontal
      ? padding * 2 + nodeHeight
      : padding * 2 + Double(diagram.nodes.count) * nodeHeight + Double(max(0, diagram.nodes.count - 1)) * gap

    var positions: [String: (x: Double, y: Double)] = [:]
    for (index, node) in diagram.nodes.enumerated() {
      positions[node.id] = isHorizontal
        ? (padding + Double(index) * (nodeWidth + gap), padding)
        : (padding, padding + Double(index) * (nodeHeight + gap))
    }

    let edges = diagram.edges.compactMap { edge -> String? in
      guard let start = positions[edge.from], let end = positions[edge.to] else { return nil }
      let x1 = isHorizontal ? start.x + nodeWidth : start.x + nodeWidth / 2
      let y1 = isHorizontal ? start.y + nodeHeight / 2 : start.y + nodeHeight
      let x2 = isHorizontal ? end.x : end.x + nodeWidth / 2
      let y2 = isHorizontal ? end.y + nodeHeight / 2 : end.y
      let label = edge.label.map {
        "<text class=\"edge-label\" x=\"\((x1 + x2) / 2)\" y=\"\((y1 + y2) / 2 - 6)\" text-anchor=\"middle\">\(escapeHTML($0))</text>"
      } ?? ""
      return "<line class=\"edge\" x1=\"\(x1)\" y1=\"\(y1)\" x2=\"\(x2)\" y2=\"\(y2)\" marker-end=\"url(#mermaid-arrow)\"/>\(label)"
    }
    .joined()

    let nodes = diagram.nodes.compactMap { node -> String? in
      guard let point = positions[node.id] else { return nil }
      return """
      <g class="node">
        <rect x="\(point.x)" y="\(point.y)" width="\(nodeWidth)" height="\(nodeHeight)" rx="10" />
        <text x="\(point.x + nodeWidth / 2)" y="\(point.y + nodeHeight / 2 + 5)" text-anchor="middle">\(escapeHTML(node.label))</text>
      </g>
      """
    }
    .joined()

    return """
    <section class="mermaid-diagram" aria-label="Mermaid 基础流程图预览">
      <div class="mermaid-title">Mermaid 基础流程图预览</div>
      <div class="mermaid-note">当前仅支持基础流程图预览，不是完整 Mermaid。</div>
      <svg viewBox="0 0 \(width) \(height)" role="img" aria-label="\(escapeHTML(diagram.nodes.map(\.label).joined(separator: "，")))">
        <defs><marker id="mermaid-arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" /></marker></defs>
        \(edges)
        \(nodes)
      </svg>
      <details><summary>查看 Mermaid 源码</summary>\(preformattedFallback(from: diagram.source))</details>
    </section>
    """
  }

  private static func escapeHTML(_ value: String) -> String {
    MarkupEscaping.html(value)
  }
}

enum MarkdownPreviewTheme: String, CaseIterable, Identifiable, Hashable, Sendable {
  case system
  case site
  case github
  case githubDark
  case simple

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return String(localized: "跟随系统")
    case .site:
      return String(localized: "真实站点 CSS")
    case .github:
      return "GitHub"
    case .githubDark:
      return "GitHub Dark"
    case .simple:
      return String(localized: "简洁白")
    }
  }

  func styles(
    isDarkAppearance: Bool,
    siteStylesheet: SitePreviewStylesheet? = nil
  ) -> String {
    switch self {
    case .system:
      if isDarkAppearance {
        return """
        :root { color-scheme: dark; }
        body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif; line-height: 1.78; background: #171c17; color: #e3e8e1; padding: 22px; }
        .markdown-content { max-width: 860px; margin: 0; }
        .markdown-content a { color: #94c785; }
        .markdown-content pre { background: #222a21; border: 1px solid #3e4b3a; border-radius: 8px; padding: 12px; }
        .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
        .markdown-content table { border-collapse: collapse; margin: 12px 0; }
        .markdown-content th, .markdown-content td { border: 1px solid #3e4b3a; padding: 6px 10px; }
        .markdown-content blockquote { border-left: 4px solid #76a96b; margin: 12px 0; padding: 8px 12px; background: #222d21; color: #c5d3c1; }
        \(extendedPreviewStyles)
        """
      }
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif; line-height: 1.78; background: #f7f9f5; color: #253126; padding: 22px; }
      .markdown-content { max-width: 860px; margin: 0; }
      .markdown-content a { color: #427a38; }
      .markdown-content pre { background: #edf2e9; border: 1px solid #ced9c8; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #ced9c8; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #6f9b65; margin: 12px 0; padding: 8px 12px; background: #e9f1e5; color: #4d624f; }
      \(extendedPreviewStyles)
      """
    case .site:
      let base = """
      :root { color-scheme: light dark; }
      body { margin: 0; padding: 22px; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif; line-height: 1.7; }
      .markdown-content { max-width: 960px; margin: 0 auto; }
      .markdown-content img, .markdown-content video { max-width: 100%; height: auto; }
      .markdown-content table { border-collapse: collapse; }
      \(extendedPreviewStyles)
      """
      guard let siteStylesheet else {
        return base
      }
      return base + "\n\n" + siteStylesheet.css
    case .github:
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; line-height: 1.7; background: #fff; color: #24292f; padding: 20px; }
      .markdown-content { max-width: 860px; margin: 0; }
      .markdown-content pre { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content a { color: #0969da; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #d0d7de; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #d0d7de; margin: 12px 0; padding: 8px 12px; background: #f6f8fa; color: #57606a; }
      \(extendedPreviewStyles)
      """
    case .githubDark:
      return """
      :root { color-scheme: dark; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; line-height: 1.7; background: #0d1117; color: #c9d1d9; padding: 20px; }
      .markdown-content { max-width: 860px; margin: 0; }
      .markdown-content pre { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 12px; }
      .markdown-content code { font-family: SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
      .markdown-content a { color: #58a6ff; }
      .markdown-content table { border-collapse: collapse; margin: 12px 0; }
      .markdown-content th, .markdown-content td { border: 1px solid #30363d; padding: 6px 10px; }
      .markdown-content blockquote { border-left: 4px solid #30363d; margin: 12px 0; padding: 8px 12px; background: #161b22; color: #8b949e; }
      \(extendedPreviewStyles)
      """
    case .simple:
      return """
      :root { color-scheme: light; }
      body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Hiragino Sans GB', sans-serif; line-height: 1.85; background: #fffef8; color: #202020; padding: 24px; }
      .markdown-content { max-width: 900px; margin: 0; }
      .markdown-content pre { border: 1px solid #ddd; border-radius: 6px; padding: 12px; background: #f7f6f2; }
      .markdown-content code { font-family: Menlo, SFMono-Regular, Consolas, monospace; }
      .markdown-content h1, .markdown-content h2, .markdown-content h3 { line-height: 1.25; }
      .markdown-content img { max-width: 100%; }
      \(extendedPreviewStyles)
      """
    }
  }

  func decorate(_ html: String) -> String {
    html
  }

  private var extendedPreviewStyles: String {
    """
    .article-header { margin: 0 0 1.5em; padding-bottom: .85em; border-bottom: 1px solid color-mix(in srgb, currentColor 16%, transparent); }
    .article-title { margin: 0; font-size: clamp(1.75em, 4vw, 2.25em); line-height: 1.18; letter-spacing: -.02em; overflow-wrap: anywhere; }
    .mermaid-diagram { margin: 18px 0; padding: 14px; border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 10px; overflow-x: auto; }
    .mermaid-title { font-weight: 600; margin-bottom: 8px; }
    .mermaid-note { display: block; margin: 0 0 8px; color: color-mix(in srgb, currentColor 66%, transparent); font-size: .88em; }
    .mermaid-diagram svg { width: 100%; min-width: 320px; max-height: 720px; }
    .mermaid-diagram .node rect { fill: color-mix(in srgb, currentColor 8%, transparent); stroke: color-mix(in srgb, currentColor 55%, transparent); stroke-width: 1.5; }
    .mermaid-diagram .node text, .mermaid-diagram .edge-label { fill: currentColor; font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
    .mermaid-diagram .edge { stroke: color-mix(in srgb, currentColor 65%, transparent); stroke-width: 1.6; }
    .mermaid-diagram marker path { fill: currentColor; }
    .mermaid-diagram details { margin-top: 8px; color: inherit; opacity: .75; }
    .local-katex { color: inherit; }
    .local-katex-inline { display: inline-block; padding: 0 .12em; font-family: STIX Two Math, Cambria Math, serif; }
    .local-katex-display { display: block; margin: 1em 0; text-align: center; font-family: STIX Two Math, Cambria Math, serif; font-size: 1.15em; overflow-x: auto; }
    .math-fraction { display: inline-flex; flex-direction: column; vertical-align: middle; text-align: center; line-height: 1.05; margin: 0 .12em; }
    .math-numerator { border-bottom: 1px solid currentColor; padding: 0 .18em .08em; }
    .math-denominator { padding: .08em .18em 0; }
    .math-root { display: inline-flex; align-items: flex-start; }
    .math-root-sign { font-size: 1.2em; line-height: .9; margin-right: .08em; }
    .math-text, .math-mathrm, .math-operatorname { font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-style: normal; }
    .math-mathit { font-style: italic; }
    .math-mathbf { font-weight: 700; }
    .local-asset { display: block; margin: 18px 0; max-width: 100%; }
    .local-asset img, .local-asset video { display: block; max-width: 100%; height: auto; border-radius: 8px; }
    .local-asset-caption { display: block; margin-top: 7px; color: color-mix(in srgb, currentColor 68%, transparent); font-size: .9em; line-height: 1.45; }
    .repopress-source-jump { margin-left: .28em; color: currentColor; opacity: .32; text-decoration: none; font-size: .72em; }
    .repopress-source-jump:hover, .repopress-source-jump:focus { opacity: .9; text-decoration: underline; }
    """
  }
}

struct MarkdownPreviewAssetResource: Hashable, Sendable {
  let attachmentID: UUID
  let sourceURL: URL
  let mimeType: String
  let previewURLString: String

  static func resources(for attachments: [DraftAttachment]) -> [Self] {
    var seenAttachmentIDs: Set<UUID> = []
    return attachments.compactMap { attachment in
      guard seenAttachmentIDs.insert(attachment.id).inserted,
            let sourceFilePath = attachment.sourceFilePath?.nilIfEmpty else {
        return nil
      }
      let sourceURL = URL(fileURLWithPath: sourceFilePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      guard FileManager.default.isReadableFile(atPath: sourceURL.path),
            let values = try? sourceURL.resourceValues(forKeys: [
              .isRegularFileKey,
              .contentModificationDateKey,
              .fileSizeKey,
            ]),
            values.isRegularFile == true else {
        return nil
      }

      let expectedByteCount = values.fileSize ?? Int(attachment.byteSize)
      let modificationTime = Int64(
        (values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000
      )
      let revision = "\(modificationTime)-\(expectedByteCount)"
      let identifier = attachment.id.uuidString.lowercased()
      let previewURL = "\(MarkdownPreviewAssetService.URLScheme)://attachment/\(identifier)?v=\(revision)"
      let pathExtension = sourceURL.pathExtension.nilIfEmpty
        ?? URL(fileURLWithPath: attachment.originalFilename).pathExtension
      let mimeType = UTType(filenameExtension: pathExtension)?.preferredMIMEType
        ?? (attachment.mediaKind == .video
          ? VideoFileSupport.mimeType(for: sourceURL.path)
          : "application/octet-stream")
      return Self(
        attachmentID: attachment.id,
        sourceURL: sourceURL,
        mimeType: mimeType,
        previewURLString: previewURL
      )
    }
  }
}

struct MarkdownPreviewAssetByteRange: Equatable, Sendable {
  let lowerBound: Int64
  let upperBound: Int64

  var count: Int64 { upperBound - lowerBound + 1 }

  static func resolve(header: String?, fileSize: Int64) throws -> Self? {
    guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
          !header.isEmpty else {
      return nil
    }
    guard fileSize > 0,
          header.lowercased().hasPrefix("bytes="),
          !header.contains(",") else {
      throw MarkdownPreviewAssetRangeError.unsatisfiable
    }

    let value = String(header.dropFirst("bytes=".count))
    let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2 else {
      throw MarkdownPreviewAssetRangeError.unsatisfiable
    }

    if bounds[0].isEmpty {
      guard let suffixCount = Int64(bounds[1]), suffixCount > 0 else {
        throw MarkdownPreviewAssetRangeError.unsatisfiable
      }
      let count = min(suffixCount, fileSize)
      return Self(lowerBound: fileSize - count, upperBound: fileSize - 1)
    }

    guard let lowerBound = Int64(bounds[0]),
          lowerBound >= 0,
          lowerBound < fileSize else {
      throw MarkdownPreviewAssetRangeError.unsatisfiable
    }
    let upperBound: Int64
    if bounds[1].isEmpty {
      upperBound = fileSize - 1
    } else {
      guard let requestedUpperBound = Int64(bounds[1]),
            requestedUpperBound >= lowerBound else {
        throw MarkdownPreviewAssetRangeError.unsatisfiable
      }
      upperBound = min(requestedUpperBound, fileSize - 1)
    }
    return Self(lowerBound: lowerBound, upperBound: upperBound)
  }
}

private enum MarkdownPreviewAssetRangeError: Error {
  case unsatisfiable
}

@MainActor
private final class MarkdownPreviewAssetTaskSink {
  private let urlSchemeTask: WKURLSchemeTask
  private let onCompletion: @MainActor () -> Void
  private var isActive = true

  init(
    urlSchemeTask: WKURLSchemeTask,
    onCompletion: @escaping @MainActor () -> Void
  ) {
    self.urlSchemeTask = urlSchemeTask
    self.onCompletion = onCompletion
  }

  func sendResponse(
    url: URL,
    statusCode: Int,
    headers: [String: String]
  ) -> Bool {
    guard isActive else { return false }
    guard let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    ) else {
      fail(.badServerResponse)
      return false
    }
    urlSchemeTask.didReceive(response)
    return true
  }

  func sendData(_ data: Data) -> Bool {
    guard isActive else { return false }
    urlSchemeTask.didReceive(data)
    return true
  }

  func finish() {
    guard isActive else { return }
    isActive = false
    urlSchemeTask.didFinish()
    onCompletion()
  }

  func fail(_ code: URLError.Code) {
    guard isActive else { return }
    isActive = false
    urlSchemeTask.didFailWithError(URLError(code))
    onCompletion()
  }

  func cancel() {
    isActive = false
  }
}

@MainActor
private final class MarkdownPreviewAssetLoadOperation {
  let id: UUID
  let sink: MarkdownPreviewAssetTaskSink
  var worker: Task<Void, Never>?

  init(id: UUID, sink: MarkdownPreviewAssetTaskSink) {
    self.id = id
    self.sink = sink
  }

  func cancel() {
    worker?.cancel()
    sink.cancel()
  }
}

private enum MarkdownPreviewAssetFileStreamer {
  static func stream(
    resource: MarkdownPreviewAssetResource,
    rangeHeader: String?,
    requestURL: URL,
    maximumByteCount: Int,
    chunkByteCount: Int,
    sink: MarkdownPreviewAssetTaskSink
  ) async {
#if canImport(Darwin)
    guard !Task.isCancelled else { return }
    let descriptor = resource.sourceURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
      let code: URLError.Code = errno == ENOENT ? .fileDoesNotExist : .noPermissionsToReadFile
      await sink.fail(code)
      return
    }
    defer { Darwin.close(descriptor) }

    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_size >= 0,
          metadata.st_size <= off_t(maximumByteCount) else {
      await sink.fail(.dataLengthExceedsMaximum)
      return
    }

    let fileSize = Int64(metadata.st_size)
    let requestedRange: MarkdownPreviewAssetByteRange?
    do {
      requestedRange = try MarkdownPreviewAssetByteRange.resolve(
        header: rangeHeader,
        fileSize: fileSize
      )
    } catch {
      guard await sink.sendResponse(
        url: requestURL,
        statusCode: 416,
        headers: [
          "Accept-Ranges": "bytes",
          "Content-Range": "bytes */\(fileSize)",
          "Content-Length": "0",
        ]
      ) else {
        return
      }
      await sink.finish()
      return
    }

    let transferRange = requestedRange
      ?? (fileSize > 0
        ? MarkdownPreviewAssetByteRange(lowerBound: 0, upperBound: fileSize - 1)
        : nil)
    guard await sink.sendResponse(
      url: requestURL,
      statusCode: requestedRange == nil ? 200 : 206,
      headers: responseHeaders(
        mimeType: resource.mimeType,
        fileSize: fileSize,
        range: requestedRange
      )
    ) else {
      return
    }

    if let transferRange {
      var offset = transferRange.lowerBound
      var remainingByteCount = transferRange.count
      var buffer = [UInt8](repeating: 0, count: chunkByteCount)
      while remainingByteCount > 0 {
        guard !Task.isCancelled else { return }
        let requestedByteCount = min(Int64(buffer.count), remainingByteCount)
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
          Darwin.pread(
            descriptor,
            rawBuffer.baseAddress,
            Int(requestedByteCount),
            off_t(offset)
          )
        }
        if bytesRead < 0 {
          if errno == EINTR { continue }
          await sink.fail(.cannotDecodeRawData)
          return
        }
        guard bytesRead > 0 else {
          await sink.fail(.cannotDecodeRawData)
          return
        }
        guard await sink.sendData(Data(buffer.prefix(bytesRead))) else {
          return
        }
        offset += Int64(bytesRead)
        remainingByteCount -= Int64(bytesRead)
      }
    }

    await sink.finish()
#else
    await sink.fail(.unsupportedURL)
#endif
  }

  private static func responseHeaders(
    mimeType: String,
    fileSize: Int64,
    range: MarkdownPreviewAssetByteRange?
  ) -> [String: String] {
    var headers = [
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-store",
      "Content-Length": String(range?.count ?? fileSize),
      "Content-Type": mimeType,
    ]
    if let range {
      headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)"
    }
    return headers
  }
}

@MainActor
final class MarkdownPreviewAssetSchemeHandler: NSObject, WKURLSchemeHandler {
  private static let maximumImageByteCount = 64 * 1024 * 1024
  private static let maximumVideoByteCount = 256 * 1024 * 1024
  private static let streamChunkByteCount = 64 * 1024

  private var resourceByAttachmentID: [String: MarkdownPreviewAssetResource] = [:]
  private var loadOperationByTaskID: [ObjectIdentifier: MarkdownPreviewAssetLoadOperation] = [:]

  func update(resources: [MarkdownPreviewAssetResource]) {
    resourceByAttachmentID = Dictionary(
      uniqueKeysWithValues: resources.map {
        ($0.attachmentID.uuidString.lowercased(), $0)
      }
    )
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let requestURL = urlSchemeTask.request.url,
          requestURL.scheme == MarkdownPreviewAssetService.URLScheme,
          requestURL.host == "attachment",
          let identifier = requestURL.pathComponents.dropFirst().first,
          let resource = resource(for: identifier.lowercased()) else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }

    let taskID = ObjectIdentifier(urlSchemeTask)
    loadOperationByTaskID.removeValue(forKey: taskID)?.cancel()
    let operationID = UUID()
    let sink = MarkdownPreviewAssetTaskSink(
      urlSchemeTask: urlSchemeTask
    ) { [weak self] in
      self?.finishLoad(taskID: taskID, operationID: operationID)
    }
    let operation = MarkdownPreviewAssetLoadOperation(id: operationID, sink: sink)
    loadOperationByTaskID[taskID] = operation
    let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
    let maximumByteCount = resource.mimeType.hasPrefix("video/")
      ? Self.maximumVideoByteCount
      : Self.maximumImageByteCount
    operation.worker = Task.detached(priority: .utility) {
      await MarkdownPreviewAssetFileStreamer.stream(
        resource: resource,
        rangeHeader: rangeHeader,
        requestURL: requestURL,
        maximumByteCount: maximumByteCount,
        chunkByteCount: Self.streamChunkByteCount,
        sink: sink
      )
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    let taskID = ObjectIdentifier(urlSchemeTask)
    loadOperationByTaskID.removeValue(forKey: taskID)?.cancel()
  }

  private func resource(for attachmentID: String) -> MarkdownPreviewAssetResource? {
    resourceByAttachmentID[attachmentID]
  }

  private func finishLoad(taskID: ObjectIdentifier, operationID: UUID) {
    guard loadOperationByTaskID[taskID]?.id == operationID else { return }
    loadOperationByTaskID.removeValue(forKey: taskID)
  }
}

struct MarkdownPreviewWebView: NSViewRepresentable {
  let html: String
  let renderID: UUID?
  let assetResources: [MarkdownPreviewAssetResource]
  let scrollSyncUpdate: MarkdownScrollSyncUpdate?
  let scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  let onScrollProgressChanged: (Double) -> Void
  let onSourceLocationSelected: (Int) -> Void

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate {
    var lastLoadedRenderID: UUID?
    var latestScrollSyncUpdate: MarkdownScrollSyncUpdate?
    var latestScrollRestorationUpdate: MarkdownScrollSyncUpdate?
    private let scrollSyncBridge: MarkdownScrollViewSyncBridge
    private let onSourceLocationSelected: (Int) -> Void
    let assetSchemeHandler = MarkdownPreviewAssetSchemeHandler()

    init(
      onScrollProgressChanged: @escaping (Double) -> Void,
      onSourceLocationSelected: @escaping (Int) -> Void
    ) {
      scrollSyncBridge = MarkdownScrollViewSyncBridge(
        source: .preview,
        onProgressChanged: onScrollProgressChanged
      )
      self.onSourceLocationSelected = onSourceLocationSelected
      super.init()
    }

    func observeScrolling(in webView: WKWebView, allowDeferredRetry: Bool = true) {
      guard let scrollView = descendantScrollView(in: webView) else {
        guard allowDeferredRetry else { return }
        DispatchQueue.main.async { [weak self, weak webView] in
          guard let self, let webView else { return }
          self.observeScrolling(in: webView, allowDeferredRetry: false)
        }
        return
      }
      scrollSyncBridge.observe(scrollView)
    }

    func applySynchronizedScroll(includingOwnSource: Bool = false) {
      scrollSyncBridge.apply(
        latestScrollSyncUpdate,
        includingOwnSource: includingOwnSource
      )
    }

    func applyRestoredScroll() {
      scrollSyncBridge.restore(latestScrollRestorationUpdate)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      DispatchQueue.main.async { [weak self, weak webView] in
        guard let webView else { return }
        self?.observeScrolling(in: webView, allowDeferredRetry: false)
        self?.applySynchronizedScroll(includingOwnSource: true)
        self?.applyRestoredScroll()
      }
    }

    private func descendantScrollView(in view: NSView) -> NSScrollView? {
      if let scrollView = view as? NSScrollView {
        return scrollView
      }
      for subview in view.subviews {
        if let scrollView = descendantScrollView(in: subview) {
          return scrollView
        }
      }
      return nil
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.allow)
        return
      }
      if url.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      if url.scheme == MarkdownPreviewAssetService.URLScheme {
        decisionHandler(.cancel)
        return
      }
      if let sourceLocation = MarkdownPreviewSourceLinkService.sourceLocation(from: url) {
        onSourceLocationSelected(sourceLocation)
        decisionHandler(.cancel)
        return
      }
      if navigationAction.navigationType == .linkActivated {
        _ = ExternalURLOpener.open(url)
      }
      decisionHandler(.cancel)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onScrollProgressChanged: onScrollProgressChanged,
      onSourceLocationSelected: onSourceLocationSelected
    )
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.setURLSchemeHandler(
      context.coordinator.assetSchemeHandler,
      forURLScheme: MarkdownPreviewAssetService.URLScheme
    )
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    context.coordinator.observeScrolling(in: view)
    return view
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.latestScrollSyncUpdate = scrollSyncUpdate
    context.coordinator.latestScrollRestorationUpdate = scrollRestorationUpdate
    guard let renderID, context.coordinator.lastLoadedRenderID != renderID else {
      context.coordinator.applySynchronizedScroll()
      context.coordinator.applyRestoredScroll()
      return
    }
    context.coordinator.assetSchemeHandler.update(resources: assetResources)
    context.coordinator.lastLoadedRenderID = renderID
    nsView.loadHTMLString(html, baseURL: nil)
  }
}
