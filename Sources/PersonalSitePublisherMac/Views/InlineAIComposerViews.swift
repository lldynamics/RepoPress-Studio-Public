import PublishingWorkbenchCore
import SwiftUI

struct InlineSelectionFloatingPalette: View {
  let isProcessing: Bool
  let activeActionName: String?
  let preview: AIPublishingSelectionEditPreview?
  let actionMessage: String
  let availabilityForAction: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let onPerformAction: (AIPublishingActionKind) -> Void
  let onPerformConvergedAction: (AIPublishingActionConvergence) -> Void
  let onApplyPreview: () -> Void
  let onDiscardPreview: () -> Void
  let onCancel: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if let preview {
        previewContent(preview)
      } else if isProcessing {
        processingContent
      } else {
        actionContent
      }
      if !actionMessage.trimmedForPublishing.isEmpty {
        Text(actionMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .accessibilityLabel("AI 行内操作状态：\(actionMessage)")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: 520, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65))
    }
    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("AI 行内工具")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label("AI 行内工具", systemImage: "sparkles")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
      if let activeActionName {
        Text(activeActionName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Button("关闭", action: onDismiss)
        .buttonStyle(.borderless)
        .font(.caption)
        .accessibilityLabel("关闭 AI 行内工具")
    }
  }

  private var actionContent: some View {
      ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        convergedRewriteMenu
        actionButton("纠错", systemImage: "checkmark.seal", kind: .fixSelectionGrammar)
      }
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          convergedRewriteMenu
        }
        HStack(spacing: 6) {
          actionButton("纠错", systemImage: "checkmark.seal", kind: .fixSelectionGrammar)
        }
      }
    }
  }

  private var processingContent: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("正在生成行内建议…")
        .font(.caption)
      Spacer(minLength: 8)
      Button("取消", action: onCancel)
        .buttonStyle(.borderless)
        .font(.caption)
    }
    // Keep the cancel button as an independent VoiceOver action.
    .accessibilityElement(children: .contain)
    .accessibilityLabel("正在生成 AI 行内建议")
  }

  private func previewContent(_ preview: AIPublishingSelectionEditPreview) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("建议已生成，确认后替换选中文本")
        .font(.caption.weight(.medium))
      Text(preview.trimmedReplacementText)
        .font(.caption)
        .foregroundStyle(.primary)
        .lineLimit(3)
        .textSelection(.enabled)
      if !preview.providerName.trimmedForPublishing.isEmpty {
        Text(
          "服务商：\(preview.providerName)\(preview.model.trimmedForPublishing.isEmpty ? "" : " · \(preview.model)")"
        )
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Button("采用", action: onApplyPreview)
          .workbenchProminentActionStyle()
          .keyboardShortcut(.return, modifiers: [])
        Button("放弃", action: onDiscardPreview)
          .buttonStyle(.bordered)
          .keyboardShortcut(.escape, modifiers: [])
      }
    }
  }

  private var convergedRewriteMenu: some View {
    Menu {
      Section("风格") {
        ForEach(AIPublishingRewriteStyle.allCases) { style in
          Button {
            onPerformConvergedAction(
              .rewriteSelection(AIPublishingRewriteConfiguration(style: style))
            )
          } label: {
            Label(style.displayName, systemImage: "wand.and.stars")
          }
          .disabled(!availabilityForAction(.rewriteSelection).isEnabled)
        }
      }
      Section("处理") {
        ForEach(AIPublishingRewriteOperation.allCases.filter { $0 != .rewrite }) { operation in
          Button {
            onPerformConvergedAction(
              .rewriteSelection(AIPublishingRewriteConfiguration(operation: operation))
            )
          } label: {
            Label(operation.displayName, systemImage: "wand.and.stars")
          }
          .disabled(!availabilityForAction(.rewriteSelection).isEnabled)
        }
      }
    } label: {
      Label("改写", systemImage: "wand.and.stars")
    }
    .menuStyle(.borderlessButton)
    .help("使用五档风格或不同改写方式处理选区")
  }

  private var toneMenu: some View {
    Menu {
      actionButton("正式", systemImage: "textformat", kind: .rewriteSelectionFormal)
      actionButton("轻松", systemImage: "bubble.left.and.text.bubble.right", kind: .rewriteSelectionCasual)
      actionButton("技术", systemImage: "chevron.left.forwardslash.chevron.right", kind: .rewriteSelectionTechnical)
    } label: {
      Label("语气", systemImage: "slider.horizontal.3")
    }
    .menuStyle(.borderlessButton)
    .help("改变选中文本的语气")
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    kind: AIPublishingActionKind
  ) -> some View {
    let availability = availabilityForAction(kind)
    return Button {
      onPerformAction(kind)
    } label: {
      Label(title, systemImage: systemImage)
    }
    .buttonStyle(.borderless)
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? title)
    .accessibilityLabel(title)
  }
}
