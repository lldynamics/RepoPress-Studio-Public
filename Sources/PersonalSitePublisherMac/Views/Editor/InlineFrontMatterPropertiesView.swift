import PublishingWorkbenchCore
import SwiftUI

/// The compact editing rules shared by the Front Matter property controls.
///
/// Values are intentionally normalized at the interaction boundary so the
/// rendered chips and persisted `ArticleDraft` metadata remain predictable.
enum InlineFrontMatterCollectionEditing {
  static func normalized(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard let trimmed = trimmed(value) else { return nil }
      guard seen.insert(comparisonKey(for: trimmed)).inserted else { return nil }
      return trimmed
    }
  }

  static func adding(_ value: String, to values: [String]) -> [String] {
    let normalizedValues = normalized(values)
    guard let trimmed = trimmed(value) else { return normalizedValues }
    let isDuplicate = normalizedValues.contains {
      comparisonKey(for: $0) == comparisonKey(for: trimmed)
    }
    guard !isDuplicate
    else {
      return normalizedValues
    }
    return normalizedValues + [trimmed]
  }

  static func removing(_ value: String, from values: [String]) -> [String] {
    let key = comparisonKey(for: value.trimmingCharacters(in: .whitespacesAndNewlines))
    return normalized(values).filter { comparisonKey(for: $0) != key }
  }

  static func suggestions(from values: [String], excluding selectedValues: [String]) -> [String] {
    let selectedKeys = Set(normalized(selectedValues).map(comparisonKey(for:)))
    return normalized(values)
      .filter { !selectedKeys.contains(comparisonKey(for: $0)) }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private static func trimmed(_ value: String) -> String? {
    value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func comparisonKey(for value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}

enum InlineFrontMatterPropertiesPresentation {
  static func effectiveExpanded(isExpanded: Bool, forceCompact: Bool) -> Bool {
    isExpanded && !forceCompact
  }

  static func resolvedSlug(slug: String, date: Date) -> String {
    slug.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? SlugService.fallbackSlug(date: date)
  }

  static func summary(
    slug: String,
    date: Date,
    tags: [String],
    categories: [String],
    sourceIssueMessage: String?
  ) -> String {
    let issue = sourceIssueMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let issue, !issue.isEmpty {
      return "Front Matter · 格式错误：\(issue)"
    }
    let resolvedSlug = resolvedSlug(slug: slug, date: date)
    let tagCount = InlineFrontMatterCollectionEditing.normalized(tags).count
    let categoryCount = InlineFrontMatterCollectionEditing.normalized(categories).count
    return "Front Matter · \(resolvedSlug) · 标签 \(tagCount) · 分类 \(categoryCount)"
  }

  static func summary(for draft: ArticleDraft, sourceIssueMessage: String?) -> String {
    summary(
      slug: draft.slug,
      date: draft.date,
      tags: draft.tags,
      categories: draft.categories,
      sourceIssueMessage: sourceIssueMessage
    )
  }

  static func sourceTitle(for style: FrontMatterStyle) -> String {
    switch style {
    case .yaml:
      return "YAML 源码"
    case .toml:
      return "TOML 源码"
    }
  }

  static func showsSource(requested: Bool, hasIssue: Bool) -> Bool {
    requested || hasIssue
  }
}

struct InlineFrontMatterPropertiesView: View {
  @Binding var draft: ArticleDraft
  let profile: SiteProfile
  let categorySuggestions: [String]
  @Binding var isSourceVisible: Bool
  let sourceIssueMessage: String?
  @Binding var isExpanded: Bool
  let forceCompact: Bool

  init(
    draft: Binding<ArticleDraft>,
    profile: SiteProfile,
    categorySuggestions: [String],
    isSourceVisible: Binding<Bool>,
    sourceIssueMessage: String?,
    isExpanded: Binding<Bool> = .constant(true),
    forceCompact: Bool = false
  ) {
    _draft = draft
    self.profile = profile
    self.categorySuggestions = categorySuggestions
    _isSourceVisible = isSourceVisible
    self.sourceIssueMessage = sourceIssueMessage
    _isExpanded = isExpanded
    self.forceCompact = forceCompact
  }

  @State private var tagInput = ""
  @State private var categoryInput = ""

  private var hasSourceIssue: Bool {
    sourceIssueMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  }

  private var showsSource: Bool {
    InlineFrontMatterPropertiesPresentation.showsSource(
      requested: isSourceVisible,
      hasIssue: hasSourceIssue
    )
  }

  private var shouldShowExpandedContent: Bool {
    InlineFrontMatterPropertiesPresentation.effectiveExpanded(
      isExpanded: isExpanded,
      forceCompact: forceCompact
    )
  }

  private var summary: String {
    InlineFrontMatterPropertiesPresentation.summary(
      for: draft,
      sourceIssueMessage: sourceIssueMessage
    )
  }

  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  private var sourceTitle: String {
    InlineFrontMatterPropertiesPresentation.sourceTitle(for: profile.frontMatterStyle)
  }

  private var availableCategorySuggestions: [String] {
    InlineFrontMatterCollectionEditing.suggestions(
      from: categorySuggestions,
      excluding: draft.categories
    )
  }

  var body: some View {
    Group {
      if shouldShowExpandedContent {
        VStack(alignment: .leading, spacing: 10) {
          header

          if showsSource {
            sourceModeNotice
          } else {
            properties
          }
        }
        .padding(12)
      } else {
        collapsedSummary
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .frame(minHeight: 28)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .animation(
      accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2),
      value: shouldShowExpandedContent
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章 Front Matter 属性")
    .accessibilityHint("编辑标题、标签、分类、日期和 slug，或切换到原始 Front Matter 源码")
    .accessibilityIdentifier("inline-front-matter-properties")
  }

  private var collapsedSummary: some View {
    Button {
      isExpanded = true
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .imageScale(.small)
        Text(summary)
          .font(.caption)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("展开 Front Matter 属性")
    .accessibilityLabel("Front Matter 属性已折叠")
    .accessibilityHint(forceCompact ? "当前处于紧凑模式；点击保留展开意图" : "点击展开 Front Matter 属性")
    .accessibilityIdentifier("inline-front-matter-properties-expand")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        isExpanded = false
      } label: {
        Image(systemName: "chevron.down")
          .imageScale(.small)
      }
      .buttonStyle(.plain)
      .help("折叠 Front Matter 属性")
      .accessibilityLabel("折叠 Front Matter 属性")
      .accessibilityHint("将属性面板收起为摘要条")
      .accessibilityIdentifier("inline-front-matter-properties-collapse")

      Label("Front Matter", systemImage: "slider.horizontal.3")
        .font(.headline)

      Spacer(minLength: 12)

      Button("属性视图") {
        isSourceVisible = false
      }
      .buttonStyle(.bordered)
      .tint(showsSource ? .secondary : .accentColor)
      .controlSize(.small)
      .disabled(hasSourceIssue)
      .help(
        hasSourceIssue
          ? "请先修复原始 Front Matter 格式，才能返回属性视图"
          : "使用结构化属性编辑 Front Matter"
      )
      .accessibilityLabel("属性视图")
      .accessibilityHint("显示可直接编辑的 Front Matter 属性")
      .accessibilityIdentifier("inline-front-matter-properties-toggle")

      Button(sourceTitle) {
        isSourceVisible = true
      }
      .buttonStyle(.bordered)
      .tint(showsSource ? .accentColor : .secondary)
      .controlSize(.small)
      .help("显示可自由编辑的 \(sourceTitle)")
      .accessibilityLabel(sourceTitle)
      .accessibilityHint("显示 Front Matter 的原始文本")
      .accessibilityIdentifier("inline-front-matter-source-toggle")
    }
  }

  private var sourceModeNotice: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let sourceIssueMessage, hasSourceIssue {
        Label("Front Matter 需要修复", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(WorkbenchTheme.warning)
          .font(.callout.weight(.semibold))
        Text(sourceIssueMessage)
          .font(.caption)
      } else {
        Label("正在编辑 \(sourceTitle)", systemImage: "doc.plaintext")
          .font(.callout.weight(.semibold))
        Text("原始 Front Matter 会显示在下方编辑器中；可随时切回属性视图。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(hasSourceIssue ? "Front Matter 需要修复" : "正在编辑 \(sourceTitle)")
    .accessibilityIdentifier("inline-front-matter-source-notice")
  }

  private var properties: some View {
    VStack(alignment: .leading, spacing: 9) {
      propertyRow("标题", systemImage: "textformat") {
        TextField("文章标题", text: $draft.title)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .accessibilityLabel("文章标题")
          .accessibilityHint("输入文章标题")
          .accessibilityIdentifier("inline-front-matter-title")
      }

      propertyRow("标签", systemImage: "tag") {
        collectionEditor(
          values: draft.tags,
          input: $tagInput,
          placeholder: "添加标签",
          kind: "标签",
          add: addTag,
          remove: removeTag
        )
      }

      propertyRow("分类", systemImage: "folder") {
        VStack(alignment: .leading, spacing: 6) {
          collectionEditor(
            values: draft.categories,
            input: $categoryInput,
            placeholder: "添加分类",
            kind: "分类",
            add: addCategory,
            remove: removeCategory
          )

          if !availableCategorySuggestions.isEmpty {
            Menu {
              ForEach(availableCategorySuggestions, id: \.self) { category in
                Button(category) {
                  draft.categories = InlineFrontMatterCollectionEditing.adding(
                    category,
                    to: draft.categories
                  )
                }
              }
            } label: {
              Label("从已有分类添加", systemImage: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .help("从此站点已有文章的分类中选择")
            .accessibilityLabel("已有分类")
            .accessibilityHint("打开菜单并添加一个已有分类")
            .accessibilityIdentifier("inline-front-matter-category-suggestions")
          }
        }
      }

      propertyRow("日期", systemImage: "calendar") {
        DatePicker("发布日期", selection: $draft.date, displayedComponents: .date)
          .datePickerStyle(.field)
          .controlSize(.small)
          .labelsHidden()
          .accessibilityLabel("发布日期")
          .accessibilityHint("选择文章发布日期")
          .accessibilityIdentifier("inline-front-matter-date")
      }

      propertyRow("Slug", systemImage: "link") {
        TextField("文章 slug", text: $draft.slug)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .accessibilityLabel("文章 slug")
          .accessibilityHint("输入用于文章 URL 的 slug")
          .accessibilityIdentifier("inline-front-matter-slug")
      }
    }
  }

  private func propertyRow<Content: View>(
    _ title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Label(title, systemImage: systemImage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 76, alignment: .leading)

      content()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func collectionEditor(
    values: [String],
    input: Binding<String>,
    placeholder: String,
    kind: String,
    add: @escaping () -> Void,
    remove: @escaping (String) -> Void
  ) -> some View {
    let identifier = collectionIdentifier(for: kind)
    return InlineFrontMatterChipLayout(spacing: 6, lineSpacing: 6) {
      ForEach(InlineFrontMatterCollectionEditing.normalized(values), id: \.self) { value in
        collectionChip(value, kind: kind, remove: remove)
      }

      TextField(placeholder, text: input)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(width: 122)
        .onSubmit(add)
        .accessibilityLabel("添加\(kind)")
        .accessibilityHint("输入后按回车添加")
        .accessibilityIdentifier("inline-front-matter-add-\(identifier)")
    }
  }

  private func collectionChip(
    _ value: String,
    kind: String,
    remove: @escaping (String) -> Void
  ) -> some View {
    let identifier = collectionIdentifier(for: kind)
    return HStack(spacing: 4) {
      Text(value)
        .lineLimit(1)
      Button {
        remove(value)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .imageScale(.small)
      }
      .buttonStyle(.plain)
      .help("移除\(kind) \(value)")
      .accessibilityLabel("移除\(kind) \(value)")
      .accessibilityHint("从当前文章的\(kind)中移除 \(value)")
      .accessibilityValue(value)
      .accessibilityIdentifier("inline-front-matter-remove-\(identifier)-\(value)")
    }
    .font(.caption)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(.quaternary, in: Capsule())
  }

  private func addTag() {
    draft.tags = InlineFrontMatterCollectionEditing.adding(tagInput, to: draft.tags)
    tagInput = ""
  }

  private func removeTag(_ value: String) {
    draft.tags = InlineFrontMatterCollectionEditing.removing(value, from: draft.tags)
  }

  private func addCategory() {
    draft.categories = InlineFrontMatterCollectionEditing.adding(
      categoryInput,
      to: draft.categories
    )
    categoryInput = ""
  }

  private func removeCategory(_ value: String) {
    draft.categories = InlineFrontMatterCollectionEditing.removing(value, from: draft.categories)
  }

  private func collectionIdentifier(for kind: String) -> String {
    kind == "标签" ? "tags" : "categories"
  }
}

private struct InlineFrontMatterChipLayout: Layout {
  var spacing: CGFloat
  var lineSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let availableWidth = proposal.width ?? .greatestFiniteMagnitude
    var rowWidth: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalHeight: CGFloat = 0
    var maximumRowWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let nextWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
      if nextWidth > availableWidth, rowWidth > 0 {
        totalHeight += rowHeight + lineSpacing
        maximumRowWidth = max(maximumRowWidth, rowWidth)
        rowWidth = size.width
        rowHeight = size.height
      } else {
        rowWidth = nextWidth
        rowHeight = max(rowHeight, size.height)
      }
    }

    guard !subviews.isEmpty else { return .zero }
    return CGSize(
      width: proposal.width ?? max(maximumRowWidth, rowWidth),
      height: totalHeight + rowHeight
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + spacing + size.width > bounds.maxX {
        x = bounds.minX
        y += rowHeight + lineSpacing
        rowHeight = 0
      }

      subview.place(
        at: CGPoint(x: x, y: y),
        proposal: ProposedViewSize(width: size.width, height: size.height)
      )
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
