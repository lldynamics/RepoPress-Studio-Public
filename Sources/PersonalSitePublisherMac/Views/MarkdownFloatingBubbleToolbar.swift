import PublishingWorkbenchCore
import SwiftUI

struct MarkdownHeadingMenuItems: View {
  let onSelectHeading: (Int) -> Void

  var body: some View {
    ForEach(1...6, id: \.self) { level in
      Button {
        onSelectHeading(level)
      } label: {
        Label("\(level) 级标题 (H\(level))", systemImage: "textformat.size")
      }
    }
  }
}

struct MarkdownListMenuItems: View {
  let onSelectUnorderedList: () -> Void
  let onSelectOrderedList: () -> Void
  let onSelectTaskList: () -> Void

  var body: some View {
    Button {
      onSelectUnorderedList()
    } label: {
      Label("无序列表", systemImage: "list.bullet")
    }
    Button {
      onSelectOrderedList()
    } label: {
      Label("有序列表", systemImage: "list.number")
    }
    Button {
      onSelectTaskList()
    } label: {
      Label("任务列表", systemImage: "checklist")
    }
  }
}

struct MarkdownFloatingBubbleToolbar: View {
  let isSelectionAIActionRunning: Bool
  let onApplyFormatting: (MarkdownFormattingCommand) -> Void
  let onApplyAdvancedFormatting: (MarkdownAdvancedFormattingCommand) -> Void
  let onPerformSelectionAIAction: (AIPublishingActionKind) -> Void
  let onPerformConvergedSelectionAIAction: (AIPublishingActionConvergence) -> Void

  var body: some View {
    HStack(spacing: 4) {
      Menu {
        MarkdownHeadingMenuItems { level in
          onApplyFormatting(.heading(level: level))
        }
      } label: {
        HStack(spacing: 2) {
          Text("H")
            .font(.workbenchMetadata.weight(.semibold))
            .monospaced()
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
      }
      .menuIndicator(.hidden)
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .help("插入或切换标题 (H1-H6)")
      .accessibilityLabel("标题层级")

      divider

      iconButton("bold", title: "粗体") {
        onApplyFormatting(.bold)
      }
      iconButton("italic", title: "斜体") {
        onApplyFormatting(.italic)
      }
      iconButton("chevron.left.forwardslash.chevron.right", title: "行内代码") {
        onApplyAdvancedFormatting(.inlineCode)
      }

      divider

      Menu {
        MarkdownListMenuItems(
          onSelectUnorderedList: { onApplyAdvancedFormatting(.unorderedList) },
          onSelectOrderedList: { onApplyAdvancedFormatting(.orderedList) },
          onSelectTaskList: { onApplyAdvancedFormatting(.taskList) }
        )
      } label: {
        HStack(spacing: 2) {
          Image(systemName: "list.bullet")
            .font(.system(size: 11, weight: .medium))
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .frame(height: 24)
        .padding(.horizontal, 3)
      }
      .menuIndicator(.hidden)
      .buttonStyle(.plain)
      .foregroundStyle(.primary)
      .help("转换为列表（无序、有序、任务列表）")
      .accessibilityLabel("列表格式")

      divider

      Menu {
        Section("风格改写") {
          ForEach(AIPublishingRewriteStyle.allCases) { style in
            Button {
              onPerformConvergedSelectionAIAction(
                .rewriteSelection(AIPublishingRewriteConfiguration(style: style))
              )
            } label: {
              Label(style.localizedDisplayName, systemImage: "wand.and.stars")
            }
          }
        }
        Section("文本处理") {
          ForEach(AIPublishingRewriteOperation.allCases.filter { $0 != .rewrite }) { operation in
            Button {
              onPerformConvergedSelectionAIAction(
                .rewriteSelection(AIPublishingRewriteConfiguration(operation: operation))
              )
            } label: {
              Label(operation.localizedDisplayName, systemImage: operation.systemImage)
            }
          }
        }
      } label: {
        Label("AI 润色", systemImage: "wand.and.stars")
          .font(.workbenchButtonLabel)
      }
      .menuIndicator(.hidden)
      .foregroundStyle(WorkbenchTheme.progress)
      .accessibilityLabel("AI 润色与处理")

      Menu {
        Button {
          onPerformSelectionAIAction(.translateSelectionToChinese)
        } label: {
          Label("翻译为中文", systemImage: "character.book.closed")
        }
        Button {
          onPerformSelectionAIAction(.translateSelectionToEnglish)
        } label: {
          Label(String(localized: "翻译为英文"), systemImage: "character.book.closed")
        }
      } label: {
        Label("翻译", systemImage: "arrow.triangle.2.circlepath")
          .font(.workbenchButtonLabel)
      }
      .menuIndicator(.hidden)
      .foregroundStyle(WorkbenchTheme.brand)
      .accessibilityLabel("AI 翻译")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      .thinMaterial,
      in: Capsule()
    )
    .overlay(
      Capsule()
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
  }

  private var divider: some View {
    Divider()
      .frame(height: 14)
  }

  private func iconButton(_ systemName: String, title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .help(title)
    .accessibilityLabel(title)
  }
}
