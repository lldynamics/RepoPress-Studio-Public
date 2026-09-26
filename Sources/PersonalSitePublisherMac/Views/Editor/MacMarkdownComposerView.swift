import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownComposerView: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @Binding var draft: ArticleDraft
  let store: WorkbenchStore
  let aiActions: WorkbenchAIFeatureFacade
  @ObservedObject var inlineAIReviewState: AIInlineStructuredEditReviewState
  @Environment(\.publishDrawerCommandAction) var publishDrawerCommandAction
  @Environment(\.aiChatWorkspaceCommandAction) var aiChatWorkspaceCommandAction
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var accessibilityVoiceOverEnabled
  @Environment(\.workspaceWindowSession) var workspaceWindowSession
  @Environment(\.workspaceWindowIsKey) private var workspaceWindowIsKey
  @EnvironmentObject var sceneCommandRouter: WorkspaceSceneCommandRouter
  @StateObject var editorState: WorkbenchMarkdownEditorFeatureFacade
  @StateObject var editorSessionState: MarkdownComposerEditorSessionState
  @StateObject var externalBrowserPreviewCoordinator: ExternalBrowserPreviewCoordinator
  /// Stored as reference state rather than an observed object so delayed
  /// whole-document statistics invalidate only the formatting toolbar that
  /// observes this model, not the complete composer hierarchy.
  @State var editorStatisticsState = MarkdownComposerStatisticsState()
  @StateObject var zenModeController = ZenModeController()
  @SceneStorage("workspace.focusMode") var isFocusModeActive = false
  @AppStorage(MarkdownEditorComfortPreferences.focusToolbarFadeEnabledKey)
  var isFocusToolbarFadeEnabled = true
  @State var attachmentState = MarkdownComposerAttachmentState()
  @State var selectionActionState = MarkdownComposerSelectionActionState()
  @State var selectionBubblePresentationState = MarkdownSelectionBubblePresentationState()
  @State var presentationState = MarkdownComposerPresentationState()
  @State var analysisState = MarkdownComposerAnalysisState()
  @State var editorDocumentBodyOffsetCache: Int
  @State var markdownSSGDerivedData = MarkdownComposerSSGDerivedData.empty
  @State var editorSessionSaveTask: Task<Void, Never>?
  @State var editorSessionSaveGeneration: UInt64 = 0
  @State var pendingInlineStructuredEditApplyRequestID: UUID?
  @State var pendingFindReplacement: MarkdownPendingFindReplacement?
  @State var pendingAttachmentInsertion: MarkdownPendingAttachmentInsertion?
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
  @AppStorage(MarkdownEditorComfortPreferences.bodyFontStyleKey)
  var editorBodyFontStyleRawValue = MarkdownEditorBodyFontStyle.defaultStyle.rawValue
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
  @AppStorage("workspace.markdownOutlinePinned") var isOutlinePinned = false
  @State private var slashCommandQuery: String? = nil
  @State private var isSlashMenuPresented: Bool = false
  @State private var slashCommandSelectedIndex = 0
  @State private var pendingSlashAIRequest: (requestID: UUID, draftID: UUID)?
  @State private var contextualPopoverAnchor: MarkdownContextualPopoverAnchor?
  @State private var isDiscardInvalidFrontMatterConfirmationPresented = false
  @State var isArticleInformationExpanded = false
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

  var markdownSelectionBubbleTaskID: MarkdownSelectionBubbleTaskID {
    MarkdownSelectionBubbleTaskID(
      draftID: draft.id,
      selectedRange: editorSessionState.selectedRange
    )
  }

  var editorComfortConfiguration: MarkdownEditorComfortConfiguration {
    MarkdownEditorComfortConfiguration(
      fontSize: editorFontSize,
      lineSpacing: editorLineSpacing,
      bodyWidth: editorBodyWidth,
      bodyFontStyle: MarkdownEditorBodyFontStyle.resolved(rawValue: editorBodyFontStyleRawValue),
      spellCheckEnabled: isEditorSpellCheckEnabled,
      typewriterModeEnabled: isTypewriterModeEnabled,
      currentParagraphHighlightEnabled: isCurrentParagraphHighlightEnabled,
      warmPaperBackgroundEnabled: isWarmPaperBackgroundEnabled,
      automaticPairingEnabled: isAutomaticPairingEnabled,
      accessibilityReduceMotionEnabled: accessibilityReduceMotion
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
      onRequestInlineAICompletion: requestInlineGhostText,
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
    _inlineAIReviewState = ObservedObject(
      wrappedValue: store.ai.inlineStructuredEditReviewState
    )
    _editorState = StateObject(
      wrappedValue: WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: draftID)
    )
    _externalBrowserPreviewCoordinator = StateObject(
      wrappedValue: ExternalBrowserPreviewCoordinator(store: store)
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
      editorBodyRevision: buffer.revision,
      invalidFrontMatterBaseBodyMarkdown: editorSession.invalidFrontMatterBaseBodyMarkdown,
      invalidFrontMatterBaseBodyRevision: editorSession.invalidFrontMatterBaseBodyRevision,
      invalidFrontMatterBaseMetadataRevision:
        editorSession.invalidFrontMatterBaseMetadataRevision
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
        externalBrowserPreviewCoordinator: externalBrowserPreviewCoordinator,
        writingToolDensity: writingToolDensity,
        availableWritingContextPanels: availableWritingContextPanels,
        actions: markdownEditorToolbarActions,
        articleInformationToggle: articleInformationToggle,
        formattingToolbar: integratedFormattingToolbar
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
          findScope: findScope,
          canUseSelectionScope: hasUsableFindSelectionScope,
          findScopeStatus: findScopeStatus,
          findMatchStatus: findMatchStatus,
          findReplaceMessage: findReplaceFeedbackMessage,
          onSetScope: setFindScope,
          onFindPrevious: findPrevious,
          onFindNext: findNext,
          onReplaceCurrentOrNext: replaceCurrentOrNext,
          onReplaceAll: replaceAll,
          onDismiss: {
            isFindReplacePresented = false
            discardPendingFindReplacePreview()
          }
        )
        Divider()
      }
      editorOverlaySurface
    }
    .sheet(item: $editorSessionState.pendingFindReplacePreview) { preview in
      MarkdownFindReplacePreviewSheet(
        preview: preview,
        onConfirm: applyPendingFindReplacePreview,
        onCancel: discardPendingFindReplacePreview
      )
    }
    .onChange(of: commandActions.sceneCommandPresentation, initial: true) { _, _ in
      sceneCommandRouter.registerMarkdownEditor(
        commandActions,
        owner: sceneCommandOwnerID
      )
    }
    .task {
      await restoreEditorAfterMount()
    }
    .task(id: markdownSelectionBubbleTaskID) {
      let selection = selectedRange
      guard selection.length > 0, !Task.isCancelled else { return }

      guard
        let selectionGeneration = selectionBubblePresentationState.selectionDidChange(
          to: selection
        )
      else {
        return
      }
      do {
        try await Task.sleep(for: MarkdownSelectionBubblePresentationState.presentationDelay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      selectionBubblePresentationState.revealIfCurrentSelection(
        selection,
        generation: selectionGeneration
      )
    }
    .onChange(of: editorState.editorFocusRequest?.id) { _, _ in
      applyEditorFocusRequest()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .markdownLocalPreviewDiagnosticJumpRequested)
    ) {
      notification in
      guard let request = notification.object as? MarkdownLocalPreviewDiagnosticJumpRequest,
        request.draftID == draft.id,
        workspaceWindowIsKey
      else {
        return
      }
      jumpToMarkdownLine(request.line)
    }
    .onChange(of: workspaceWindowIsKey) { _, isKeyWindow in
      // A legacy Store request can arrive while this editor is behind a
      // sheet. It remains unconsumed until this window becomes key; owned
      // requests still reject every non-owner and every replay.
      guard isKeyWindow else { return }
      applyEditorFocusRequest()
    }
    .onChange(of: selectedRange) { oldRange, newRange in
      // AppKit coalesces text and selection bindings separately. Re-evaluate
      // when the caret arrives after the text so a valid slash trigger is not
      // lost merely because the body observer ran with the previous range.
      checkSlashCommandTrigger()
      selectionBubblePresentationState.selectionDidChange(to: newRange)
      if !NSEqualRanges(oldRange, newRange) {
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
      cancelInlineGhostText()
    }
    .onChange(of: editorBody) { _, _ in
      aiActions.invalidateInlineStructuredEditReviewIfStale(for: draft, body: editorBody)
      cancelInlineGhostText()
      zenModeController.handleTypingActivity()
      checkSlashCommandTrigger()
      pendingFindReplacePreview = nil
    }
  }

  private var editorWorkspaceDocumentLifecycle: some View {
    editorWorkspaceLifecycle
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
        if !isFindReplacePresented {
          findScopeSnapshot = nil
          if findScope == .selection { findScope = .body }
          discardPendingFindReplacePreview()
        }
        saveCurrentEditorSession()
      }
      .onChange(of: editorBodyRevision) { _, _ in
        pendingFindReplacePreview = nil
        refreshFindMatchSnapshot()
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
        aiActions.invalidateInlineStructuredEditReviewIfStale(for: draft, body: editorBody)
        syncEditorBodyFromStore()
      }
      .onChange(of: draft.editorObservationProjection) { _, _ in
        aiActions.invalidateInlineStructuredEditReviewIfStale(for: draft, body: editorBody)
      }
      .onChange(of: editorEditRequest?.id) { _, requestID in
        if let pending = pendingAttachmentInsertion, pending.requestID != requestID {
          cancelAttachmentImport()
        }
      }
      .onChange(of: editorBufferRevision) { _, _ in
        syncEditorBodyFromStore()
      }
      .onChange(of: draft.id) { oldDraftID, _ in
        pendingInlineStructuredEditApplyRequestID = nil
        pendingFindReplacement = nil
        // Review state is application-scoped and draft-keyed. Switching one
        // window must not destroy a review still visible in another window; the
        // destination composer simply hides sessions for other draft IDs.
        selectionBubblePresentationState.reset()
        cancelFindMatchRefresh()
        editorStatisticsState.update(.empty)
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

  private func restoreEditorAfterMount() async {
    // Editor restoration updates shared selection and presentation state.
    // Do it after the mounting transaction so ObservableObject publishers
    // never fire while SwiftUI is still installing focused values.
    await MainRunLoopUpdateDeferral.waitForNextDefaultModeCycle()
    guard !Task.isCancelled else { return }
    syncEditorBodyFromStore()
    let restoredSession = store.markdownEditorSessionState(for: draft.id)
    restoreInvalidFrontMatterDocument(
      restoredSession.invalidFrontMatterDocument,
      baseBodyMarkdown: restoredSession.invalidFrontMatterBaseBodyMarkdown,
      baseBodyRevision: restoredSession.invalidFrontMatterBaseBodyRevision,
      baseMetadataRevision: restoredSession.invalidFrontMatterBaseMetadataRevision
    )
    refreshFindMatchSnapshot()
    syncActiveEditorSelection()
    refreshMarkdownCursorContextSnapshot()
    applyEditorFocusRequest()
    scheduleMarkdownAnalysis(isAutomatic: true)
  }

  private var editorOverlaySurface: some View {
    GeometryReader { geometry in
      let usesDockedOutline = MarkdownOutlinePresentationPolicy.usesDockedLayout(
        isPinned: isOutlinePinned && activeWritingContextPanel == .outline,
        availableWidth: geometry.size.width
      )
      ZStack(alignment: .top) {
        HStack(spacing: 0) {
          editorSurface
            .frame(maxWidth: .infinity, maxHeight: .infinity)

          if usesDockedOutline {
            Divider()
            outlinePanelContent()
              .frame(width: 320)
              .frame(maxHeight: .infinity)
              .padding(12)
              .accessibilityIdentifier("markdown-outline-dock")
          }
        }

        if !usesDockedOutline {
          writingContextPanelOverlay
        }
        automaticImageImportToastOverlay
      }
    }
  }

  @ViewBuilder
  private var automaticImageImportToastOverlay: some View {
    VStack {
      if let toast = automaticImageImportToast {
        Spacer(minLength: 0)
        Label(toast.message, systemImage: "photo.badge.checkmark")
          .font(.callout.weight(.medium))
          .padding(.horizontal, 14)
          .padding(.vertical, 9)
          .workbenchGlassSurface(material: .regularMaterial, in: Capsule())
          .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 3)
          .accessibilityIdentifier("markdown-automatic-image-import-toast")
          .transition(
            WorkbenchMotion.statusTransition(reduceMotion: accessibilityReduceMotion)
          )
      }
    }
    .padding(.bottom, 18)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(false)
    .zIndex(5)
    .animation(
      WorkbenchMotion.animation(
        for: .statusChange,
        reduceMotion: accessibilityReduceMotion
      ),
      value: automaticImageImportToast?.id
    )
  }

  @ViewBuilder
  private var writingContextPanelOverlay: some View {
    if let panel = activeWritingContextPanel {
      if panel == .outline {
        HStack {
          Spacer(minLength: 0)
          outlinePanelContent()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .zIndex(4)
      } else {
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
  }

  var body: some View {
    editorWorkspaceDocumentLifecycle
      .onAppear {
        syncFocusToolbarVisibility()
        zenModeController.refreshAccessibilityState(
          voiceOverEnabled: accessibilityVoiceOverEnabled,
          reduceMotionEnabled: accessibilityReduceMotion
        )
      }
      .onChange(of: isFocusModeActive) { _, _ in
        syncFocusToolbarVisibility()
      }
      .onChange(of: isFocusToolbarFadeEnabled) { _, _ in
        syncFocusToolbarVisibility()
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
    externalBrowserPreviewCoordinator.cancelPendingOpen()
    store.clearActiveEditorSelection(for: draft.id)
  }

  // Full-bleed writing surface: the pane itself is the page, so the editor is
  // not inset as a bordered card inside it.
  var editorSurface: some View {
    markdownEditor
      .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
  }

  var previewDraft: ArticleDraft {
    var updated = draft
    updated.bodyMarkdown = editorBody
    return updated
  }

  var markdownEditor: some View {
    VStack(spacing: 0) {
      let reviewPresentation = inlineStructuredEditReviewPresentation
      let statisticsDraftID = draft.id
      ZStack {
        WorkbenchWritingSurface.color(usesWarmPaper: isWarmPaperBackgroundEnabled)

        MacMarkdownTextView(
          text: $editorSessionState.editorDocument,
          bodyMarkdown: editorBody,
          bodyUTF16Offset: editorDocumentBodyOffset,
          allowsLiveBodyChanges: frontMatterIssue == nil,
          isFrontMatterFolded: writingToolDensity == .basic
            && !isArticleInformationExpanded && frontMatterIssue == nil,
          selectedRange: $editorSessionState.selectedRange,
          isFrontMatterSelection: $editorSessionState.isFrontMatterSelection,
          comfortConfiguration: editorComfortConfiguration,
          diagnostics: inlineDiagnostics,
          attachments: draft.attachments,
          editRequest: editorEditRequest,
          focusRequest: markdownTextFocusRequest,
          inlineAIReviewPresentation: reviewPresentation?.textViewPresentation,
          ghostText: inlineGhostText,
          ssgSnippets: markdownSSGSnippets,
          reportsScrollSourceLine: false,
          scrollSyncUpdate: nil,
          scrollRestorationUpdate: editorScrollRestorationUpdate,
          onStatisticsChanged: { statistics in
            receiveEditorStatistics(statistics, for: statisticsDraftID)
          },
          onFileDropTargetChanged: { isImageDropTargeted = $0 },
          onPasteMessage: { message in
            selectionActionMessage = message
            EditorAccessibilityAnnouncementCenter.announce(message)
          },
          onEditRequestHandled: { outcome in
            guard editorEditRequest?.id == outcome.id else { return }
            editorEditRequest = nil
            handleAttachmentInsertionOutcome(outcome)
            handleFindReplacementOutcome(outcome)
            if let pending = pendingSlashAIRequest, pending.requestID == outcome.id {
              pendingSlashAIRequest = nil
              if outcome.wasApplied, pending.draftID == draft.id {
                performArticleAIAction(.continueArticle)
              }
            }
            guard pendingInlineStructuredEditApplyRequestID == outcome.id else { return }
            pendingInlineStructuredEditApplyRequestID = nil
            if outcome.wasApplied {
              aiActions.endInlineStructuredEditReview(for: draft.id)
              selectionActionMessage = String(localized: "已应用接受的 AI 修改；可用撤销恢复。")
            } else {
              selectionActionMessage = String(localized: "文章已变化，AI 修改未应用；审阅内容仍保留。")
            }
            EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
          },
          onEditRequestWillApply: attachmentInsertionAdmission,
          onGhostTextAccepted: { _ in
            acceptInlineGhostText()
          },
          onGhostTextDismissed: {
            dismissInlineGhostText()
          },
          onInlineAICompletionRequested: {
            requestInlineGhostText()
          },
          onSSGSnippetShortcut: { candidate in
            handleAutomaticSSGSnippetShortcut(candidate)
          },
          onSlashCommandKey: { key, applyReplacement in
            handleSlashCommandKey(key, applyReplacement: applyReplacement)
          },
          onLiveBodyChange: { previousBody, updatedBody in
            handleLiveEditorBodyChange(from: previousBody, to: updatedBody)
          },
          onDocumentTextCommitted: { previousDocument, updatedDocument in
            commitEditorDocumentForTermination(from: previousDocument, to: updatedDocument)
          },
          onContextualAnchorChanged: { anchor in
            contextualPopoverAnchor = anchor
          },
          onScrollPositionChanged: { position in
            updateEditorScrollPosition(position)
          },
          onDroppedFiles: { urls in
            insertImageReferences(
              urls,
              automaticallyConvertToWebP: true
            )
          },
          onDroppedMarkdown: { markdown, range, citation in
            insertKnowledgeMarkdown(markdown, at: range, citation: citation)
          }
        )
        // The coordinator owns delayed statistics tasks. Recreating it for a
        // different draft binds each callback to the correct draft identity
        // and cancels any pending delivery from the prior document.
        .id(statisticsDraftID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let reviewPresentation {
          EditorAIReviewBar(
            hunk: reviewPresentation.hunk,
            position: reviewPresentation.position,
            decision: reviewPresentation.decision,
            decisionSummary: reviewPresentation.session.decisionSummary,
            onPrevious: { aiActions.moveInlineStructuredEditHunk(by: -1, draftID: draft.id) },
            onNext: { aiActions.moveInlineStructuredEditHunk(by: 1, draftID: draft.id) },
            onAccept: {
              aiActions.setInlineStructuredEditDecision(
                .accepted, for: reviewPresentation.hunk.id, draftID: draft.id)
            },
            onReject: {
              aiActions.setInlineStructuredEditDecision(
                .rejected, for: reviewPresentation.hunk.id, draftID: draft.id)
            },
            onAcceptAll: {
              aiActions.setAllInlineStructuredEditDecisions(.accepted, draftID: draft.id)
            },
            onRejectAll: {
              aiActions.setAllInlineStructuredEditDecisions(.rejected, draftID: draft.id)
            },
            onApply: applyInlineStructuredEditReview,
            onExit: { aiActions.endInlineStructuredEditReview(for: draft.id) }
          )
          .padding(12)
          .frame(maxWidth: 460, maxHeight: .infinity, alignment: .topTrailing)
        }

        if let frontMatterIssue {
          VStack(alignment: .leading, spacing: 7) {
            Label("Front Matter 尚未保存", systemImage: "exclamationmark.triangle.fill")
              .font(.callout.weight(.semibold))
              .foregroundStyle(WorkbenchTheme.warning)
            Text(frontMatterIssue.workbenchMessage)
              .font(.caption)
            Text("无效原文已写入本地恢复副本；修正格式前不会覆盖结构化文章信息。")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack {
              Button("复制恢复原文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(editorDocument, forType: .string)
                selectionActionMessage = String(localized: "已复制未保存的 Front Matter 文档。")
                EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
              }
              Button("放弃无效修改…", role: .destructive) {
                isDiscardInvalidFrontMatterConfirmationPresented = true
              }
            }
            .controlSize(.small)
          }
          .padding(10)
          .frame(maxWidth: 390, alignment: .leading)
          .background(
            .regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
          .padding(10)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("markdown-front-matter-invalid-banner")
          .confirmationDialog(
            "放弃未保存的 Front Matter 修改？",
            isPresented: $isDiscardInvalidFrontMatterConfirmationPresented,
            titleVisibility: .visible
          ) {
            Button("放弃并还原已保存版本", role: .destructive) {
              resetEditorDocumentFromDraft()
              saveCurrentEditorSession()
              selectionActionMessage = String(
                localized: "已放弃无效 Front Matter 修改并还原已保存版本。"
              )
              EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
            }
            Button("取消", role: .cancel) {}
          } message: {
            Text("此操作会删除本地恢复副本；正文草稿不受影响。")
          }
        }

        if selectionBubblePresentationState.shouldRender(for: editorSessionState.selectedRange) {
          if let placement = contextualPopoverPlacement(
            contentSize: CGSize(width: 344, height: 42),
            preferredEdge: .above
          ) {
            MarkdownFloatingBubbleToolbar(
              isSelectionAIActionRunning: isSelectionAIActionRunning,
              selectionAIActionAvailability: { kind in
                selectionAIActionAvailability(kind)
              },
              onApplyFormatting: applyMarkdownFormatting,
              onApplyAdvancedFormatting: applyAdvancedMarkdownFormatting,
              onPerformSelectionAIAction: performSelectionAIAction,
              onPerformConvergedSelectionAIAction: performConvergedSelectionAIAction
            )
            .frame(width: placement.frame.width, height: placement.frame.height)
            .position(x: placement.frame.midX, y: placement.frame.midY)
          }
        }

        if isImageDropTargeted {
          ZStack {
            workbenchAccentColor.opacity(0.10)
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
              .stroke(workbenchAccentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
          }
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }

        if isSlashMenuPresented {
          if let placement = contextualPopoverPlacement(
            contentSize: CGSize(width: 280, height: 250),
            preferredEdge: .below
          ) {
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
            .frame(width: placement.frame.width, height: placement.frame.height)
            .position(x: placement.frame.midX, y: placement.frame.midY)
          }
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

      Divider()
      MacMarkdownEditorStatusBar(
        draft: $draft,
        statisticsState: editorStatisticsState,
        cursorPosition: markdownCursorPosition,
        fenceMatch: activeMarkdownFenceMatch,
        completion: markdownCursorCompletion,
        onJumpToLine: jumpToMarkdownLine,
        onJumpToCounterpartFence: jumpToCounterpartFence,
        onApplyCompletion: applyMarkdownCompletion,
        onInsertCompletionTrigger: insertMarkdownCompletionTrigger,
        onFormatChineseTypography: formatChineseTypography,
        onCopyForWeChatAndZhihu: copyForWeChatAndZhihu
      )
    }
    .background(WorkbenchWritingSurface.color(usesWarmPaper: isWarmPaperBackgroundEnabled))
  }

  private func contextualPopoverPlacement(
    contentSize: CGSize,
    preferredEdge: MarkdownContextualPopoverPreferredEdge
  ) -> MarkdownContextualPopoverPlacement? {
    guard let contextualPopoverAnchor,
      contextualPopoverAnchor.selection == editorSessionState.selectedRange
    else { return nil }
    return MarkdownContextualPopoverPlacement.resolve(
      anchor: contextualPopoverAnchor,
      contentSize: contentSize,
      preferredEdge: preferredEdge
    )
  }

  private func buildDefaultSlashCommands(
    applySnippet: ((String) -> Bool)? = nil
  ) -> [SlashCommandItem] {
    let apply = applySnippet ?? { snippet in applySlashCommand(snippet) }
    return [
      SlashCommandItem(
        id: "h1",
        title: String(localized: "一级标题"),
        subtitle: String(localized: "# 大标题"),
        systemImage: "number"
      ) {
        _ = apply("# ")
      },
      SlashCommandItem(
        id: "h2",
        title: String(localized: "二级标题"),
        subtitle: String(localized: "## 中标题"),
        systemImage: "number"
      ) {
        _ = apply("## ")
      },
      SlashCommandItem(
        id: "h3",
        title: String(localized: "三级标题"),
        subtitle: String(localized: "### 小标题"),
        systemImage: "number"
      ) {
        _ = apply("### ")
      },
      SlashCommandItem(
        id: "code",
        title: String(localized: "代码块"),
        subtitle: String(localized: "``` 代码语法高亮"),
        systemImage: "curlybraces.square"
      ) {
        _ = apply("```swift\n\n```")
      },
      SlashCommandItem(
        id: "table",
        title: String(localized: "表格"),
        subtitle: String(localized: "| 表头 |"),
        systemImage: "tablecells"
      ) {
        _ = apply("| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |")
      },
      SlashCommandItem(
        id: "quote",
        title: String(localized: "引用块"),
        subtitle: String(localized: "> 引用文本"),
        systemImage: "text.quote"
      ) {
        _ = apply("> ")
      },
      SlashCommandItem(
        id: "task",
        title: String(localized: "任务列表"),
        subtitle: String(localized: "- [ ] 待办事项"),
        systemImage: "checklist"
      ) {
        _ = apply("- [ ] ")
      },
      SlashCommandItem(
        id: "hr",
        title: String(localized: "分隔线"),
        subtitle: String(localized: "--- 分隔线"),
        systemImage: "minus"
      ) {
        _ = apply("\n---\n")
      },
      SlashCommandItem(
        id: "ai",
        title: String(localized: "AI 续写"),
        subtitle: String(localized: "使用 AI 自动生成段落"),
        systemImage: "wand.and.stars"
      ) {
        if let applySnippet {
          guard applySnippet("") else { return }
          performArticleAIAction(.continueArticle)
        } else {
          _ = applySlashCommand("", startsAIContinuation: true)
        }
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

  private func applySlashCommand(_ snippet: String, startsAIContinuation: Bool = false) -> Bool {
    let location = editorSessionState.selectedRange.location
    guard
      let replaceRange = MarkdownSlashCommandText.replacementRange(
        in: editorBody,
        caretUTF16Location: location
      )
    else { return false }

    let request = MarkdownTextEditRequest(
      expectedText: editorBody,
      edit: MarkdownSmartEdit(
        replacedRange: replaceRange,
        replacement: snippet,
        selectedRange: NSRange(
          location: replaceRange.location + (snippet as NSString).length, length: 0
        )
      )
    )
    pendingSlashAIRequest = startsAIContinuation ? (request.id, draft.id) : nil
    editorEditRequest = request
    dismissSlashCommandMenu()
    return true
  }

  private func handleSlashCommandKey(
    _ key: MarkdownSlashCommandKey,
    applyReplacement: @escaping (String) -> Bool
  ) -> Bool {
    guard isSlashMenuPresented else { return false }

    let filteredItems = MarkdownSlashCommandMenu.filteredItems(
      from: buildDefaultSlashCommands(applySnippet: applyReplacement),
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

extension MarkdownFrontMatterEditingIssue {
  fileprivate var workbenchMessage: String {
    switch self {
    case .invalidDelimiter:
      return String(localized: "起止分隔符缺失或与当前站点的 Front Matter 格式不匹配。")
    case .concurrentBodyChange:
      return String(localized: "另一窗口已修改正文；恢复原文仍保留，未覆盖另一窗口的内容。")
    case .malformedLine(let line):
      return String(localized: "第 \(line) 行不是有效的键值格式。")
    case .missingDate:
      return String(localized: "缺少必需的 date 字段。")
    case .invalidDate:
      return String(localized: "date 字段不是有效日期。")
    case .invalidDraftFlag:
      return String(localized: "draft 字段必须使用有效的布尔值。")
    case .invalidVisibility:
      return String(localized: "visibility 字段不是受支持的可见性值。")
    }
  }
}

extension MacMarkdownComposerView {
  private func syncFocusToolbarVisibility() {
    zenModeController.setZenModeActive(isFocusModeActive && isFocusToolbarFadeEnabled)
  }

  private var integratedFormattingToolbar: MacMarkdownFormattingToolbar {
    MacMarkdownFormattingToolbar(
      writingToolDensity: writingToolDensity,
      isFocusModeActive: $isFocusModeActive,
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
        let requestedDraftID = draft.id
        Task {
          let urls = await ImageSelectionPanel.chooseImages()
          guard draft.id == requestedDraftID, !urls.isEmpty else { return }
          insertImageReferences(urls)
        }
      },
      onInsertVideo: {
        guard requireBodyEditingContext() else { return }
        let requestedDraftID = draft.id
        Task {
          let urls = await VideoSelectionPanel.chooseVideos()
          guard draft.id == requestedDraftID, !urls.isEmpty else { return }
          insertVideoReferences(urls)
        }
      },
      onFormatChineseTypography: formatChineseTypography,
      presentation: .integrated
    )
  }
}
