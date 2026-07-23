import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownComposerView: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  let aiActions: WorkbenchAIFeatureFacade
  @StateObject var editorState: WorkbenchMarkdownEditorFeatureFacade
  @State var editorSessionState: MarkdownComposerEditorSessionState
  @State var attachmentState = MarkdownComposerAttachmentState()
  @State var selectionActionState = MarkdownComposerSelectionActionState()
  @State var presentationState = MarkdownComposerPresentationState()
  @State var analysisState = MarkdownComposerAnalysisState()
  @AppStorage("markdownEditorSynchronizedScrolling") var isSynchronizedScrollingEnabled = true
  @AppStorage(MarkdownEditorComfortPreferences.fontSizeKey)
  var editorFontSize = MarkdownEditorComfortConfiguration.defaultFontSize
  @AppStorage(MarkdownEditorComfortPreferences.lineSpacingKey)
  var editorLineSpacing = MarkdownEditorComfortConfiguration.defaultLineSpacing
  @AppStorage(MarkdownEditorComfortPreferences.bodyWidthKey)
  var editorBodyWidth = MarkdownEditorComfortConfiguration.defaultBodyWidth
  @AppStorage(MarkdownEditorComfortPreferences.spellCheckEnabledKey)
  var isEditorSpellCheckEnabled = MarkdownEditorComfortConfiguration.defaultSpellCheckEnabled
  @AppStorage(MarkdownEditorComfortPreferences.typewriterModeEnabledKey)
  var isTypewriterModeEnabled = MarkdownEditorComfortConfiguration.defaultTypewriterModeEnabled
  @AppStorage(MarkdownEditorComfortPreferences.currentParagraphHighlightEnabledKey)
  var isCurrentParagraphHighlightEnabled = MarkdownEditorComfortConfiguration.defaultCurrentParagraphHighlightEnabled
  @AppStorage(MarkdownEditorComfortPreferences.warmPaperBackgroundEnabledKey)
  var isWarmPaperBackgroundEnabled = MarkdownEditorComfortConfiguration.defaultWarmPaperBackgroundEnabled
  @AppStorage(MarkdownEditorComfortPreferences.writingGoalKey)
  var editorWritingGoal = MarkdownEditorComfortConfiguration.defaultWritingGoal
  let findReplaceService = MarkdownFindReplaceService()
  let outlineService = MarkdownOutlineService()
  let markdownAnalysisService = MarkdownEditorAnalysisService()
  let imageMetadataEditingService = ImageMetadataEditingService()
  let frontMatterEditingService = MarkdownFrontMatterEditingService()
  let selectionEditingService = MarkdownComposerSelectionEditingService()

  var inlineDiagnostics: [MarkdownInlineDiagnostic] {
    guard appliedMarkdownAnalysisGeneration == markdownAnalysisGeneration else { return [] }
    return markdownAnalysis.diagnostics
  }

  var outlineItems: [MarkdownOutlineItem] {
    guard appliedMarkdownAnalysisGeneration == markdownAnalysisGeneration else { return [] }
    return markdownAnalysis.outlineItems
  }

  var editorComfortConfiguration: MarkdownEditorComfortConfiguration {
    MarkdownEditorComfortConfiguration(
      fontSize: editorFontSize,
      lineSpacing: editorLineSpacing,
      bodyWidth: editorBodyWidth,
      spellCheckEnabled: isEditorSpellCheckEnabled,
      typewriterModeEnabled: isTypewriterModeEnabled,
      currentParagraphHighlightEnabled: isCurrentParagraphHighlightEnabled,
      warmPaperBackgroundEnabled: isWarmPaperBackgroundEnabled
    )
  }

  var activeProfile: SiteProfile {
    editorState.profile(for: draft)
  }

  var canonicalFrontMatter: String {
    frontMatterEditingService.render(draft: draft, profile: activeProfile)
  }

  var editorDocumentParts: MarkdownFrontMatterDocumentParts? {
    frontMatterEditingService.splitDocument(editorDocument, profile: activeProfile)
  }

  var editorDocumentBodyOffset: Int {
    if let editorDocumentParts {
      return editorDocumentParts.bodyUTF16Offset
    }
    let canonicalDocument = frontMatterEditingService.renderDocument(
      draft: draft,
      profile: activeProfile,
      bodyMarkdown: editorBody
    )
    return frontMatterEditingService
      .splitDocument(canonicalDocument, profile: activeProfile)?
      .bodyUTF16Offset ?? 0
  }

  init(draft: Binding<ArticleDraft>, store: WorkbenchStore) {
    _draft = draft
    let draftID = draft.wrappedValue.id
    let buffer = store.draftBodyEditorBuffer(for: draftID)
    let bodyUTF16Count = (buffer.bodyMarkdown as NSString).length
    let editorSession = store.markdownEditorSessionState(for: draftID)
      .normalized(bodyUTF16Count: bodyUTF16Count)
    let editorDocument = MarkdownFrontMatterEditingService().renderDocument(
        draft: draft.wrappedValue,
        profile: store.profile(for: draft.wrappedValue),
        bodyMarkdown: buffer.bodyMarkdown
    )
    let findMatchSnapshot = Self.makeFindMatchSnapshot(
        text: buffer.bodyMarkdown,
        query: editorSession.findQuery,
        options: MarkdownFindOptions(
          caseSensitive: editorSession.isFindCaseSensitive,
          wholeWord: editorSession.isFindWholeWord,
          usesRegularExpression: editorSession.isFindRegularExpression
        )
    )
    _editorSessionState = State(
      initialValue: MarkdownComposerEditorSessionState(
        editorBody: buffer.bodyMarkdown,
        editorDocument: editorDocument,
        selectedRange: editorSession.selectedRange(bodyUTF16Count: bodyUTF16Count),
        isFindReplacePresented: editorSession.isFindReplacePresented,
        findQuery: editorSession.findQuery,
        replacementText: editorSession.replacementText,
        isFindCaseSensitive: editorSession.isFindCaseSensitive,
        isFindWholeWord: editorSession.isFindWholeWord,
        isFindRegularExpression: editorSession.isFindRegularExpression,
        findMatchSnapshot: findMatchSnapshot,
        editorScrollRestorationUpdate: MarkdownScrollSyncUpdate(
        source: .editor,
        progress: editorSession.editorScrollProgress
        ),
        previewScrollRestorationUpdate: MarkdownScrollSyncUpdate(
        source: .preview,
        progress: editorSession.previewScrollProgress
        ),
        editorScrollProgress: editorSession.editorScrollProgress,
        previewScrollProgress: editorSession.previewScrollProgress,
        editorBodyRevision: buffer.revision
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
        isOutlinePresented: $presentationState.isOutlinePresented,
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
        onOpenAITemplateLibrary: {
          isAITemplateLibraryPresented = true
        },
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
          findQuery: $editorSessionState.findQuery,
          replacementText: $editorSessionState.replacementText,
          isFindCaseSensitive: $editorSessionState.isFindCaseSensitive,
          isFindWholeWord: $editorSessionState.isFindWholeWord,
          isFindRegularExpression: $editorSessionState.isFindRegularExpression,
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
            onOpenAITemplateLibrary: {
              isAITemplateLibraryPresented = true
            },
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
    .onChange(of: isFrontMatterSelection) { _, isSelected in
      if isSelected {
        store.clearActiveEditorSelection(for: draft.id)
      } else {
        syncActiveEditorSelection()
      }
    }
    .onChange(of: findQuery) { _, _ in
      findReplaceMessage = ""
      refreshFindMatchSnapshot()
      saveCurrentEditorSession()
    }
    .onChange(of: findOptions) { _, _ in
      findReplaceMessage = ""
      refreshFindMatchSnapshot()
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
    .modifier(
      MarkdownDocumentSynchronizationModifier(
        editorDocument: editorDocument,
        editorBody: editorBody,
        canonicalFrontMatter: canonicalFrontMatter,
        onEditorDocumentChange: applyEditorDocument,
        onEditorBodyChange: handleEditorBodyChange,
        onCanonicalFrontMatterChange: handleCanonicalFrontMatterChange
      )
    )
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
      resetEditorDocumentFromDraft()
      restoreEditorSession(for: draft.id)
      syncActiveEditorSelection()
      scheduleMarkdownAnalysis(immediate: true)
    }
    .sheet(isPresented: $presentationState.isShortcutHelpPresented) {
      MarkdownShortcutHelpPanel()
    }
    .sheet(isPresented: $presentationState.isInternalLinkPickerPresented) {
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
    .sheet(isPresented: $presentationState.isDiagnosticsPresented) {
      MarkdownDiagnosticsPanel(
        diagnostics: inlineDiagnostics,
        onSelect: selectDiagnostic,
        onQuickFix: applyDiagnosticQuickFix
      )
    }
    .sheet(isPresented: $presentationState.isSnippetLibraryPresented) {
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
    .sheet(isPresented: $presentationState.isAITemplateLibraryPresented) {
      AIPublishingTemplateLibraryView(
        draft: previewDraft,
        selectedText: selectedText(in: editorBody),
        availabilityForAction: { kind in
          if isSelectionAIAction(kind) {
            selectionAIActionAvailability(kind, respectActiveAction: false)
          } else {
            articleAIActionAvailability(kind, respectActiveAction: false)
          }
        },
        onPerformAction: performTemplateLibraryAction,
        onUsePrompt: openTemplateLibraryPrompt
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

  var editorSurface: some View {
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

  var previewDraft: ArticleDraft {
    var updated = draft
    updated.bodyMarkdown = editorBody
    return updated
  }

  var markdownPreview: some View {
    MarkdownPreviewPane(
      draft: previewDraft,
      showsSynchronizedScrollingControl: editorState.editorDisplayMode == .split,
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

  var markdownEditor: some View {
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
          guard requireBodyEditingContext() else { return }
          isInternalLinkPickerPresented = true
        },
        onShowSnippets: {
          guard requireBodyEditingContext() else { return }
          isSnippetLibraryPresented = true
        },
        onShowDiagnostics: {
          showDiagnostics()
        },
        diagnosticCount: inlineDiagnostics.count,
        onInsertImage: {
          guard requireBodyEditingContext() else { return }
          insertImageReferences(ImageSelectionPanel.chooseImages())
        },
        onInsertVideo: {
          guard requireBodyEditingContext() else { return }
          insertVideoReferences(VideoSelectionPanel.chooseVideos())
        }
      )
      Divider()

      ZStack {
        WorkbenchWritingSurface.color(usesWarmPaper: isWarmPaperBackgroundEnabled)

        MacMarkdownTextView(
          text: $editorSessionState.editorDocument,
          bodyMarkdown: editorBody,
          bodyUTF16Offset: editorDocumentBodyOffset,
          selectedRange: $editorSessionState.selectedRange,
          isFrontMatterSelection: $editorSessionState.isFrontMatterSelection,
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

        if frontMatterIssue != nil {
          Label("Front Matter 格式", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .allowsHitTesting(false)
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
    .background(WorkbenchWritingSurface.color(usesWarmPaper: isWarmPaperBackgroundEnabled))
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

}
