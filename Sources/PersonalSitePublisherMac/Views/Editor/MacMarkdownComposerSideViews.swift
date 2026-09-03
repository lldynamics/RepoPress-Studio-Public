import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum SelectionEditPreviewDiffKind: Equatable, Sendable {
  case unchanged
  case deletion
  case insertion
}

struct SelectionEditPreviewDiffRun: Equatable, Sendable {
  let kind: SelectionEditPreviewDiffKind
  let text: String
}

/// A compact, deterministic diff prepared for the two-column selection preview.
///
/// The UI deliberately keeps unchanged text in both columns, then decorates only
/// the removed or inserted runs. This makes punctuation-only edits just as
/// discoverable as word changes without asking the reader to mentally align two
/// unrelated paragraphs.
struct SelectionEditPreviewPresentation: Equatable, Sendable {
  static let minimumTextRegionHeight = 52.0
  static let maximumTextRegionHeight = 300.0

  let originalRuns: [SelectionEditPreviewDiffRun]
  let replacementRuns: [SelectionEditPreviewDiffRun]
  let textRegionHeight: Double

  static func make(original: String, replacement: String) -> Self {
    let runs = diffRuns(original: Array(original), replacement: Array(replacement))
    return Self(
      originalRuns: runs.original,
      replacementRuns: runs.replacement,
      textRegionHeight: textRegionHeight(original: original, replacement: replacement)
    )
  }

  static func textRegionHeight(original: String, replacement: String) -> Double {
    let estimatedLineCount = max(
      estimatedLineCount(for: original),
      estimatedLineCount(for: replacement)
    )
    let estimatedHeight = 16 + Double(estimatedLineCount) * 18
    return min(maximumTextRegionHeight, max(minimumTextRegionHeight, estimatedHeight))
  }

  private static func estimatedLineCount(for text: String) -> Int {
    guard !text.isEmpty else { return 1 }
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .reduce(into: 0) { count, line in
        count += max(1, Int(ceil(Double(line.count) / 42)))
      }
  }

  private static func diffRuns(
    original: [Character],
    replacement: [Character]
  ) -> (original: [SelectionEditPreviewDiffRun], replacement: [SelectionEditPreviewDiffRun]) {
    // A character matrix is ideal for short selections and punctuation changes.
    // For unusually large selections, retain the same presentation contract with
    // a prefix/suffix fallback rather than allocating an unbounded matrix.
    let cellLimit = 240_000
    guard original.count <= cellLimit / max(1, replacement.count) else {
      return prefixSuffixRuns(original: original, replacement: replacement)
    }

    let columnCount = replacement.count + 1
    var lengths = Array(repeating: 0, count: (original.count + 1) * columnCount)
    for originalIndex in original.indices.reversed() {
      for replacementIndex in replacement.indices.reversed() {
        let index = originalIndex * columnCount + replacementIndex
        if original[originalIndex] == replacement[replacementIndex] {
          lengths[index] = lengths[(originalIndex + 1) * columnCount + replacementIndex + 1] + 1
        } else {
          lengths[index] = max(
            lengths[(originalIndex + 1) * columnCount + replacementIndex],
            lengths[originalIndex * columnCount + replacementIndex + 1]
          )
        }
      }
    }

    var originalRuns: [SelectionEditPreviewDiffRun] = []
    var replacementRuns: [SelectionEditPreviewDiffRun] = []
    var originalIndex = 0
    var replacementIndex = 0
    while originalIndex < original.count || replacementIndex < replacement.count {
      if originalIndex < original.count,
        replacementIndex < replacement.count,
        original[originalIndex] == replacement[replacementIndex]
      {
        append(String(original[originalIndex]), kind: .unchanged, to: &originalRuns)
        append(String(replacement[replacementIndex]), kind: .unchanged, to: &replacementRuns)
        originalIndex += 1
        replacementIndex += 1
      } else if replacementIndex == replacement.count
        || (originalIndex < original.count
          && lengths[(originalIndex + 1) * columnCount + replacementIndex]
            >= lengths[originalIndex * columnCount + replacementIndex + 1])
      {
        append(String(original[originalIndex]), kind: .deletion, to: &originalRuns)
        originalIndex += 1
      } else {
        append(String(replacement[replacementIndex]), kind: .insertion, to: &replacementRuns)
        replacementIndex += 1
      }
    }
    return (originalRuns, replacementRuns)
  }

  private static func prefixSuffixRuns(
    original: [Character],
    replacement: [Character]
  ) -> (original: [SelectionEditPreviewDiffRun], replacement: [SelectionEditPreviewDiffRun]) {
    var prefixCount = 0
    while prefixCount < min(original.count, replacement.count),
      original[prefixCount] == replacement[prefixCount]
    {
      prefixCount += 1
    }

    var suffixCount = 0
    while suffixCount < min(original.count - prefixCount, replacement.count - prefixCount),
      original[original.count - suffixCount - 1] == replacement[replacement.count - suffixCount - 1]
    {
      suffixCount += 1
    }

    let prefix = String(original.prefix(prefixCount))
    let originalMiddle = String(original.dropFirst(prefixCount).dropLast(suffixCount))
    let replacementMiddle = String(replacement.dropFirst(prefixCount).dropLast(suffixCount))
    let suffix = suffixCount == 0 ? "" : String(original.suffix(suffixCount))
    var originalRuns: [SelectionEditPreviewDiffRun] = []
    var replacementRuns: [SelectionEditPreviewDiffRun] = []
    append(prefix, kind: .unchanged, to: &originalRuns)
    append(prefix, kind: .unchanged, to: &replacementRuns)
    append(originalMiddle, kind: .deletion, to: &originalRuns)
    append(replacementMiddle, kind: .insertion, to: &replacementRuns)
    append(suffix, kind: .unchanged, to: &originalRuns)
    append(suffix, kind: .unchanged, to: &replacementRuns)
    return (originalRuns, replacementRuns)
  }

  private static func append(
    _ text: String,
    kind: SelectionEditPreviewDiffKind,
    to runs: inout [SelectionEditPreviewDiffRun]
  ) {
    guard !text.isEmpty else { return }
    if let last = runs.last, last.kind == kind {
      runs[runs.count - 1] = SelectionEditPreviewDiffRun(kind: kind, text: last.text + text)
    } else {
      runs.append(SelectionEditPreviewDiffRun(kind: kind, text: text))
    }
  }
}

struct SelectionEditPreviewPanel: View {
  let preview: AIPublishingSelectionEditPreview
  let onApply: (AIPublishingSelectionEditPreview) -> Void
  let onDiscard: () -> Void

  private var presentation: SelectionEditPreviewPresentation {
    SelectionEditPreviewPresentation.make(
      original: preview.originalText,
      replacement: preview.trimmedReplacementText
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("\(preview.kind.localizedDisplayName)预览", systemImage: "doc.text.magnifyingglass")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(preview.application.localizedDisplayName)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(WorkbenchBackgroundStyle.control, in: Capsule())
        if let modelSummary = preview.modelSummary {
          Text(modelSummary)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
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
          runs: presentation.originalRuns,
          placeholder: preview.originalText.nilIfEmpty ?? "将在当前光标位置插入。"
        )
        selectionPreviewColumn(
          title: "AI 建议",
          runs: presentation.replacementRuns,
          placeholder: preview.trimmedReplacementText.nilIfEmpty ?? "AI 没有返回可应用的文本。"
        )
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
    .padding(10)
    .frame(maxWidth: 720)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
  }

  private func selectionPreviewColumn(
    title: String,
    runs: [SelectionEditPreviewDiffRun],
    placeholder: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ScrollView {
        SelectionEditPreviewDiffText(runs: runs, placeholder: placeholder)
          .font(.caption)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: presentation.textRegionHeight)
      .padding(8)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(title)：\(placeholder)")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SelectionEditPreviewDiffText: View {
  let runs: [SelectionEditPreviewDiffRun]
  let placeholder: String

  var body: some View {
    if runs.isEmpty {
      Text(placeholder)
        .foregroundStyle(.secondary)
    } else {
      runs.reduce(Text("")) { partialResult, run in
        partialResult + styledText(for: run)
      }
    }
  }

  private func styledText(for run: SelectionEditPreviewDiffRun) -> Text {
    switch run.kind {
    case .unchanged:
      Text(run.text)
    case .deletion:
      Text(run.text)
        .foregroundColor(WorkbenchTheme.risk)
        .strikethrough()
    case .insertion:
      Text(run.text)
        .foregroundColor(WorkbenchTheme.success)
    }
  }
}

struct MarkdownShortcutHelpPanel: View {
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  private var shortcutGroups: [(String, [(String, String)])] {
    var groups: [(String, [(String, String)])] = [
    (
      String(localized: "焦点导航"),
      [
        (String(localized: "移到下一个控件"), "Control-Tab"),
        (String(localized: "移到上一个控件"), "Control-Shift-Tab")
      ]
    ),
    (
      String(localized: "编辑"),
      [
        (String(localized: "查找"), "⌘F"),
        (String(localized: "查找下一个"), "⌘G"),
        (String(localized: "查找上一个"), "⇧⌘G"),
        (String(localized: "查找栏下一个 / 上一个"), "Return / Shift-Return"),
        (String(localized: "关闭查找栏"), "Esc"),
        (String(localized: "替换当前"), String(localized: "查找栏“替换”")),
        (String(localized: "全部替换"), "⌥⌘E"),
        (String(localized: "插入图片"), "⇧⌘I"),
        (String(localized: "模板与片段"), "⌥⌘S"),
        (String(localized: "文章大纲"), "⌥⌘O"),
        (String(localized: "跳转到行"), "⌘L"),
        (String(localized: "文章后退"), "⌘["),
        (String(localized: "文章前进"), "⌘]"),
        (String(localized: "粘贴 URL 为链接"), String(localized: "选中文字后按 ⌘V")),
        (String(localized: "粘贴截图"), "⌘V")
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
        (String(localized: "增加列表层级"), "Tab"),
        (String(localized: "减少列表层级"), "Shift-Tab"),
        (String(localized: "表格、代码、图片、脚注补全"), "/表格、/代码、/图片、/脚注"),
        (String(localized: "文章链接补全"), "[[文章]]"),
        (String(localized: "代码语言补全"), "```swift")
      ]
    ),
  ]
    groups.append(
      (
        String(localized: "AI 与工具"),
        [
          (String(localized: "请求 AI 续写"), "⌥\\"),
          (String(localized: "采纳 AI 续写"), "Tab"),
          (String(localized: "丢弃 AI 续写"), "Esc"),
          (String(localized: "改写选中文本"), "⌥⌘R"),
          (String(localized: "打开 AI 对话"), String(localized: "AI > 打开 AI 对话")),
          (String(localized: "复制上下文 Prompt"), String(localized: "AI > 复制上下文 Prompt")),
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
        .padding(10)

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
