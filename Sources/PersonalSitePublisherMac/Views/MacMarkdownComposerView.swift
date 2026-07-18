import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownComposerView: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  let aiActions: WorkbenchAIFeatureFacade
  @StateObject private var editorState: WorkbenchMarkdownEditorFeatureFacade
  @State private var editorBody: String
  @State private var editorStatistics = MarkdownEditorStatistics.empty
  @State private var selectedRange: NSRange
  @State private var isImageDropTargeted = false
  @State private var activeSelectionAIAction: AIPublishingActionKind?
  @State private var selectionAIActionTask: Task<Void, Never>?
  @State private var selectionAIActionRequestID: UUID?
  @State private var aiPromptClipboardTask: Task<Void, Never>?
  @State private var aiPromptClipboardRequestID: UUID?
  @State private var isFindReplacePresented: Bool
  @State private var findQuery: String
  @State private var replacementText: String
  @State private var isFindCaseSensitive: Bool
  @State private var isFindWholeWord: Bool
  @State private var isFindRegularExpression: Bool
  @State private var findReplaceMessage = ""
  @State private var editorEditRequest: MarkdownTextEditRequest?
  @State private var markdownTextFocusRequest: MarkdownTextFocusRequest?
  @State private var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  @State private var editorScrollRestorationUpdate: MarkdownScrollSyncUpdate?
  @State private var previewScrollRestorationUpdate: MarkdownScrollSyncUpdate?
  @State private var editorScrollProgress: Double
  @State private var previewScrollProgress: Double
  @State private var selectionActionMessage = ""
  @State private var selectionEditPreview: AIPublishingSelectionEditPreview?
  @State private var isShortcutHelpPresented = false
  @State private var isOutlinePresented = false
  @State private var isInternalLinkPickerPresented = false
  @State private var isDiagnosticsPresented = false
  @State private var isSnippetLibraryPresented = false
  @State private var markdownAnalysis = MarkdownEditorAnalysisSnapshot.empty
  @State private var markdownAnalysisGeneration: UInt64 = 0
  @State private var appliedMarkdownAnalysisGeneration: UInt64 = 0
  @State private var markdownAnalysisTask: Task<Void, Never>?
  @State private var insertedImageMetadataDrafts: [InsertedImageMetadataDraft] = []
  @State private var activeInsertedImageMetadataID: UUID?
  @State private var editorBodyRevision: UInt64
  @AppStorage("markdownEditorSynchronizedScrolling") private var isSynchronizedScrollingEnabled = true
  @AppStorage(MarkdownEditorComfortPreferences.fontSizeKey)
  private var editorFontSize = MarkdownEditorComfortConfiguration.defaultFontSize
  @AppStorage(MarkdownEditorComfortPreferences.lineSpacingKey)
  private var editorLineSpacing = MarkdownEditorComfortConfiguration.defaultLineSpacing
  @AppStorage(MarkdownEditorComfortPreferences.bodyWidthKey)
  private var editorBodyWidth = MarkdownEditorComfortConfiguration.defaultBodyWidth
  @AppStorage(MarkdownEditorComfortPreferences.spellCheckEnabledKey)
  private var isEditorSpellCheckEnabled = MarkdownEditorComfortConfiguration.defaultSpellCheckEnabled
  @AppStorage(MarkdownEditorComfortPreferences.typewriterModeEnabledKey)
  private var isTypewriterModeEnabled = MarkdownEditorComfortConfiguration.defaultTypewriterModeEnabled
  @AppStorage(MarkdownEditorComfortPreferences.currentParagraphHighlightEnabledKey)
  private var isCurrentParagraphHighlightEnabled = MarkdownEditorComfortConfiguration.defaultCurrentParagraphHighlightEnabled
  @AppStorage(MarkdownEditorComfortPreferences.writingGoalKey)
  private var editorWritingGoal = MarkdownEditorComfortConfiguration.defaultWritingGoal
  private let findReplaceService = MarkdownFindReplaceService()
  private let outlineService = MarkdownOutlineService()
  private let markdownAnalysisService = MarkdownEditorAnalysisService()
  private let imageMetadataEditingService = ImageMetadataEditingService()

  private var inlineDiagnostics: [MarkdownInlineDiagnostic] {
    guard appliedMarkdownAnalysisGeneration == markdownAnalysisGeneration else { return [] }
    return markdownAnalysis.diagnostics
  }

  private var outlineItems: [MarkdownOutlineItem] {
    guard appliedMarkdownAnalysisGeneration == markdownAnalysisGeneration else { return [] }
    return markdownAnalysis.outlineItems
  }

  private var editorComfortConfiguration: MarkdownEditorComfortConfiguration {
    MarkdownEditorComfortConfiguration(
      fontSize: editorFontSize,
      lineSpacing: editorLineSpacing,
      bodyWidth: editorBodyWidth,
      spellCheckEnabled: isEditorSpellCheckEnabled,
      typewriterModeEnabled: isTypewriterModeEnabled,
      currentParagraphHighlightEnabled: isCurrentParagraphHighlightEnabled
    )
  }

  init(draft: Binding<ArticleDraft>, store: WorkbenchStore) {
    _draft = draft
    let draftID = draft.wrappedValue.id
    let buffer = store.draftBodyEditorBuffer(for: draftID)
    let bodyUTF16Count = (buffer.bodyMarkdown as NSString).length
    let editorSession = store.markdownEditorSessionState(for: draftID)
      .normalized(bodyUTF16Count: bodyUTF16Count)
    _editorBody = State(initialValue: buffer.bodyMarkdown)
    _editorBodyRevision = State(initialValue: buffer.revision)
    _selectedRange = State(
      initialValue: editorSession.selectedRange(bodyUTF16Count: bodyUTF16Count)
    )
    _isFindReplacePresented = State(initialValue: editorSession.isFindReplacePresented)
    _findQuery = State(initialValue: editorSession.findQuery)
    _replacementText = State(initialValue: editorSession.replacementText)
    _isFindCaseSensitive = State(initialValue: editorSession.isFindCaseSensitive)
    _isFindWholeWord = State(initialValue: editorSession.isFindWholeWord)
    _isFindRegularExpression = State(initialValue: editorSession.isFindRegularExpression)
    _editorScrollProgress = State(initialValue: editorSession.editorScrollProgress)
    _previewScrollProgress = State(initialValue: editorSession.previewScrollProgress)
    _editorScrollRestorationUpdate = State(
      initialValue: MarkdownScrollSyncUpdate(
        source: .editor,
        progress: editorSession.editorScrollProgress
      )
    )
    _previewScrollRestorationUpdate = State(
      initialValue: MarkdownScrollSyncUpdate(
        source: .preview,
        progress: editorSession.previewScrollProgress
      )
    )
    self.store = store
    aiActions = store.ai
    _editorState = StateObject(
      wrappedValue: WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: draftID)
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      MacMarkdownEditorToolbar(
        title: $draft.title,
        markdownPath: editorState.profile(for: draft).markdownPath(for: draft),
        lastSaveStatus: editorState.lastSaveStatus,
        hasUnsavedChanges: editorState.hasUnsavedChanges,
        editorDisplayMode: editorState.editorDisplayMode,
        isSelectionAIActionRunning: isSelectionAIActionRunning,
        isOutlinePresented: $isOutlinePresented,
        outlineItems: outlineItems,
        onSetEditorDisplayMode: { store.setEditorDisplayMode($0) },
        onShowFindReplace: showFindReplace,
        onShowOutline: showOutline,
        onSelectOutlineItem: selectOutlineItem,
        onPerformOutlineAction: performOutlineAction,
        onShowShortcutHelp: {
          isShortcutHelpPresented = true
        },
        onOpenAIContextInspector: showAIContextInspector,
        recommendedAIActionMenuItems: recommendedAIActionMenuItems,
        moreAIActionMenuItems: moreAIActionMenuItems,
        isSelectionAIAction: isSelectionAIAction,
        selectionAIActionAvailability: { kind in
          selectionAIActionAvailability(kind)
        },
        articleAIActionAvailability: { kind in
          articleAIActionAvailability(kind)
        },
        onPerformSelectionAIAction: performSelectionAIAction,
        onPerformArticleAIAction: performArticleAIAction,
        onPasteAIPromptToClipboard: pasteAIPromptToClipboard
      )
      Divider()
      if isFindReplacePresented {
        FindReplaceBar(
          findQuery: $findQuery,
          replacementText: $replacementText,
          isFindCaseSensitive: $isFindCaseSensitive,
          isFindWholeWord: $isFindWholeWord,
          isFindRegularExpression: $isFindRegularExpression,
          canUseFindReplace: canUseFindReplace,
          findMatchStatus: findMatchStatus,
          findReplaceMessage: findReplaceFeedbackMessage,
          onFindPrevious: findPrevious,
          onFindNext: findNext,
          onReplaceCurrentOrNext: replaceCurrentOrNext,
          onReplaceAll: replaceAll,
          onDismiss: {
            isFindReplacePresented = false
          }
        )
        Divider()
      }
      ZStack(alignment: .top) {
        editorSurface
        if canShowSelectionActions {
          SelectionActionBar(
            selectionAIActionMenuItems: selectionAIActionMenuItems,
            isSelectionAIActionRunning: isSelectionAIActionRunning,
            activeSelectionActionName: activeSelectionAIAction?.localizedDisplayName,
            hasLatestAssistantMessage: latestAssistantMessageForCurrentDraft != nil,
            selectionActionMessage: selectionActionMessage,
            onSelectSelectionAction: performSelectionAIAction,
            onApplyLatestAIReply: applyLatestAIReplyToSelection,
            onInsertImages: {
              insertImageReferences(ImageSelectionPanel.chooseImages())
            },
            onCheckSelectedPublicRisk: checkSelectedPublicRisk,
            availabilityForSelectionAction: { kind in
              selectionAIActionAvailability(kind)
            }
          )
            .padding(.top, 10)
            .zIndex(1)
        }
        if let selectionEditPreview {
          SelectionEditPreviewPanel(
            preview: selectionEditPreview,
            onApply: applySelectionEditPreview,
            onDiscard: discardSelectionEditPreview
          )
            .padding(.top, hasSelectedText ? 58 : 10)
            .zIndex(2)
        }
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
          .padding(.top, 10)
          .zIndex(3)
        }
      }
    }
    .focusedSceneValue(\.markdownEditorCommandActions, commandActions)
    .onAppear {
      syncEditorBodyFromStore()
      restoreEditorSession(for: draft.id)
      syncActiveEditorSelection()
      applyEditorFocusRequest()
      scheduleMarkdownAnalysis(immediate: true)
    }
    .onChange(of: editorState.editorFocusRequest?.id) { _, _ in
      applyEditorFocusRequest()
    }
    .onChange(of: selectedRange) { _, _ in
      syncActiveEditorSelection()
      saveCurrentEditorSession()
    }
    .onChange(of: findQuery) { _, _ in
      findReplaceMessage = ""
      saveCurrentEditorSession()
    }
    .onChange(of: findOptions) { _, _ in
      findReplaceMessage = ""
      saveCurrentEditorSession()
    }
    .onChange(of: replacementText) { _, _ in
      saveCurrentEditorSession()
    }
    .onChange(of: isFindReplacePresented) { _, _ in
      saveCurrentEditorSession()
    }
    .onChange(of: isSynchronizedScrollingEnabled) { _, isEnabled in
      guard isEnabled, let scrollSyncUpdate else { return }
      self.scrollSyncUpdate = MarkdownScrollSyncUpdate(
        source: scrollSyncUpdate.source,
        progress: scrollSyncUpdate.progress
      )
    }
    .onChange(of: editorBody) { previousBody, _ in
      syncActiveEditorSelection()
      stageEditorBody(replacingBaseBody: previousBody)
      scheduleMarkdownAnalysis()
      saveCurrentEditorSession()
    }
    .onChange(of: draft.bodyMarkdown) { _, _ in
      syncEditorBodyFromStore()
    }
    .onChange(of: editorBufferRevision) { _, _ in
      syncEditorBodyFromStore()
    }
    .onChange(of: draft.id) { oldDraftID, _ in
      editorState.trackDraft(draft.id)
      persistEditorSession(for: oldDraftID)
      dismissInsertedImageMetadata()
      cancelSelectionAIAction()
      cancelAIPromptClipboardTask()
      editorEditRequest = nil
      markdownTextFocusRequest = nil
      scrollSyncUpdate = nil
      store.flushDraftBodyEditorBuffer(for: oldDraftID)
      syncEditorBodyFromStore(force: true)
      restoreEditorSession(for: draft.id)
      syncActiveEditorSelection()
      scheduleMarkdownAnalysis(immediate: true)
    }
    .sheet(isPresented: $isShortcutHelpPresented) {
      MarkdownShortcutHelpPanel()
    }
    .sheet(isPresented: $isInternalLinkPickerPresented) {
      MarkdownInternalLinkPicker(
        draft: previewDraft,
        drafts: editorState.drafts,
        profile: editorState.profile(for: previewDraft),
        selectedText: selectedText(in: editorBody),
        onInsert: insertInternalLink,
        onOpenBacklink: { draftID in
          _ = store.focusDraft(draftID, section: .writing)
        },
        onInsertExternalLink: {
          applyMarkdownFormatting(.link)
        }
      )
    }
    .sheet(isPresented: $isDiagnosticsPresented) {
      MarkdownDiagnosticsPanel(
        diagnostics: inlineDiagnostics,
        onSelect: selectDiagnostic,
        onQuickFix: applyDiagnosticQuickFix
      )
    }
    .sheet(isPresented: $isSnippetLibraryPresented) {
      MarkdownSnippetLibraryPanel(
        draft: previewDraft,
        siteName: editorState.profile(for: previewDraft).name,
        storedCustomSnippets: store.customMarkdownSnippets,
        onInsert: insertSnippet,
        onSaveCustomSnippet: store.saveCustomMarkdownSnippet,
        onDeleteCustomSnippet: { snippet in
          store.deleteCustomMarkdownSnippet(
            id: snippet.id,
            siteProfileID: previewDraft.siteProfileID
          )
        }
      )
    }
    .onDisappear {
      markdownAnalysisTask?.cancel()
      markdownAnalysisTask = nil
      persistEditorSession(for: draft.id)
      cancelSelectionAIAction()
      cancelAIPromptClipboardTask()
      store.flushDraftBodyEditorBuffer(for: draft.id)
      store.clearActiveEditorSelection(for: draft.id)
    }
  }

  private var editorSurface: some View {
    Group {
      switch editorState.editorDisplayMode {
      case .edit:
        markdownEditor
          .padding(14)
      case .preview:
        markdownPreview
          .padding(14)
      case .split:
        HSplitView {
          markdownEditor
            .frame(minWidth: 320)
          markdownPreview
            .frame(minWidth: 320)
        }
        .padding(14)
      }
    }
    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
  }

  private var previewDraft: ArticleDraft {
    var updated = draft
    updated.bodyMarkdown = editorBody
    return updated
  }

  private var markdownPreview: some View {
    MarkdownPreviewPane(
      draft: previewDraft,
      isSynchronizedScrollingEnabled: $isSynchronizedScrollingEnabled,
      scrollSyncUpdate: scrollSyncUpdate,
      scrollRestorationUpdate: previewScrollRestorationUpdate,
      onScrollProgressChanged: { progress in
        updateSynchronizedScroll(source: .preview, progress: progress)
      }
    )
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  private var editorBufferRevision: UInt64 {
    editorState.draftBodyEditorBuffer(for: draft.id).revision
  }

  private func stageEditorBody(replacingBaseBody baseBodyMarkdown: String) {
    guard let result = store.stageDraftBody(
      editorBody,
      for: draft.id,
      baseRevision: editorBodyRevision,
      replacingBaseBody: baseBodyMarkdown
    ) else {
      return
    }

    editorBodyRevision = result.buffer.revision
    guard !result.wasAccepted else { return }

    editorBody = result.buffer.bodyMarkdown
    selectionActionMessage = "另一窗口已更新正文，刚才的陈旧修改未写入；已同步到最新版本。"
  }

  private func syncEditorBodyFromStore(force: Bool = false) {
    let buffer = editorState.draftBodyEditorBuffer(for: draft.id)
    guard force || buffer.revision != editorBodyRevision else { return }
    editorBody = buffer.bodyMarkdown
    editorBodyRevision = buffer.revision
  }

  @discardableResult
  private func applyDraftUpdate(_ updated: ArticleDraft) -> Bool {
    guard let result = store.replaceDraftBody(
      updated.bodyMarkdown,
      for: updated.id,
      expectedRevision: editorBodyRevision
    ) else { return false }
    editorBody = result.buffer.bodyMarkdown
    editorBodyRevision = result.buffer.revision
    guard result.wasAccepted else {
      selectionActionMessage = "另一窗口已更新正文，刚才的编辑命令未应用；已同步到最新版本。"
      return false
    }
    draft = updated
    return true
  }

  private var markdownEditor: some View {
    VStack(spacing: 0) {
      MacMarkdownFormattingToolbar(
        characterCount: editorStatistics.characterCount,
        hanCharacterCount: editorStatistics.hanCharacterCount,
        wordCount: editorStatistics.wordCount,
        writingUnitCount: editorStatistics.writingUnitCount,
        lineCount: editorStatistics.lineCount,
        readingMinutes: editorStatistics.readingMinutes,
        writingGoal: editorWritingGoal,
        onApplyMarkdownFormatting: applyMarkdownFormatting,
        onWrapSelection: { prefix, suffix, placeholder in
          wrapSelection(prefix: prefix, suffix: suffix, placeholder: placeholder)
        },
        onPrefixCurrentLine: prefixCurrentLine,
        onInsertCodeBlock: insertCodeBlock,
        onInsertTable: insertTable,
        onInsertHorizontalRule: insertHorizontalRule,
        onInsertInternalLink: {
          isInternalLinkPickerPresented = true
        },
        onShowSnippets: {
          isSnippetLibraryPresented = true
        },
        onShowDiagnostics: {
          showDiagnostics()
        },
        diagnosticCount: inlineDiagnostics.count,
        onInsertImage: {
          insertImageReferences(ImageSelectionPanel.chooseImages())
        },
        onInsertVideo: {
          insertVideoReferences(VideoSelectionPanel.chooseVideos())
        }
      )
      Divider()

      ZStack {
        Color(nsColor: .textBackgroundColor)

        MacMarkdownTextView(
          text: $editorBody,
          selectedRange: $selectedRange,
          comfortConfiguration: editorComfortConfiguration,
          diagnostics: inlineDiagnostics,
          editRequest: editorEditRequest,
          focusRequest: markdownTextFocusRequest,
          scrollSyncUpdate: isSynchronizedScrollingEnabled ? scrollSyncUpdate : nil,
          scrollRestorationUpdate: editorScrollRestorationUpdate,
          onStatisticsChanged: { editorStatistics = $0 },
          onFileDropTargetChanged: { isImageDropTargeted = $0 },
          onPasteMessage: { message in
            selectionActionMessage = message
            EditorAccessibilityAnnouncementCenter.announce(message)
          },
          onEditRequestHandled: { requestID in
            guard editorEditRequest?.id == requestID else { return }
            editorEditRequest = nil
          },
          onScrollProgressChanged: { progress in
            updateSynchronizedScroll(source: .editor, progress: progress)
          }
        ) { urls in
          insertImageReferences(urls)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if editorBody.trimmedForPublishing.isEmpty {
          Text("Markdown 正文")
            .font(.body)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        if isImageDropTargeted {
          ZStack {
            Color.accentColor.opacity(0.10)
            VStack(spacing: 8) {
              Image(systemName: "photo.badge.plus")
                .font(.system(size: 30, weight: .semibold))
              Text("拖入图片到当前文章")
                .font(.headline)
            }
            .foregroundStyle(.tint)
          }
          .overlay {
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
              .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
          }
          .allowsHitTesting(false)
          .accessibilityHidden(true)
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  private var canShowSelectionActions: Bool {
    SelectionActionBarPresentation.shouldShow(
      hasSelectedText: hasSelectedText,
      isSelectionAIActionRunning: isSelectionAIActionRunning,
      selectionActionMessage: selectionActionMessage
    )
  }

  private var hasSelectedText: Bool {
    !selectedText(in: editorBody).trimmedForPublishing.isEmpty
  }

  private var latestAssistantMessageForCurrentDraft: AIPublishingChatMessage? {
    editorState.latestAssistantMessage(for: draft.id)
  }

  private var isSelectionAIActionRunning: Bool {
    activeSelectionAIAction != nil || editorState.isAIActionRunning
  }

  private var isAIEnabledForDraft: Bool {
    let profile = editorState.profile(for: draft)
    return !profile.aiProviderConfig.requiresAPIKey || editorState.aiTokenAvailability.hasToken
  }

  private func articleAIActionAvailability(
    _ kind: AIPublishingActionKind,
    respectActiveAction: Bool = true
  ) -> AIPublishingActionAvailabilityPresentation {
    AIPublishingActionAvailabilityService.presentation(
      for: kind,
      draft: previewDraft,
      isAIEnabled: isAIEnabledForDraft,
      activeAction: respectActiveAction ? activeAIActionForAvailability(fallback: kind) : nil
    )
  }

  private func selectionAIActionAvailability(
    _ kind: AIPublishingActionKind,
    respectActiveAction: Bool = true
  ) -> AIPublishingActionAvailabilityPresentation {
    AIPublishingActionAvailabilityService.presentation(
      for: kind,
      selectedText: selectedText(in: editorBody),
      draft: previewDraft,
      isAIEnabled: isAIEnabledForDraft,
      activeAction: respectActiveAction ? activeAIActionForAvailability(fallback: kind) : nil
    )
  }

  private func activeAIActionForAvailability(fallback kind: AIPublishingActionKind) -> AIPublishingActionKind? {
    activeSelectionAIAction ?? (editorState.isAIActionRunning ? kind : nil)
  }

  private var selectionAIActionMenuItems: [AIPublishingActionMenuItem] {
    AIPublishingWritingActionCatalog.selectionActions
  }

  private var recommendedAIActionMenuItems: [AIPublishingActionMenuItem] {
    let recommendation = AIPublishingActionRecommendationService.recommendation(
      selectedText: selectedText(in: editorBody),
      draft: previewDraft
    )
    return recommendation.actions.prefix(4).map { kind in
      aiActionMenuItem(for: kind)
    }
  }

  private var moreAIActionMenuItems: [AIPublishingActionMenuItem] {
    let recommendedKinds = Set(recommendedAIActionMenuItems.map(\.kind))
    return allAIActionMenuItems.filter { !recommendedKinds.contains($0.kind) }
  }

  private var allAIActionMenuItems: [AIPublishingActionMenuItem] {
    var seen = Set<AIPublishingActionKind>()
    return (selectionAIActionMenuItems + AIPublishingWritingActionCatalog.articleActions).filter {
      seen.insert($0.kind).inserted
    }
  }

  private func aiActionMenuItem(for kind: AIPublishingActionKind) -> AIPublishingActionMenuItem {
    allAIActionMenuItems.first { $0.kind == kind }
      ?? AIPublishingActionMenuItem(kind: kind, systemImage: "sparkles")
  }

  private func isSelectionAIAction(_ kind: AIPublishingActionKind) -> Bool {
    selectionAIActionMenuItems.contains { $0.kind == kind }
  }

  private func insertImageReferences(_ urls: [URL]) {
    let imageURLs = ImageFileSupport.supportedImageURLs(in: urls)
    guard !imageURLs.isEmpty else {
      selectionActionMessage = "没有可插入的图片文件。"
      EditorAccessibilityAnnouncementCenter.announce(
        String(localized: "没有可插入的图片文件。"),
        priority: .high
      )
      return
    }

    var updated = previewDraft
    var markdownBlocks: [String] = []
    var insertedMetadata: [InsertedImageMetadataDraft] = []
    for url in imageURLs {
      let selectedAlt = selectedText(in: updated.bodyMarkdown).trimmedForPublishing
      var attachment = store.makeAttachment(from: url, draft: updated)
      if !selectedAlt.isEmpty {
        attachment.altText = selectedAlt
      }
      updated.attachments.append(attachment)
      markdownBlocks.append(
        imageMetadataEditingService.markdownReference(
          altText: attachment.altText,
          imagePath: attachment.relativePublishPath
        )
      )
      insertedMetadata.append(
        InsertedImageMetadataDraft(
          attachment: attachment,
          coverAttachmentID: updated.coverAttachmentID
        )
      )
    }

    let insertedDraft = replacingSelection(
      in: updated,
      with: markdownBlocks.joined(separator: "\n")
    )
    guard applyDraftUpdate(insertedDraft) else { return }

    insertedImageMetadataDrafts = insertedMetadata
    activeInsertedImageMetadataID = insertedMetadata.first?.id
    store.scheduleImageWorkbenchCachesRefresh(for: insertedDraft)
    selectionActionMessage = "已在光标位置插入 \(imageURLs.count) 张图片，请完善图片信息。"
    EditorAccessibilityAnnouncementCenter.announceImageInsertion(count: imageURLs.count)
  }

  private func insertVideoReferences(_ urls: [URL]) {
    let videoURLs = VideoFileSupport.supportedVideoURLs(in: urls)
    guard !videoURLs.isEmpty else {
      selectionActionMessage = "没有可插入的视频文件。"
      EditorAccessibilityAnnouncementCenter.announce(
        String(localized: "没有可插入的视频文件。"),
        priority: .high
      )
      return
    }

    var updated = previewDraft
    let selectedTitle = selectedText(in: updated.bodyMarkdown).trimmedForPublishing
    let htmlBlocks = videoURLs.map { url in
      let attachment = store.makeVideoAttachment(from: url, draft: updated)
      updated.attachments.append(attachment)
      let accessibleTitle = videoURLs.count == 1 && !selectedTitle.isEmpty
        ? selectedTitle
        : VideoFileSupport.accessibleTitle(for: url)
      return VideoFileSupport.htmlEmbed(
        publicPath: attachment.relativePublishPath,
        accessibleTitle: accessibleTitle
      )
    }

    let insertedDraft = replacingSelection(
      in: updated,
      with: htmlBlocks.joined(separator: "\n\n")
    )
    guard applyDraftUpdate(insertedDraft) else { return }
    selectionActionMessage = String(
      format: String(localized: "已在光标位置插入 %@ 个视频。"),
      "\(videoURLs.count)"
    )
    EditorAccessibilityAnnouncementCenter.announceVideoInsertion(count: videoURLs.count)
  }

  private var activeInsertedImageMetadataIndex: Int? {
    guard let activeInsertedImageMetadataID else { return nil }
    return insertedImageMetadataDrafts.firstIndex { $0.id == activeInsertedImageMetadataID }
  }

  private var activeInsertedImageMetadataBinding: Binding<InsertedImageMetadataDraft>? {
    guard let activeInsertedImageMetadataID,
          let index = activeInsertedImageMetadataIndex else {
      return nil
    }
    let fallback = insertedImageMetadataDrafts[index]
    return Binding(
      get: {
        insertedImageMetadataDrafts.first { $0.id == activeInsertedImageMetadataID } ?? fallback
      },
      set: { metadata in
        guard let currentIndex = insertedImageMetadataDrafts.firstIndex(where: {
          $0.id == activeInsertedImageMetadataID
        }) else { return }
        insertedImageMetadataDrafts[currentIndex] = metadata
      }
    )
  }

  private func setPendingImageCover(_ isCover: Bool, attachmentID: UUID) {
    for index in insertedImageMetadataDrafts.indices {
      if insertedImageMetadataDrafts[index].id == attachmentID {
        insertedImageMetadataDrafts[index].isCover = isCover
      } else if isCover {
        insertedImageMetadataDrafts[index].isCover = false
      }
    }
  }

  private func moveToPreviousInsertedImage() {
    guard let index = activeInsertedImageMetadataIndex, index > 0 else { return }
    activeInsertedImageMetadataID = insertedImageMetadataDrafts[index - 1].id
  }

  private func applyInsertedImageMetadataAndAdvance() {
    guard let index = activeInsertedImageMetadataIndex else { return }
    if index + 1 < insertedImageMetadataDrafts.count {
      let currentID = insertedImageMetadataDrafts[index].id
      guard applyInsertedImageMetadata(attachmentIDs: [currentID]) else { return }
      activeInsertedImageMetadataID = insertedImageMetadataDrafts[index + 1].id
      return
    }

    guard applyInsertedImageMetadata(
      attachmentIDs: Set(insertedImageMetadataDrafts.map(\.id))
    ) else { return }
    dismissInsertedImageMetadata()
  }

  private func openInsertedImageInspector() {
    guard let attachmentID = activeInsertedImageMetadataID else { return }
    guard applyInsertedImageMetadata(
      attachmentIDs: Set(insertedImageMetadataDrafts.map(\.id))
    ) else { return }
    guard store.focusImageInspector(draftID: draft.id, attachmentID: attachmentID) else {
      selectionActionMessage = "找不到刚插入的图片，请刷新图片 Inspector 后重试。"
      return
    }
    dismissInsertedImageMetadata()
  }

  private func applyInsertedImageMetadata(attachmentIDs: Set<UUID>) -> Bool {
    var updated = previewDraft
    for metadata in insertedImageMetadataDrafts where attachmentIDs.contains(metadata.id) {
      guard let result = imageMetadataEditingService.updating(
        draft: updated,
        attachmentID: metadata.id,
        altText: metadata.altText,
        caption: metadata.caption,
        isCover: metadata.isCover
      ) else {
        selectionActionMessage = "图片附件已变化，请重新插入或前往图片 Inspector 处理。"
        return false
      }
      updated = result.draft
    }

    guard applyDraftUpdate(updated) else { return false }
    store.scheduleImageWorkbenchCachesRefresh(for: updated, force: true)
    selectionActionMessage = "图片 alt、caption 和封面状态已更新。"
    return true
  }

  private func dismissInsertedImageMetadata() {
    insertedImageMetadataDrafts = []
    activeInsertedImageMetadataID = nil
  }

  private var commandActions: MarkdownEditorCommandActions {
    MarkdownEditorCommandActions(
      draftID: draft.id,
      canRewriteSelection: !selectedText(in: editorBody).trimmedForPublishing.isEmpty,
      canUseFindReplace: canUseFindReplace,
      showFindReplace: showFindReplace,
      showKeyboardShortcuts: {
        isShortcutHelpPresented = true
      },
      showSnippets: {
        isSnippetLibraryPresented = true
      },
      findPrevious: findPrevious,
      findNext: findNext,
      replaceCurrentOrNext: replaceCurrentOrNext,
      replaceAll: replaceAll,
      applyFormatting: applyMarkdownFormatting,
      insertImages: {
        insertImageReferences(ImageSelectionPanel.chooseImages())
      },
      runPreflight: runPreflightForCurrentDraft,
      rewriteSelection: rewriteSelectedText,
      openAIAssistant: showAIContextInspector,
      copyAIPrompt: pasteAIPromptToClipboard
    )
  }

  private var canUseFindReplace: Bool {
    guard !findQuery.isEmpty else { return false }
    return (try? findReplaceService.matches(
      in: editorBody,
      query: findQuery,
      options: findOptions
    )) != nil
  }

  private func updateSynchronizedScroll(
    source: MarkdownScrollSyncSource,
    progress: Double
  ) {
    let normalizedProgress = min(max(progress.isFinite ? progress : 0, 0), 1)
    switch source {
    case .editor:
      editorScrollProgress = normalizedProgress
      if isSynchronizedScrollingEnabled {
        previewScrollProgress = normalizedProgress
      }
    case .preview:
      previewScrollProgress = normalizedProgress
      if isSynchronizedScrollingEnabled {
        editorScrollProgress = normalizedProgress
      }
    }
    saveCurrentEditorSession()

    guard isSynchronizedScrollingEnabled else { return }
    scrollSyncUpdate = MarkdownScrollSyncUpdate(source: source, progress: normalizedProgress)
  }

  private func restoreEditorSession(for draftID: UUID) {
    let bodyUTF16Count = (editorBody as NSString).length
    let editorSession = store.markdownEditorSessionState(for: draftID)
      .normalized(bodyUTF16Count: bodyUTF16Count)

    selectedRange = editorSession.selectedRange(bodyUTF16Count: bodyUTF16Count)
    isFindReplacePresented = editorSession.isFindReplacePresented
    findQuery = editorSession.findQuery
    replacementText = editorSession.replacementText
    isFindCaseSensitive = editorSession.isFindCaseSensitive
    isFindWholeWord = editorSession.isFindWholeWord
    isFindRegularExpression = editorSession.isFindRegularExpression
    editorScrollProgress = editorSession.editorScrollProgress
    previewScrollProgress = editorSession.previewScrollProgress
    scrollSyncUpdate = nil
    editorScrollRestorationUpdate = MarkdownScrollSyncUpdate(
      source: .editor,
      progress: editorSession.editorScrollProgress
    )
    previewScrollRestorationUpdate = MarkdownScrollSyncUpdate(
      source: .preview,
      progress: editorSession.previewScrollProgress
    )
    findReplaceMessage = findQuery.isEmpty && isFindReplacePresented
      ? "输入查找内容。"
      : ""
  }

  private func currentEditorSessionState() -> MarkdownEditorSessionState {
    MarkdownEditorSessionState(
      selectedRange: selectedRange,
      editorScrollProgress: editorScrollProgress,
      previewScrollProgress: previewScrollProgress,
      isFindReplacePresented: isFindReplacePresented,
      findQuery: findQuery,
      replacementText: replacementText,
      isFindCaseSensitive: isFindCaseSensitive,
      isFindWholeWord: isFindWholeWord,
      isFindRegularExpression: isFindRegularExpression
    )
  }

  private func saveCurrentEditorSession() {
    persistEditorSession(for: draft.id)
  }

  private func persistEditorSession(for draftID: UUID) {
    store.updateMarkdownEditorSessionState(
      currentEditorSessionState(),
      for: draftID,
      bodyUTF16Count: (editorBody as NSString).length
    )
  }

  private var findOptions: MarkdownFindOptions {
    MarkdownFindOptions(
      caseSensitive: isFindCaseSensitive,
      wholeWord: isFindWholeWord,
      usesRegularExpression: isFindRegularExpression
    )
  }

  private var findMatchStatus: String {
    guard !findQuery.isEmpty else { return "0/0" }
    guard let position = try? findReplaceService.position(
      in: editorBody,
      query: findQuery,
      selectedRange: selectedRange,
      options: findOptions
    ) else {
      return "—/—"
    }
    return "\(position.currentNumber ?? 0)/\(position.total)"
  }

  private var findReplaceFeedbackMessage: String {
    guard !findQuery.isEmpty else { return findReplaceMessage }
    do {
      _ = try findReplaceService.matches(
        in: editorBody,
        query: findQuery,
        options: findOptions
      )
      return findReplaceMessage
    } catch {
      return error.localizedDescription
    }
  }

  private func showOutline() {
    isOutlinePresented = true
    scheduleMarkdownAnalysis(immediate: true, includeOutline: true)
  }

  private func showDiagnostics() {
    isDiagnosticsPresented = true
    guard appliedMarkdownAnalysisGeneration != markdownAnalysisGeneration else { return }
    scheduleMarkdownAnalysis(immediate: true)
  }

  private func scheduleMarkdownAnalysis(
    immediate: Bool = false,
    includeOutline: Bool? = nil
  ) {
    markdownAnalysisTask?.cancel()
    markdownAnalysisGeneration &+= 1
    let generation = markdownAnalysisGeneration
    let requestedMarkdown = editorBody
    let requestedDraftID = draft.id
    let shouldIncludeOutline = includeOutline ?? isOutlinePresented

    markdownAnalysisTask = Task { @MainActor in
      if !immediate {
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return
        }
      }
      guard !Task.isCancelled else { return }
      let snapshot = await markdownAnalysisService.analyzeInBackground(
        requestedMarkdown,
        includeOutline: shouldIncludeOutline
      )
      guard !Task.isCancelled,
            markdownAnalysisGeneration == generation,
            draft.id == requestedDraftID else { return }
      markdownAnalysis = snapshot
      appliedMarkdownAnalysisGeneration = generation
      markdownAnalysisTask = nil
    }
  }

  private func selectOutlineItem(_ item: MarkdownOutlineItem) {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }

    let bodyLength = (editorBody as NSString).length
    selectedRange = NSRange(
      location: min(max(item.headingLocation, 0), bodyLength),
      length: 0
    )
    selectionActionMessage = ""
  }

  private func performOutlineAction(
    _ action: MarkdownOutlineSectionAction,
    item: MarkdownOutlineItem
  ) {
    switch action {
    case .moveUp:
      applyOutlineEdit(
        outlineService.moveSectionEdit(in: editorBody, item: item, direction: .up),
        message: "已上移章节「\(item.title)」。"
      )
    case .moveDown:
      applyOutlineEdit(
        outlineService.moveSectionEdit(in: editorBody, item: item, direction: .down),
        message: "已下移章节「\(item.title)」。"
      )
    case .duplicate:
      applyOutlineEdit(
        outlineService.duplicateSectionEdit(in: editorBody, item: item),
        message: "已创建章节「\(item.title)」的副本。"
      )
    case .delete:
      applyOutlineEdit(
        outlineService.deleteSectionEdit(in: editorBody, item: item),
        message: "已删除章节「\(item.title)」，可撤销。"
      )
    case .copyAnchorLink:
      guard let anchorLink = outlineService.anchorLink(for: item, in: editorBody) else {
        selectionActionMessage = "章节已变化，请刷新大纲后重试。"
        return
      }
      ClipboardWriter.copy(
        anchorLink,
        successMessage: "已复制锚点链接：\(anchorLink)"
      ) { selectionActionMessage = $0 }
    }
  }

  private func applyOutlineEdit(_ edit: MarkdownSmartEdit?, message: String) {
    guard let edit else {
      selectionActionMessage = "章节已变化，请刷新大纲后重试。"
      return
    }
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    editorEditRequest = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
    selectionActionMessage = message
  }

  private func showFindReplace() {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    let selected = selectedText(in: editorBody).trimmedForPublishing
    if !selected.isEmpty, !selected.contains("\n") {
      findQuery = selected
    }
    isFindReplacePresented = true
    findReplaceMessage = findQuery.isEmpty ? "输入查找内容。" : ""
  }

  private func findNext() {
    find(.next)
  }

  private func findPrevious() {
    find(.previous)
  }

  private func find(_ direction: MarkdownFindDirection) {
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      EditorAccessibilityAnnouncementCenter.announceFindMessage(
        String(localized: "输入查找内容。")
      )
      return
    }

    do {
      guard let result = try findReplaceService.find(
        in: editorBody,
        query: findQuery,
        selectedRange: selectedRange,
        direction: direction,
        options: findOptions
      ) else {
        findReplaceMessage = "没有找到匹配。"
        EditorAccessibilityAnnouncementCenter.announceFindMessage(
          String(localized: "没有找到匹配。")
        )
        return
      }

      selectedRange = result.range
      if result.didWrap {
        findReplaceMessage = direction == .next
          ? "已从开头继续查找。"
          : "已从末尾继续查找。"
      } else {
        findReplaceMessage = ""
      }
      EditorAccessibilityAnnouncementCenter.announceFindResult(
        result,
        direction: direction
      )
    } catch {
      findReplaceMessage = error.localizedDescription
      EditorAccessibilityAnnouncementCenter.announceFindMessage(
        error.localizedDescription,
        isError: true
      )
    }
  }

  private func replaceCurrentOrNext() {
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      return
    }

    do {
      let mutation = try findReplaceService.replaceCurrentOrNext(
        in: editorBody,
        query: findQuery,
        replacement: replacementText,
        selectedRange: selectedRange,
        options: findOptions
      )

      guard mutation.replacementCount > 0 else {
        findReplaceMessage = "没有找到可替换内容。"
        return
      }

      applyFindReplaceMutation(mutation)
      findReplaceMessage = "已替换 1 处。"
    } catch {
      findReplaceMessage = error.localizedDescription
    }
  }

  private func replaceAll() {
    isFindReplacePresented = true
    guard !findQuery.isEmpty else {
      findReplaceMessage = "输入查找内容。"
      return
    }

    do {
      let mutation = try findReplaceService.replaceAll(
        in: editorBody,
        query: findQuery,
        replacement: replacementText,
        options: findOptions
      )

      guard mutation.replacementCount > 0 else {
        findReplaceMessage = "没有找到可替换内容。"
        return
      }

      applyFindReplaceMutation(mutation)
      findReplaceMessage = "已替换 \(mutation.replacementCount) 处，可撤销。"
    } catch {
      findReplaceMessage = error.localizedDescription
    }
  }

  private func applyFindReplaceMutation(_ mutation: MarkdownFindReplaceMutation) {
    if let edit = mutation.edit {
      editorEditRequest = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
      return
    }

    var updated = previewDraft
    updated.bodyMarkdown = mutation.text
    applyDraftUpdate(updated)
    selectedRange = mutation.selectedRange
  }

  private func replacingSelection(in draft: ArticleDraft, with markdown: String) -> ArticleDraft {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let needsLeadingBreak = range.location > 0 && !source.substring(to: range.location).hasSuffix("\n")
    let needsTrailingBreak = range.location + range.length < source.length
      && !source.substring(from: range.location + range.length).hasPrefix("\n")
    let insertion = "\(needsLeadingBreak ? "\n" : "")\(markdown)\(needsTrailingBreak ? "\n" : "")"
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: insertion)
    selectedRange = NSRange(location: range.location + (insertion as NSString).length, length: 0)
    return updated
  }

  private func replacingRawSelection(in draft: ArticleDraft, with text: String) -> ArticleDraft {
    var updated = draft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    updated.bodyMarkdown = source.replacingCharacters(in: range, with: text)
    selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
    return updated
  }

  private func applyMarkdownFormatting(_ command: MarkdownFormattingCommand) {
    guard !MarkdownFormattingResponderBridge.perform(command) else { return }
    let service = MarkdownFormattingService()
    guard let edit = service.edit(
      in: editorBody,
      selectedRange: selectedRange,
      command: command
    ) else { return }

    var updated = previewDraft
    updated.bodyMarkdown = (editorBody as NSString).replacingCharacters(
      in: edit.replacedRange,
      with: edit.replacement
    )
    applyDraftUpdate(updated)
    selectedRange = edit.selectedRange
  }

  private func wrapSelection(prefix: String, suffix: String, placeholder: String) {
    var updated = previewDraft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let selected = range.length > 0 ? source.substring(with: range) : placeholder
    let replacement = prefix + selected + suffix

    updated.bodyMarkdown = source.replacingCharacters(in: range, with: replacement)
    applyDraftUpdate(updated)

    let prefixLength = (prefix as NSString).length
    selectedRange = NSRange(location: range.location + prefixLength, length: (selected as NSString).length)
  }

  private func prefixCurrentLine(_ prefix: String) {
    replaceCurrentLines { line in
      line.hasPrefix(prefix) ? line : prefix + line
    }
  }

  private func replaceCurrentLines(_ transform: (String) -> String) {
    var updated = previewDraft
    let source = updated.bodyMarkdown as NSString
    let range = editingRange(in: source)
    let effectiveRange = NSRange(location: range.location, length: max(range.length, 0))
    let lineRange = source.lineRange(for: effectiveRange)
    let lineText = source.substring(with: lineRange)
    let lines = lineText.components(separatedBy: "\n")
    let transformed = lines.enumerated().map { index, line in
      if index == lines.count - 1, line.isEmpty {
        return line
      }
      return transform(line)
    }
    .joined(separator: "\n")

    updated.bodyMarkdown = source.replacingCharacters(in: lineRange, with: transformed)
    applyDraftUpdate(updated)
    selectedRange = NSRange(
      location: min(range.location, (updated.bodyMarkdown as NSString).length),
      length: range.length
    )
  }

  private func insertCodeBlock() {
    let selected = selectedText(in: editorBody).trimmedForPublishing
    let body = selected.isEmpty ? "code" : selected
    applyDraftUpdate(replacingSelection(in: previewDraft, with: "```\n\(body)\n```"))
  }

  private func insertTable() {
    let table = """
    | 列 1 | 列 2 |
    | --- | --- |
    | 内容 | 内容 |
    """
    let source = editorBody as NSString
    let insertionRange = editingRange(in: source)
    let updated = replacingSelection(in: previewDraft, with: table)
    guard applyDraftUpdate(updated) else { return }

    let updatedSource = updated.bodyMarkdown as NSString
    let searchStart = min(insertionRange.location, updatedSource.length)
    let searchRange = NSRange(
      location: searchStart,
      length: min(
        updatedSource.length - searchStart,
        (table as NSString).length + 2
      )
    )
    let insertedTableRange = updatedSource.range(of: table, options: [], range: searchRange)
    guard insertedTableRange.location != NSNotFound else { return }
    let firstHeaderRange = updatedSource.range(
      of: "列 1",
      options: [],
      range: insertedTableRange
    )
    if firstHeaderRange.location != NSNotFound {
      selectedRange = firstHeaderRange
    }
  }

  private func insertHorizontalRule() {
    applyDraftUpdate(replacingSelection(in: previewDraft, with: "---"))
  }

  private func insertInternalLink(_ suggestion: MarkdownInternalLinkSuggestion) {
    let markdown = MarkdownInternalLinkService.markdownLink(
      to: suggestion,
      selectedText: selectedText(in: editorBody)
    )
    guard applyDraftUpdate(replacingRawSelection(in: previewDraft, with: markdown)) else { return }
    selectionActionMessage = "已插入站内链接：\(suggestion.title)"
  }

  private func insertSnippet(_ snippet: MarkdownSnippet) {
    let markdown = MarkdownSnippetLibraryService.expandedMarkdown(for: snippet, draft: previewDraft)
    guard applyDraftUpdate(replacingSelection(in: previewDraft, with: markdown)) else { return }
    let kindName = snippet.kind == .articleTemplate ? "文章模板" : "正文片段"
    selectionActionMessage = "已插入\(kindName)：\(snippet.title)"
  }

  private func selectDiagnostic(_ diagnostic: MarkdownInlineDiagnostic) {
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    selectedRange = clamped(diagnostic.range, length: (editorBody as NSString).length)
    EditorAccessibilityAnnouncementCenter.announce(
      "已定位：\(diagnostic.title)",
      priority: .high
    )
  }

  private func applyDiagnosticQuickFix(_ diagnostic: MarkdownInlineDiagnostic) {
    guard let edit = MarkdownInlineDiagnosticService.quickFix(for: diagnostic, in: editorBody) else {
      selectionActionMessage = "这项诊断没有可自动应用的修复。"
      return
    }
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.edit)
    }
    editorEditRequest = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
    selectionActionMessage = "已修复：\(diagnostic.title)"
  }

  private func selectedText(in text: String) -> String {
    let source = text as NSString
    let range = clamped(selectedRange, length: source.length)
    guard range.length > 0 else { return "" }
    return source.substring(with: range)
  }

  private func editingRange(in source: NSString) -> NSRange {
    let range = clamped(selectedRange, length: source.length)
    if range.length > 0 {
      return range
    }
    return NSRange(location: source.length, length: 0)
  }

  private func syncActiveEditorSelection() {
    let source = editorBody as NSString
    let range = clamped(selectedRange, length: source.length)
    let selectedText = range.length > 0 ? source.substring(with: range) : ""
    store.updateActiveEditorSelection(
      draftID: draft.id,
      selectedRange: range,
      selectedText: selectedText,
      bodyUTF16Count: source.length
    )
  }

  private func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }

  private func pasteAIPromptToClipboard() {
    cancelAIPromptClipboardTask()
    let requestedDraft = previewDraft
    let requestedBody = requestedDraft.bodyMarkdown
    let requestID = UUID()
    aiPromptClipboardRequestID = requestID
    store.setPublishActionMessage(String(localized: "正在生成 AI Prompt…"))
    aiPromptClipboardTask = Task { @MainActor in
      let prompt = await store.publishingAIPromptInBackground(for: requestedDraft)
      guard !Task.isCancelled,
            aiPromptClipboardRequestID == requestID else {
        return
      }
      aiPromptClipboardTask = nil
      aiPromptClipboardRequestID = nil
      guard draft.id == requestedDraft.id,
            editorBody == requestedBody else {
        store.setPublishActionMessage(String(localized: "文章已变化，未复制陈旧 AI Prompt；请重试。"))
        return
      }
      ClipboardWriter.copy(
        prompt,
        successMessage: "已复制 AI Prompt。"
      ) { store.setPublishActionMessage($0) }
    }
  }

  private func cancelAIPromptClipboardTask() {
    aiPromptClipboardTask?.cancel()
    aiPromptClipboardTask = nil
    aiPromptClipboardRequestID = nil
  }

  private func applyEditorFocusRequest() {
    guard let request = editorState.editorFocusRequest, request.draftID == draft.id else {
      return
    }

    guard request.field == nil || request.field == "body" else {
      selectionActionMessage = "问题在 \(request.field ?? "元数据") 字段，右侧可直接处理。"
      return
    }

    let text = editorBody as NSString
    if let requestedRange = request.selectedRange,
       requestedRange.location >= 0,
       NSMaxRange(requestedRange) <= text.length {
      let expectedQuery = request.query?.trimmedForPublishing
      let selectedText = text.substring(with: requestedRange)
      if expectedQuery?.isEmpty != false
        || selectedText.compare(
          expectedQuery ?? "",
          options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) == .orderedSame {
        focusMarkdownText(
          for: request.id,
          selectedRange: requestedRange,
          message: "已定位到正文匹配内容。"
        )
        return
      }
    }

    if let query = request.query?.trimmedForPublishing, !query.isEmpty {
      let range = text.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
      )
      if range.location != NSNotFound {
        focusMarkdownText(
          for: request.id,
          selectedRange: range,
          message: "已定位到正文匹配内容。"
        )
        return
      }
    }

    focusMarkdownText(
      for: request.id,
      selectedRange: NSRange(location: 0, length: 0),
      message: "已定位到正文。"
    )
  }

  private func focusMarkdownText(
    for requestID: UUID,
    selectedRange: NSRange,
    message: String
  ) {
    self.selectedRange = selectedRange
    markdownTextFocusRequest = MarkdownTextFocusRequest(
      id: requestID,
      selectedRange: selectedRange
    )
    selectionActionMessage = message
  }

  private func runPreflightForCurrentDraft() {
    store.runPreflight()
    let issues = editorState.preflightIssues(for: previewDraft)
    EditorAccessibilityAnnouncementCenter.announceDiagnostics(issues)
    _ = store.focusDraft(draft.id, section: .contentHealth)
  }

  private func rewriteSelectedText() {
    performSelectionAIAction(.rewriteSelection)
  }

  private func performSelectionAIAction(_ kind: AIPublishingActionKind) {
    let rawSelectedText = selectedText(in: editorBody)
    let promptSelectedText = rawSelectedText.trimmedForPublishing
    let availability = selectionAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多上下文")"
      return
    }

    cancelSelectionAIAction()
    let requestedDraft = previewDraft
    let requestID = UUID()
    activeSelectionAIAction = kind
    selectionAIActionRequestID = requestID
    selectionActionMessage = "\(kind.localizedDisplayName)处理中..."
    let previewRange = clamped(selectedRange, length: (editorBody as NSString).length)
    selectionEditPreview = nil
    selectionAIActionTask = Task { @MainActor in
      let result = await aiActions.performAction(
        kind,
        draft: requestedDraft,
        selectedText: promptSelectedText
      )
      guard selectionAIActionRequestID == requestID else { return }
      defer { finishSelectionAIAction(requestID: requestID) }
      guard !Task.isCancelled, draft.id == requestedDraft.id else { return }

      if let result {
        let preview = AIPublishingSelectionEditPreview(
          draftID: requestedDraft.id,
          sourceBodyMarkdown: requestedDraft.bodyMarkdown,
          kind: result.kind,
          range: previewRange,
          originalText: rawSelectedText,
          replacementText: result.content,
          application: selectionEditApplication(for: result.kind),
          providerName: result.providerName,
          model: result.model
        )
        selectionEditPreview = preview
        selectionActionMessage = result.kind.localizedDisplayName + "预览已生成。"
        EditorAccessibilityAnnouncementCenter.announceAIPreview(
          kind: result.kind.localizedDisplayName,
          characterCount: (preview.trimmedReplacementText as NSString).length
        )
      } else {
        selectionActionMessage = kind.localizedDisplayName + "失败。"
        EditorAccessibilityAnnouncementCenter.announce(
          selectionActionMessage,
          priority: .high
        )
      }
    }
  }

  private func performArticleAIAction(_ kind: AIPublishingActionKind) {
    let availability = articleAIActionAvailability(kind, respectActiveAction: false)
    guard availability.isEnabled else {
      selectionActionMessage = "\(kind.localizedDisplayName)：\(availability.unavailableReason ?? "需要更多文章内容")"
      return
    }

    cancelSelectionAIAction()
    let requestedDraft = previewDraft
    let requestID = UUID()
    activeSelectionAIAction = kind
    selectionAIActionRequestID = requestID
    selectionActionMessage = "\(kind.localizedDisplayName)处理中..."
    let previewRange = articleInsertionRange(for: kind)
    selectionEditPreview = nil
    selectionAIActionTask = Task { @MainActor in
      let result = await aiActions.performAction(kind, draft: requestedDraft)
      guard selectionAIActionRequestID == requestID else { return }
      defer { finishSelectionAIAction(requestID: requestID) }
      guard !Task.isCancelled, draft.id == requestedDraft.id else { return }

      if let result {
        if result.kind.producesMetadataSuggestion, editorState.aiMetadataSuggestion != nil {
          selectionActionMessage = result.kind.localizedDisplayName + "已生成，可在元数据建议中应用。"
          EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
        } else {
          let preview = AIPublishingSelectionEditPreview(
            draftID: requestedDraft.id,
            sourceBodyMarkdown: requestedDraft.bodyMarkdown,
            kind: result.kind,
            range: previewRange,
            originalText: "",
            replacementText: result.content,
            application: .insertAtRange,
            providerName: result.providerName,
            model: result.model
          )
          selectionEditPreview = preview
          selectionActionMessage = result.kind.localizedDisplayName + "预览已生成。"
          EditorAccessibilityAnnouncementCenter.announceAIPreview(
            kind: result.kind.localizedDisplayName,
            characterCount: (preview.trimmedReplacementText as NSString).length
          )
        }
      } else {
        selectionActionMessage = kind.localizedDisplayName + "失败。"
        EditorAccessibilityAnnouncementCenter.announce(
          selectionActionMessage,
          priority: .high
        )
      }
    }
  }

  private func cancelSelectionAIAction() {
    selectionAIActionTask?.cancel()
    selectionAIActionTask = nil
    selectionAIActionRequestID = nil
    activeSelectionAIAction = nil
    selectionEditPreview = nil
  }

  private func finishSelectionAIAction(requestID: UUID) {
    guard selectionAIActionRequestID == requestID else { return }
    selectionAIActionTask = nil
    selectionAIActionRequestID = nil
    activeSelectionAIAction = nil
  }

  private func articleInsertionRange(for kind: AIPublishingActionKind) -> NSRange {
    let bodyLength = (editorBody as NSString).length
    switch kind {
    case .continueArticle, .draftArticleFAQ, .draftTroubleshootingSection, .draftReferencesSection:
      return NSRange(location: bodyLength, length: 0)
    case .draftOpening, .draftArticleTLDR:
      return NSRange(location: 0, length: 0)
    default:
      let location = min(max(selectedRange.location, 0), bodyLength)
      return NSRange(location: location, length: 0)
    }
  }

  private func selectionEditApplication(for kind: AIPublishingActionKind) -> AIPublishingSelectionEditApplication {
    switch kind {
    case .continueAfterSelection, .explainSelection:
      return .insertAfterRange
    default:
      return .replaceRange
    }
  }

  private func checkSelectedPublicRisk() {
    let selectedText = selectedText(in: editorBody).trimmedForPublishing
    guard !selectedText.isEmpty else {
      return
    }

    var probeDraft = previewDraft
    probeDraft.bodyMarkdown = selectedText
    let summary = PublicRiskSummary(issues: PublicRiskScanner().scan(draft: probeDraft))
    let content: String
    if summary.isClear {
      content = "选中文本未命中密钥、私钥、内网地址或本机路径规则。"
      selectionActionMessage = "选区未发现公开风险。"
    } else {
      let issueLines = summary.issues.map {
        "- \($0.severity.localizedDisplayName)：\($0.title) - \($0.message)"
      }
      content = "选中文本公开风险：\n\(issueLines.joined(separator: "\n"))"
      selectionActionMessage = "选区有 \(summary.issueCount) 项公开风险。"
    }
    aiActions.setActionResult(AIPublishingActionResult(kind: .privacyReview, content: content))
    aiActions.setActionMessage(selectionActionMessage)
  }

  private func applyLatestAIReplyToSelection() {
    guard let message = latestAssistantMessageForCurrentDraft else {
      selectionActionMessage = "当前文章还没有可应用的 AI 回复。"
      return
    }

    let range = clamped(selectedRange, length: (editorBody as NSString).length)
    guard range.length > 0 else {
      selectionActionMessage = "请先选择要替换的正文。"
      return
    }

    guard let result = AIPublishingChatDraftApplicationService.applyAssistantContent(
      message.content,
      to: previewDraft,
      mode: .replaceSelection,
      selectionRange: range
    ) else {
      selectionActionMessage = "AI 回复为空或选区无效。"
      return
    }

    let replacementLength = (message.content.trimmedForPublishing as NSString).length
    applyDraftUpdate(result.draft)
    selectedRange = NSRange(location: range.location + replacementLength, length: 0)
    selectionActionMessage = result.action.statusMessage
  }

  private func showAIContextInspector() {
    aiActions.openChatWorkspace(for: draft.id)
  }

  private func applySelectionEditPreview(_ preview: AIPublishingSelectionEditPreview) {
    do {
      let originalLength = (editorBody as NSString).length
      let updated = try AIPublishingSelectionEditPreviewService.apply(preview, to: previewDraft)
      let updatedLength = (updated.bodyMarkdown as NSString).length
      let insertedLength = max(0, updatedLength - originalLength)
      let newSelectionLocation: Int
      switch preview.application {
      case .replaceRange:
        newSelectionLocation = preview.range.location + (preview.trimmedReplacementText as NSString).length
      case .insertAfterRange:
        newSelectionLocation = preview.range.location + preview.range.length + insertedLength
      case .insertAtRange:
        newSelectionLocation = preview.range.location + insertedLength
      }
      applyDraftUpdate(updated)
      selectedRange = NSRange(location: newSelectionLocation, length: 0)
      selectionEditPreview = nil
      selectionActionMessage = "\(preview.kind.localizedDisplayName)已应用。"
    } catch {
      selectionActionMessage = error.localizedDescription
    }
  }

  private func discardSelectionEditPreview() {
    selectionEditPreview = nil
    selectionActionMessage = "已丢弃 AI 预览。"
  }
}
