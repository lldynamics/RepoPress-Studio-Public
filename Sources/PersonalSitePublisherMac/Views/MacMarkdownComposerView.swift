import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownComposerView: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  let aiActions: WorkbenchAIFeatureFacade
  @Environment(\.publishDrawerCommandAction) var publishDrawerCommandAction
  @EnvironmentObject var sceneCommandRouter: WorkspaceSceneCommandRouter
  @StateObject var editorState: WorkbenchMarkdownEditorFeatureFacade
  @StateObject var editorSessionState: MarkdownComposerEditorSessionState
  @State var attachmentState = MarkdownComposerAttachmentState()
  @State var selectionActionState = MarkdownComposerSelectionActionState()
  @State var presentationState = MarkdownComposerPresentationState()
  @State var analysisState = MarkdownComposerAnalysisState()
  @State var editorDocumentBodyOffsetCache: Int
  @State var markdownSSGDerivedData = MarkdownComposerSSGDerivedData.empty
  @State var editorSessionSaveTask: Task<Void, Never>?
  @State var sceneCommandOwnerID = UUID()
  @AppStorage("markdownEditorSynchronizedScrolling") var isSynchronizedScrollingEnabled = true
  @AppStorage("workspace.writingToolDensity") var writingToolDensityRawValue = MarkdownWritingToolDensity.basic.rawValue
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
  @AppStorage(MarkdownEditorComfortPreferences.automaticPairingEnabledKey)
  var isAutomaticPairingEnabled = MarkdownEditorComfortConfiguration.defaultAutomaticPairingEnabled
  @AppStorage(MarkdownEditorComfortPreferences.writingGoalKey)
  var editorWritingGoal = MarkdownEditorComfortConfiguration.defaultWritingGoal
  @AppStorage(MarkdownEditorDisplayModePreferences.siteArticleKey)
  var siteArticleDisplayModeRawValue = EditorDisplayMode.edit.rawValue
  @AppStorage(MarkdownEditorDisplayModePreferences.generalDraftKey)
  var generalDraftDisplayModeRawValue = EditorDisplayMode.edit.rawValue
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
      warmPaperBackgroundEnabled: isWarmPaperBackgroundEnabled,
      automaticPairingEnabled: isAutomaticPairingEnabled
    )
  }

  var activeProfile: SiteProfile {
    editorState.profile(for: draft)
  }

  var writingToolDensity: MarkdownWritingToolDensity {
    MarkdownWritingToolDensity(rawValue: writingToolDensityRawValue) ?? .basic
  }

  var markdownEditorToolbarActions: MarkdownEditorToolbarActions {
    MarkdownEditorToolbarActions(
      onSetEditorDisplayMode: setPreferredEditorDisplayMode,
      onSetWritingToolDensity: { writingToolDensityRawValue = $0.rawValue },
      onShowFindReplace: showFindReplace,
      onShowOutline: showOutline,
      onOpenWritingContextPanel: showWritingContextPanel,
      onShowShortcutHelp: {
        isShortcutHelpPresented = true
      },
      onPreparePublish: preparePublish,
      onOpenAIContextInspector: showAIContextInspector,
      onOpenAITemplateLibrary: {
        isAITemplateLibraryPresented = true
      },
      onExportDocument: performMarkdownDocumentExport,
      selectionAIActionAvailability: { kind in
        selectionAIActionAvailability(kind)
      },
      articleAIActionAvailability: { kind in
        articleAIActionAvailability(kind)
      },
      onPerformSelectionAIAction: performSelectionAIAction,
      onPerformArticleAIAction: performArticleAIAction,
      onPerformConvergedSelectionAIAction: performConvergedSelectionAIAction,
      onPerformConvergedArticleAIAction: performConvergedArticleAIAction,
      onPasteAIPromptToClipboard: pasteAIPromptToClipboard
    )
  }

  var preferredEditorDisplayMode: EditorDisplayMode {
    MarkdownEditorDisplayModePreferences.mode(
      for: MarkdownEditorDisplayModePreferenceScope(
        isGeneralDraft: draft.isGeneralDraft
      ),
      siteArticleRawValue: siteArticleDisplayModeRawValue,
      generalDraftRawValue: generalDraftDisplayModeRawValue
    )
  }

  func setPreferredEditorDisplayMode(_ mode: EditorDisplayMode) {
    if draft.isGeneralDraft {
      generalDraftDisplayModeRawValue = mode.rawValue
    } else {
      siteArticleDisplayModeRawValue = mode.rawValue
    }
    store.setEditorDisplayMode(mode)
  }

  func restorePreferredEditorDisplayMode() {
    guard store.editorDisplayMode != preferredEditorDisplayMode else { return }
    store.setEditorDisplayMode(preferredEditorDisplayMode)
  }

  var canonicalFrontMatter: String {
    frontMatterEditingService.render(draft: draft, profile: activeProfile)
  }

  var editorDocumentParts: MarkdownFrontMatterDocumentParts? {
    frontMatterEditingService.splitDocument(editorDocument, profile: activeProfile)
  }

  var editorDocumentBodyOffset: Int {
    editorDocumentBodyOffsetCache
  }

  init(draft: Binding<ArticleDraft>, store: WorkbenchStore) {
    _draft = draft
    let initialDraft = draft.wrappedValue
    let draftID = initialDraft.id
    let initialBuffer = store.draftBodyEditorBuffer(for: draftID)
    let initialDocument = MarkdownFrontMatterEditingService().renderDocument(
      draft: initialDraft,
      profile: store.profile(for: initialDraft),
      bodyMarkdown: initialBuffer.bodyMarkdown
    )
    let initialBodyOffset = (initialDocument as NSString).length
      - (initialBuffer.bodyMarkdown as NSString).length
    _editorDocumentBodyOffsetCache = State(initialValue: initialBodyOffset)
    _editorSessionState = StateObject(
      wrappedValue: Self.makeInitialEditorSessionState(
        draft: initialDraft,
        store: store
      )
    )
    self.store = store
    aiActions = store.ai
    _editorState = StateObject(
      wrappedValue: WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: draftID)
    )
  }

  @MainActor
  private static func makeInitialEditorSessionState(
    draft: ArticleDraft,
    store: WorkbenchStore
  ) -> MarkdownComposerEditorSessionState {
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    let bodyUTF16Count = (buffer.bodyMarkdown as NSString).length
    let editorSession = store.markdownEditorSessionState(for: draft.id)
      .normalized(bodyUTF16Count: bodyUTF16Count)
    let editorDocument = MarkdownFrontMatterEditingService().renderDocument(
      draft: draft,
      profile: store.profile(for: draft),
      bodyMarkdown: buffer.bodyMarkdown
    )
    let findMatchSnapshot = makeFindMatchSnapshot(
      text: buffer.bodyMarkdown,
      query: editorSession.findQuery,
      options: MarkdownFindOptions(
        caseSensitive: editorSession.isFindCaseSensitive,
        wholeWord: editorSession.isFindWholeWord,
        usesRegularExpression: editorSession.isFindRegularExpression
      )
    )
    let state = MarkdownComposerEditorSessionState(
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
    state.findReplaceMessage = editorSession.findQuery.isEmpty && editorSession.isFindReplacePresented
      ? "输入查找内容。"
      : ""
    return state
  }

  private var editorWorkspaceLifecycle: some View {
    VStack(spacing: 0) {
      MacMarkdownEditorToolbar(
        title: $draft.title,
        store: store,
        markdownPath: editorState.profile(for: draft).markdownPath(for: draft),
        lastSaveStatus: editorState.lastSaveStatus,
        hasUnsavedChanges: editorState.hasUnsavedChanges,
        editorDisplayMode: editorState.editorDisplayMode,
        isSelectionAIActionRunning: isSelectionAIActionRunning,
        writingToolDensity: writingToolDensity,
        availableWritingContextPanels: availableWritingContextPanels,
        actions: markdownEditorToolbarActions
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
      editorOverlaySurface
    }
    .onChange(of: commandActions.sceneCommandPresentation, initial: true) { _, _ in
      sceneCommandRouter.registerMarkdownEditor(
        commandActions,
        owner: sceneCommandOwnerID
      )
    }
    .task {
      // Editor restoration updates shared selection and presentation state.
      // Do it after the mounting transaction so ObservableObject publishers
      // never fire while SwiftUI is still installing focused values.
      await MainRunLoopUpdateDeferral.waitForNextDefaultModeCycle()
      guard !Task.isCancelled else { return }
      restorePreferredEditorDisplayMode()
      syncEditorBodyFromStore()
      syncActiveEditorSelection()
      applyEditorFocusRequest()
      scheduleMarkdownAnalysis(immediate: true)
      scheduleInlineGhostText()
    }
    .onChange(of: editorState.editorFocusRequest?.id) { _, _ in
      applyEditorFocusRequest()
    }
    .onChange(of: selectedRange) { oldRange, newRange in
      if !NSEqualRanges(oldRange, newRange) {
        isInlineSelectionPaletteDismissed = false
        if let selectionEditPreview,
           !NSEqualRanges(selectionEditPreview.range, newRange) {
          self.selectionEditPreview = nil
          isInlineSelectionAIAction = false
        }
      }
      syncActiveEditorSelection()
      saveCurrentEditorSession()
      scheduleInlineGhostText()
    }
    .onChange(of: editorBody) { _, _ in
      scheduleInlineGhostText()
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
      flushEditorSessionSave(for: oldDraftID)
      cancelAttachmentImport()
      dismissInsertedImageMetadata()
      cancelSelectionAIAction()
      cancelInlineGhostText()
      activeWritingContextPanel = nil
      cancelAIPromptClipboardTask()
      editorEditRequest = nil
      markdownTextFocusRequest = nil
      scrollSyncUpdate = nil
      store.flushDraftBodyEditorBuffer(for: oldDraftID)
      syncEditorBodyFromStore(force: true)
      resetEditorDocumentFromDraft()
      restoreEditorSession(for: draft.id)
      restorePreferredEditorDisplayMode()
      syncActiveEditorSelection()
      scheduleMarkdownAnalysis(immediate: true)
    }
    .onChange(of: draft.isGeneralDraft) { _, _ in
      restorePreferredEditorDisplayMode()
    }
  }

  private var editorOverlaySurface: some View {
    ZStack(alignment: .top) {
      editorSurface
      insertedImageMetadataOverlay
      writingContextPanelOverlay
    }
  }

  @ViewBuilder
  private var insertedImageMetadataOverlay: some View {
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

  @ViewBuilder
  private var writingContextPanelOverlay: some View {
    if let panel = activeWritingContextPanel {
      HStack {
        Spacer(minLength: 0)
        MarkdownWritingContextPanelContainer(
          selectedPanel: panel,
          availablePanels: availableWritingContextPanels,
          onSelectPanel: showWritingContextPanel,
          onClose: dismissWritingContextPanel
        ) {
          writingContextPanelContent(for: panel)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .zIndex(4)
    }
  }

  var body: some View {
    editorWorkspaceLifecycle
    .task(id: markdownSSGDerivedDataKey) {
      await refreshMarkdownSSGDerivedData(for: markdownSSGDerivedDataKey)
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
    .onDisappear(perform: handleComposerDisappear)
  }

  private func handleComposerDisappear() {
    sceneCommandRouter.unregisterMarkdownEditor(owner: sceneCommandOwnerID)
    editorSessionSaveTask?.cancel()
    editorSessionSaveTask = nil
    markdownAnalysisTask?.cancel()
    markdownAnalysisTask = nil
    cancelAttachmentImport()
    persistEditorSession(for: draft.id)
    cancelSelectionAIAction()
    cancelInlineGhostText()
    cancelAIPromptClipboardTask()
    store.clearActiveEditorSelection(for: draft.id)
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
      profile: activeProfile,
      showsSynchronizedScrollingControl: editorState.editorDisplayMode == .split,
      isSynchronizedScrollingEnabled: $isSynchronizedScrollingEnabled,
      scrollSyncUpdate: scrollSyncUpdate,
      scrollRestorationUpdate: previewScrollRestorationUpdate,
      onScrollProgressChanged: { progress in
        updateSynchronizedScroll(source: .preview, progress: progress)
      },
      onSourceLocationSelected: { location in
        if editorState.editorDisplayMode == .preview {
          store.setEditorDisplayMode(.split)
        }
        focusMarkdownText(
          for: UUID(),
          selectedRange: NSRange(location: location, length: 0),
          message: "已从预览定位到 Markdown 源码。"
        )
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
        cursorPosition: markdownCursorPosition,
        fenceMatch: activeMarkdownFenceMatch,
        completion: markdownCursorCompletion,
        writingToolDensity: writingToolDensity,
        onApplyMarkdownFormatting: applyMarkdownFormatting,
        onApplyAdvancedFormatting: applyAdvancedMarkdownFormatting,
        onEditLines: applyMarkdownLineEditing,
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
        },
        onJumpToLine: jumpToMarkdownLine,
        onJumpToCounterpartFence: jumpToCounterpartFence,
        onApplyCompletion: applyMarkdownCompletion,
        onInsertCompletionTrigger: insertMarkdownCompletionTrigger
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
          ghostText: inlineGhostText,
          ssgSnippets: markdownSSGSnippets,
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
          onGhostTextAccepted: { _ in
            acceptInlineGhostText()
          },
          onGhostTextDismissed: {
            dismissInlineGhostText()
          },
          onSSGSnippetShortcut: { candidate in
            handleAutomaticSSGSnippetShortcut(candidate)
          },
          onScrollProgressChanged: { progress in
            updateSynchronizedScroll(source: .editor, progress: progress)
          },
          onDroppedFiles: { urls in
            insertImageReferences(urls)
          },
          onDroppedMarkdown: { markdown, range, citation in
            insertKnowledgeMarkdown(markdown, at: range, citation: citation)
          }
        )
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

        if shouldShowInlineSelectionPalette {
          InlineSelectionFloatingPalette(
            isProcessing: isInlineSelectionAIAction && activeSelectionAIAction != nil,
            activeActionName: activeSelectionAIAction?.localizedDisplayName,
            preview: isInlineSelectionAIAction ? selectionEditPreview : nil,
            actionMessage: selectionActionMessage,
            availabilityForAction: inlineSelectionAIActionAvailability,
            onPerformAction: performInlineSelectionAIAction,
            onPerformConvergedAction: performInlineConvergedSelectionAIAction,
            onApplyPreview: {
              guard let selectionEditPreview else { return }
              applySelectionEditPreview(selectionEditPreview)
            },
            onDiscardPreview: discardSelectionEditPreview,
            onCancel: cancelSelectionAIAction,
            onDismiss: {
              isInlineSelectionPaletteDismissed = true
            }
          )
          .padding(.horizontal, 12)
          .padding(.top, 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .transition(.move(edge: .top).combined(with: .opacity))
          .zIndex(5)
        }
      }

      .animation(WorkbenchMotion.standard, value: shouldShowInlineSelectionPalette)
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if !markdownSSGComponentOccurrences.isEmpty {
        Divider()
        MarkdownSSGComponentPreviewStrip(
          occurrences: markdownSSGComponentOccurrences,
          onSelect: focusSSGComponentOccurrence
        )
        .frame(height: 118)
      }

      MacMarkdownWritingGoalStatusBar(
        currentCount: editorStatistics.writingUnitCount,
        writingGoal: $editorWritingGoal
      )
    }
    .background(WorkbenchWritingSurface.color(usesWarmPaper: isWarmPaperBackgroundEnabled))
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

}
