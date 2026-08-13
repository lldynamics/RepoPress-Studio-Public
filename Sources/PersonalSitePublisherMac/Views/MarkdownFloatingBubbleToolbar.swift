import PublishingWorkbenchCore
import SwiftUI

struct MarkdownFloatingBubbleToolbar: View {
  let isSelectionAIActionRunning: Bool
  let onApplyFormatting: (MarkdownFormattingCommand) -> Void
  let onApplyAdvancedFormatting: (MarkdownAdvancedFormattingCommand) -> Void
  let onPerformSelectionAIAction: (AIPublishingActionKind) -> Void
  let onPerformConvergedSelectionAIAction: (AIPublishingActionConvergence) -> Void

  var body: some View {
    HStack(spacing: 4) {
      groupButton("H1", title: "一级标题") {
        onApplyFormatting(.heading(level: 1))
      }
      groupButton("H2", title: "二级标题") {
        onApplyFormatting(.heading(level: 2))
      }
      groupButton("H3", title: "三级标题") {
        onApplyFormatting(.heading(level: 3))
      }

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
              Label(operation.localizedDisplayName, systemImage: "wand.and.stars")
            }
          }
        }
      } label: {
        Label("AI 润色", systemImage: "wand.and.stars")
          .font(.workbenchButtonLabel)
      }
      .menuIndicator(.hidden)
      .foregroundStyle(Color.purple)

      Menu {
        Button {
          onPerformSelectionAIAction(.translateSelectionToChinese)
        } label: {
          Label("翻译为中文", systemImage: "character.book.closed")
        }
        Button {
          onPerformSelectionAIAction(.translateSelectionToEnglish)
        } label: {
          Label("Translate to English", systemImage: "character.book.closed")
        }
      } label: {
        Label("翻译", systemImage: "arrow.triangle.2.circlepath")
          .font(.workbenchButtonLabel)
      }
      .menuIndicator(.hidden)
      .foregroundStyle(Color.indigo)
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

  private func groupButton(_ label: String, title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label)
        .font(.workbenchMetadata.weight(.semibold))
        .monospaced()
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .help(title)
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
  }
}
