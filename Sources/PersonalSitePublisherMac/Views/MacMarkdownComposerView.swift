import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownComposerView: View {
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  let aiActions: WorkbenchAIFeatureFacade
  @Environment(\.publishDrawerCommandAction) var publishDrawerCommandAction
  @Environment(\.aiChatWorkspaceCommandAction) var aiChatWorkspaceCommandAction
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
  @EnvironmentObject var sceneCommandRouter: WorkspaceSceneCommandRouter
  @StateObject var editorState: WorkbenchMarkdownEditorFeatureFacade
  @StateObject var editorSessionState: MarkdownComposerEditorSessionState
  /// Stored as reference state rather than an observed object so delayed
  /// whole-document statistics invalidate only the formatting toolbar that
  /// observes this model, not the complete composer hierarchy.
  @State var editorStatisticsState = MarkdownComposerStatisticsState()
  @StateObject var zenModeController = ZenModeController()
  @State var attachmentState = MarkdownComposerAttachmentState()
  @State var selectionActionState = MarkdownComposerSelectionActionState()
  @State var presentationState = MarkdownComposerPresentationState()
  @State var analysisState = MarkdownComposerAnalysisState()
  @State var editorDocumentBodyOffsetCache: Int
  @State var markdownSSGDerivedData = MarkdownComposerSSGDerivedData.empty
  @State var editorSessionSaveTask: Task<Void, Never>?
  @State var editorSessionSaveGeneration: UInt64 = 0
  @StateObject var findMatchRefreshCoordinator = MarkdownFindMatchRefreshCoordinator()
  @State var markdownAnalysisTaskIsAutomatic = false
  @State var sceneCommandOwnerID = UUID()
  @AppStorage("workspace.writingToolDensity") var writingToolDensityRawValue =
    MarkdownWritingToolDensity.basic.rawValue
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
  var isCurrentParagraphHighlightEnabled = MarkdownEditorComfortConfiguration
    .defaultCurrentParagraphHighlightEnabled
  @AppStorage(MarkdownEditorComfortPreferences.warmPaperBackgroundEnabledKey)
  var isWarmPaperBackgroundEnabled = MarkdownEditorComfortConfiguration
    .defaultWarmPaperBackgroundEnabled
  @AppStorage(MarkdownEditorComfortPreferences.automaticPairingEnabledKey)
  var isAutomaticPairingEnabled = MarkdownEditorComfortConfiguration.defaultAutomaticPairingEnabled
  @AppStorage(MarkdownEditorComfortPreferences.paragraphSpotlightEnabledKey)
  var isParagraphSpotlightEnabled = MarkdownEditorComfortConfiguration
    .defaultParagraphSpotlightEnabled
  @AppStorage(MarkdownEditorComfortPreferences.realtimeAnalysisEnabledKey)
  var isRealtimeAnalysisEnabled = MarkdownEditorComfortConfiguration
    .defaultRealtimeAnalysisEnabled
  @State private var slashCommandQuery: String? = nil
  @State private var isSlashMenuPresented: Bool = false
  @State private var slashCommandSelectedIndex = 0
  @AppStorage(AIWritingPreferences.automaticInlineCompletionEnabledKey)
  var isAutomaticInlineAICompletionEnabled =
    AIWritingPreferences.defaultAutomaticInlineCompletionEnabled
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
    let aiAvailability = markdownComposerAIAvailabilitySnapshot
    return MarkdownEditorToolbarActions(
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
      // Menu state is render-local; action handlers below still read live state.
      selectionAIActionAvailability: { kind in
        aiAvailability.selectionAvailability(for: kind)
      },
      articleAIActionAvailability: { kind in
        aiAvailability.articleAvailability(for: kind)
      },
      onPerformSelectionAIAction: performSelectionAIAction,
      onPerformArticleAIAction: performArticleAIAction,
      onPerformConvergedSelectionAIAction: performConvergedSelectionAIAction,
      onPerformConvergedArticleAIAction: performConvergedArticleAIAction,
      onPasteAIPromptToClipboard: pasteAIPromptToClipboard,
      onFormatChineseTypography: formatChineseTypography,
      onCopyForWeChatAndZhihu: copyForWeChatAndZhihu
    )
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

  init(
    draft: Binding<ArticleDraft>,
    store: WorkbenchStore
  ) {
    _draft = draft
    let initialDraft = draft.wrappedValue
    let draftID = initialDraft.id
    let initialBuffer = store.draftBodyEditorBuffer(for: draftID)
    let initialDocument = MarkdownFrontMatterEditingService().renderDocument(
      draft: initialDraft,
      profile: store.profile(for: initialDraft),
      bodyMarkdown: initialBuffer.bodyMarkdown
    )
    let initialBodyOffset =
      (initialDocument as NSString).length
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
      findMatchSnapshot: .empty,
      editorScrollRestorationUpdate: MarkdownScrollSyncUpdate(
        source: .editor,
        progress: editorSession.editorScrollProgress
      ),
      editorScrollProgress: editorSession.editorScrollProgress,
      editorBodyRevision: buffer.revision
    )
    state.findReplaceMessage =
      editorSession.findQuery.isEmpty && editorSession.isFindReplacePresented
      ? String(localized: "输入查找内容。")
      : ""
    return state
  }

  private var editorWorkspaceLifecycle: some View {
    VStack(spacing: 0) {
      MacMarkdownEditorToolbar(
        title: $draft.title,
        store: store,
        draftID: draft.id,
        markdownPath: editorState.profile(for: draft).markdownPath(for: draft),
        isSelectionAIActionRunning: isSelectionAIActionRunning,
        canOpenAIChat: aiChatWorkspaceCommandAction?.isAvailable ?? true,
        aiChatUnavailableReason: aiChatWorkspaceCommandAction?.unavailableReason,
        isAutomaticInlineAICompletionEnabled: $isAutomaticInlineAICompletionEnabled,
        writingToolDensity: writingToolDensity,
        availableWritingContextPanels: availableWritingContextPanels,
        actions: markdownEditorToolbarActions
      )
      .opacity(zenModeController.toolbarOpacity)
      .onHover { isHovered in
        zenModeController.updateHovered(isHovered)
      }
      .environmentObject(zenModeController)
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
      syncEditorBodyFromStore()
      refreshFindMatchSnapshot()
      syncActiveEditorSelection()
      refreshMarkdownCursorContextSnapshot()
      applyEditorFocusRequest()
      scheduleMarkdownAnalysis(isAutomatic: true)
      scheduleInlineGhostText()
    }
    .onChange(of: editorState.editorFocusRequest?.id) { _, _ in
      applyEditorFocusRequest()
    }
    .onChange(of: selectedRange) { oldRange, newRange in
      if !NSEqualRanges(oldRange, newRange) {
        isInlineSelectionPaletteDismissed = false
        if let selectionEditPreview,
          !NSEqualRanges(selectionEditPreview.range, newRange)
        {
          self.selectionEditPreview = nil
          isInlineSelectionAIAction = false
        }
      }
      syncActiveEditorSelection()
      refreshMarkdownCursorContextSnapshot()
      saveCurrentEditorSession()
      scheduleInlineGhostText()
    }
    .onChange(of: editorBody) { _, _ in
      scheduleInlineGhostText()
      zenModeController.handleTypingActivity()
      checkSlashCommandTrigger()
    }
    .onChange(of: isAutomaticInlineAICompletionEnabled) { _, isEnabled in
      if isEnabled {
        scheduleInlineGhostText()
      } else {
        cancelInlineGhostText()
      }
    }
    .onChange(of: isRealtimeAnalysisEnabled) { _, isEnabled in
      if isEnabled {
        scheduleMarkdownAnalysis(isAutomatic: true)
      } else {
        invalidateMarkdownAnalysis()
      }
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
      cancelFindMatchRefresh()
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
      store.flushDraftBodyEditorBuffer(for: oldDraftID)
      syncEditorBodyFromStore(force: true)
      resetEditorDocumentFromDraft()
      restoreEditorSession(for: draft.id)
      syncActiveEditorSelection()
      scheduleMarkdownAnalysis(isAutomatic: true)
    }
  }

  private var editorOverlaySurface: some View {
    ZStack(alignment: .top) {
      editorSurface
      writingContextPanelOverlay
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
      .onAppear {
        zenModeController.refreshAccessibilityState(
          voiceOverEnabled: accessibilityVoiceOverEnabled,
          reduceMotionEnabled: accessibilityReduceMotion
        )
      }
      .onChange(of: accessibilityReduceMotion) { _, shouldReduceMotion in
        zenModeController.refreshAccessibilityState(
          voiceOverEnabled: accessibilityVoiceOverEnabled,
          reduceMotionEnabled: shouldReduceMotion
        )
      }
      .onChange(of: accessibilityVoiceOverEnabled) { _, isVoiceOverEnabled in
        zenModeController.refreshAccessibilityState(
          voiceOverEnabled: isVoiceOverEnabled,
          reduceMotionEnabled: accessibilityReduceMotion
        )
      }
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
    cancelFindMatchRefresh()
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
    markdownEditor
      .padding(14)
    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
  }

  var previewDraft: ArticleDraft {
    var updated = draft
    updated.bodyMarkdown = editorBody
    return updated
  }

  var markdownEditor: some View {
    VStack(spacing: 0) {
      if zenModeController.isFormattingBarVisible {
        MacMarkdownFormattingToolbar(
          statisticsState: editorStatisticsState,
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
          onInsertCompletionTrigger: insertMarkdownCompletionTrigger,
          onFormatChineseTypography: formatChineseTypography,
          onCopyForWeChatAndZhihu: copyForWeChatAndZhihu
        )
        .opacity(zenModeController.toolbarOpacity)
        .onHover { isHovered in
          zenModeController.updateHovered(isHovered)
        }
        .environmentObject(zenModeController)
        Divider()
      }

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
          attachments: draft.attachments,
          editRequest: editorEditRequest,
          focusRequest: markdownTextFocusRequest,
          ghostText: inlineGhostText,
          ssgSnippets: markdownSSGSnippets,
          scrollSyncUpdate: nil,
          scrollRestorationUpdate: editorScrollRestorationUpdate,
          onStatisticsChanged: { editorStatisticsState.update($0) },
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
          onSlashCommandKey: { key in
            handleSlashCommandKey(key)
          },
          onLiveBodyChange: { previousBody, updatedBody in
            handleLiveEditorBodyChange(from: previousBody, to: updatedBody)
          },
          onScrollPositionChanged: { position in
            updateEditorScrollPosition(position)
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

        if editorSessionState.selectedRange.length > 0 {
          VStack {
            MarkdownFloatingBubbleToolbar(
              isSelectionAIActionRunning: isSelectionAIActionRunning,
              onApplyFormatting: applyMarkdownFormatting,
              onApplyAdvancedFormatting: applyAdvancedMarkdownFormatting,
              onPerformSelectionAIAction: performSelectionAIAction,
              onPerformConvergedSelectionAIAction: performConvergedSelectionAIAction
            )
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            Spacer()
          }
          .padding(.top, 16)
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

        if isSlashMenuPresented {
          VStack {
            Spacer()
            HStack {
              MarkdownSlashCommandMenu(
                filterText: slashCommandQuery ?? "",
                items: buildDefaultSlashCommands(),
                selectedIndex: $slashCommandSelectedIndex,
                onSelect: { item in
                  selectSlashCommand(item)
                },
                onDismiss: {
                  dismissSlashCommandMenu()
                }
              )
              .transition(.move(edge: .bottom).combined(with: .opacity))
              Spacer()
            }
          }
          .padding(20)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if !markdownSSGComponentOccurrences.isEmpty {
        Divider()
        MarkdownSSGComponentPreviewStrip(
          occurrences: markdownSSGComponentOccurrences,
          onSelect: focusSSGComponentOccurrence
        )
        .frame(height: 118)
      }
    }
    .background(WorkbenchWritingSurface.color(usesWarmPaper: isWarmPaperBackgroundEnabled))
    .clipShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }

  private func buildDefaultSlashCommands() -> [SlashCommandItem] {
    [
      SlashCommandItem(
        id: "h1",
        title: String(localized: "一级标题"),
        subtitle: String(localized: "# 大标题"),
        systemImage: "textformat.size"
      ) {
        applySlashCommand("# ")
      },
      SlashCommandItem(
        id: "h2",
        title: String(localized: "二级标题"),
        subtitle: String(localized: "## 中标题"),
        systemImage: "textformat.size"
      ) {
        applySlashCommand("## ")
      },
      SlashCommandItem(
        id: "h3",
        title: String(localized: "三级标题"),
        subtitle: String(localized: "### 小标题"),
        systemImage: "textformat.size"
      ) {
        applySlashCommand("### ")
      },
      SlashCommandItem(
        id: "code",
        title: String(localized: "代码块"),
        subtitle: String(localized: "``` 代码语法高亮"),
        systemImage: "curlybraces.square"
      ) {
        applySlashCommand("```swift\n\n```")
      },
      SlashCommandItem(
        id: "table",
        title: String(localized: "表格"),
        subtitle: String(localized: "| 表头 |"),
        systemImage: "tablecells"
      ) {
        applySlashCommand("| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |")
      },
      SlashCommandItem(
        id: "quote",
        title: String(localized: "引用块"),
        subtitle: String(localized: "> 引用文本"),
        systemImage: "text.quote"
      ) {
        applySlashCommand("> ")
      },
      SlashCommandItem(
        id: "task",
        title: String(localized: "任务列表"),
        subtitle: String(localized: "- [ ] 待办事项"),
        systemImage: "checklist"
      ) {
        applySlashCommand("- [ ] ")
      },
      SlashCommandItem(
        id: "hr",
        title: String(localized: "分隔线"),
        subtitle: String(localized: "--- 分隔线"),
        systemImage: "minus"
      ) {
        applySlashCommand("\n---\n")
      },
      SlashCommandItem(
        id: "ai",
        title: String(localized: "AI 续写"),
        subtitle: String(localized: "使用 AI 自动生成段落"),
        systemImage: "wand.and.stars"
      ) {
        applySlashCommand("")
        performArticleAIAction(.continueArticle)
      },
    ]
  }

  private func checkSlashCommandTrigger() {
    let location = editorSessionState.selectedRange.location
    guard
      let query = MarkdownSlashCommandText.query(
        in: editorBody,
        caretUTF16Location: location
      )
    else {
      isSlashMenuPresented = false
      return
    }

    slashCommandQuery = query
    isSlashMenuPresented = true
  }

  private func applySlashCommand(_ snippet: String) {
    let location = editorSessionState.selectedRange.location
    guard
      let replaceRange = MarkdownSlashCommandText.replacementRange(
        in: editorBody,
        caretUTF16Location: location
      )
    else { return }

    if let currentRange = Range(replaceRange, in: editorBody) {
      editorBody.replaceSubrange(currentRange, with: snippet)
      dismissSlashCommandMenu()
    }
  }

  private func handleSlashCommandKey(_ key: MarkdownSlashCommandKey) -> Bool {
    guard isSlashMenuPresented else { return false }

    let filteredItems = MarkdownSlashCommandMenu.filteredItems(
      from: buildDefaultSlashCommands(),
      matching: slashCommandQuery ?? ""
    )
    switch key {
    case .moveUp, .moveDown:
      slashCommandSelectedIndex = MarkdownSlashCommandSelection.move(
        currentIndex: slashCommandSelectedIndex,
        itemCount: filteredItems.count,
        direction: key
      )
    case .select:
      guard !filteredItems.isEmpty else { return true }
      let index = min(max(slashCommandSelectedIndex, 0), filteredItems.count - 1)
      selectSlashCommand(filteredItems[index])
    case .dismiss:
      dismissSlashCommandMenu()
    }
    return true
  }

  private func selectSlashCommand(_ item: SlashCommandItem) {
    item.action()
    dismissSlashCommandMenu()
  }

  private func dismissSlashCommandMenu() {
    isSlashMenuPresented = false
    slashCommandQuery = nil
    slashCommandSelectedIndex = 0
  }

}
