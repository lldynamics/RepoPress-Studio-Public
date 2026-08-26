import AppKit
import Foundation
import PublishingWorkbenchCore
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif
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
          Label(style.localizedDisplayName, systemImage: "wand.and.stars")
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
          Label(operation.localizedDisplayName, systemImage: "wand.and.stars")
        }
        .disabled(!availabilityForSelectionAction(.rewriteSelection).isEnabled)
      }
    }
  }
}
