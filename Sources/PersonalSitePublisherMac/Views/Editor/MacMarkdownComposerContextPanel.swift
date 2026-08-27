import SwiftUI

extension MacMarkdownComposerView {
  var availableWritingContextPanels: [MarkdownWritingContextPanel] {
    var panels: [MarkdownWritingContextPanel] = []
    if hasSelectedText || canShowSelectionActions {
      panels.append(.selectionTools)
    }
    if selectionEditPreview != nil {
      panels.append(.aiReview)
    }
    if activeInsertedImageMetadataBinding != nil {
      panels.append(.imageInfo)
    }
    panels.append(.outline)
    return panels
  }

  func showWritingContextPanel(_ panel: MarkdownWritingContextPanel) {
    guard availableWritingContextPanels.contains(panel) else { return }
    activeWritingContextPanel = panel
    if panel == .outline {
      scheduleMarkdownAnalysis(immediate: true, includeOutline: true)
    }
  }

  func dismissWritingContextPanel() {
    activeWritingContextPanel = nil
  }

  func preparePublish() {
    guard store.ensureEditableDraftSelected() != nil else { return }
    store.runPreflight()
    let message = String(localized: "已完成发布前检查，发布准备已打开。")
    if let publishDrawerCommandAction {
      publishDrawerCommandAction.open(message)
    } else {
      store.setPublishActionMessage(message, status: .success)
    }
  }

  @ViewBuilder
  func writingContextPanelContent(for panel: MarkdownWritingContextPanel) -> some View {
    switch panel {
    case .selectionTools:
      if canShowSelectionActions {
        SelectionActionBar(
          isSelectionAIActionRunning: isSelectionAIActionRunning,
          activeSelectionActionName: activeSelectionAIAction?.localizedDisplayName,
          hasLatestAssistantMessage: latestAssistantMessageForCurrentDraft != nil,
          selectionActionMessage: selectionActionMessage,
          onSelectSelectionAction: performSelectionAIAction,
          onSelectConvergedSelectionAction: performConvergedSelectionAIAction,
          onApplyLatestAIReply: applyLatestAIReplyToSelection,
          onInsertImages: {
            insertImageReferences(ImageSelectionPanel.chooseImages())
          },
          onCheckSelectedPublicRisk: checkSelectedPublicRisk,
          onOpenAITemplateLibrary: {
            isAITemplateLibraryPresented = true
          },
          availabilityForSelectionAction: { kind in
            selectionAIActionAvailability(kind)
          }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        writingContextPanelEmptyState(
          title: "没有活动选区",
          message: "先在正文中选择文字，再打开选区工具。",
          systemImage: "text.cursor"
        )
      }

    case .aiReview:
      if let selectionEditPreview {
        SelectionEditPreviewPanel(
          preview: selectionEditPreview,
          onApply: applySelectionEditPreview,
          onDiscard: discardSelectionEditPreview
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        writingContextPanelEmptyState(
          title: "没有待审阅的 AI 建议",
          message: "AI 生成的改写会先出现在这里，确认后才会写入正文。",
          systemImage: "sparkles.rectangle.stack"
        )
      }

    case .imageInfo:
      if let metadata = activeInsertedImageMetadataBinding,
         let activeIndex = activeInsertedImageMetadataIndex {
        InsertedImageMetadataPanel(
          metadata: metadata,
          position: activeIndex + 1,
          total: insertedImageMetadataDrafts.count,
          canMovePrevious: activeIndex > 0,
          canMoveNext: activeIndex + 1 < insertedImageMetadataDrafts.count,
          onSetCover: { isCover in
            setPendingImageCover(isCover, attachmentID: metadata.wrappedValue.id)
          },
          onMovePrevious: moveToPreviousInsertedImage,
          onApplyAndAdvance: applyInsertedImageMetadataAndAdvance,
          onOpenInspector: openInsertedImageInspector,
          onDismiss: dismissInsertedImageMetadata
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        writingContextPanelEmptyState(
          title: "没有待完善的图片",
          message: "插入图片后，可以在这里补充 Alt、Caption 和封面状态。",
          systemImage: "photo"
        )
      }

    case .outline:
      MarkdownOutlinePopover(
        items: outlineItems,
        onSelect: selectOutlineItem,
        onAction: performOutlineAction
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func writingContextPanelEmptyState(
    title: String,
    message: String,
    systemImage: String
  ) -> some View {
    VStack(spacing: 8) {
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.callout.weight(.medium))
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: 150)
    .padding(16)
  }
}
