import Foundation
import PublishingCoreSupport

extension WorkbenchAIStore {
  /// Extracts a site-scoped style profile only from the user's selected public
  /// articles. The result remains transient until `applyAIWritingStyleProfile`
  /// is explicitly invoked.
  @discardableResult
  public func generateAIWritingStyleProfile(
    exemplarArticleIDs: [UUID]
  ) async -> AIWritingStyleProfilePreview? {
    guard !Task.isCancelled else { return nil }
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = aiChatQuickHideOperationMessage()
      return nil
    }
    // Read editor-owned buffers before freezing the public text selection.
    store.flushDraftBodyEditorBuffers()
    aiWritingStylePreview = nil

    let service = AIWritingStyleProfileService()
    let initialProfile = store.activeProfile
    let initialConfig = AIOutboundPayloadPrivacyService().sanitizedProviderConfig(
      store.aiProviderConfig(for: initialProfile)
    )
    let initialRequest: AIWritingStyleExtractionRequest
    do {
      initialRequest = try service.makeExtractionRequest(
        profile: initialProfile,
        drafts: store.drafts,
        selectedArticleIDs: exemplarArticleIDs
      )
      _ = try aiChatAvailableAPIKey(for: initialProfile)
    } catch {
      store.setAIActionFailureMessage(
        CoreL10n.format("无法提炼写作风格：%@", error.localizedDescription)
      )
      return nil
    }

    let lane = AIGenerationLane.writingStyle
    let generation = beginAIRequest(lane, showsActionLoading: true)
    defer { finishAIRequest(lane, generation: generation) }

    let privacyService = AIOutboundPayloadPrivacyService()
    aiRequestContextChecks[lane] = { [weak self] in
      guard let self else { return false }
      guard self.store.activeProfileID == initialProfile.id,
        self.store.activeProfile.resolvedAIWritingStyle == initialProfile.resolvedAIWritingStyle,
        privacyService.sanitizedProviderConfig(
          self.store.aiProviderConfig(for: self.store.activeProfile)) == initialConfig
      else { return false }
      do {
        let current = try service.makeExtractionRequest(
          profile: self.store.activeProfile, drafts: self.store.drafts,
          selectedArticleIDs: initialRequest.context.articleIDs
        )
        return current.context == initialRequest.context
      } catch {
        // A removed/private/edited example invalidates the old request; it is
        // not an error belonging to the user's newly selected context.
        return false
      }
    }
    do {
      let preview = try await awaitAIRequest(lane, generation: generation) { [self] in
        let initialTransport = try aiPublishingAssistantService.prepareTransport(
          for: initialRequest.chatRequest,
          config: initialConfig,
          privacyService: privacyService,
          transportVariant: .complete,
          contextBindingValues: ["writing-style", initialProfile.id.uuidString]
        )
        let outcome = await AIOutboundPayloadApprovalBroker.shared.requestApproval(
          for: initialTransport.payload.preview,
          scopeID: initialProfile.id
        )
        guard case .confirmed(let confirmation) = outcome else {
          throw CancellationError()
        }
        try checkAIRequest(lane, generation: generation)

        // Rebuild from live state after user approval. This confirms that every
        // selected ID still belongs to this site and remains non-private before
        // a byte can cross the transport boundary.
        guard store.activeProfileID == initialProfile.id else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        let currentProfile = store.activeProfile
        guard currentProfile.resolvedAIWritingStyle == initialProfile.resolvedAIWritingStyle else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        let refreshedRequest = try service.makeExtractionRequest(
          profile: currentProfile,
          drafts: store.drafts,
          selectedArticleIDs: initialRequest.context.articleIDs
        )
        let currentConfig = privacyService.sanitizedProviderConfig(
          store.aiProviderConfig(for: currentProfile)
        )
        guard currentConfig == initialConfig else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        let refreshedTransport = try aiPublishingAssistantService.prepareTransport(
          for: refreshedRequest.chatRequest,
          config: currentConfig,
          privacyService: privacyService,
          transportVariant: .complete,
          contextBindingValues: ["writing-style", currentProfile.id.uuidString],
          now: initialTransport.payload.preview.createdAt,
          nonce: initialTransport.payload.preview.nonce
        )
        try privacyService.validate(
          confirmation: confirmation,
          prepared: refreshedTransport.payload
        )
        let authorizedTransport = refreshedTransport.bindingAuthorizationDeadline(
          refreshedTransport.payload.preview.expiresAt
        )
        let authorization = AIOutboundPayloadTransportAuthorization(
          confirmation: confirmation,
          prepared: authorizedTransport.payload,
          privacyService: privacyService
        )
        let apiKey = try aiChatAvailableAPIKey(for: currentProfile)
        try authorization.consume()
        let reply = try await aiPublishingAssistantService.completePrepared(
          authorizedTransport,
          apiKey: apiKey
        )
        try checkAIRequest(lane, generation: generation)
        guard store.activeProfileID == currentProfile.id,
          privacyService.sanitizedProviderConfig(store.aiProviderConfig(for: store.activeProfile))
            == currentConfig
        else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        store.flushDraftBodyEditorBuffers()
        let preview = try service.preview(
          response: reply.content,
          baseline: currentProfile.resolvedAIWritingStyle,
          context: refreshedRequest.context
        )
        guard
          service.validatedPreview(preview, profile: store.activeProfile, drafts: store.drafts)
            != nil
        else {
          throw AIOutboundPayloadConfirmationError.drifted
        }
        return preview
      }
      aiWritingStylePreview = preview
      if canPresentAIRequest(lane, generation: generation) {
        aiActionMessage = CoreL10n.text("已生成写作风格预览，请检查并确认应用。")
      }
      return preview
    } catch {
      if case AIOutboundPayloadConfirmationError.drifted = error { return nil }
      guard !(error is CancellationError), canPresentAIRequest(lane, generation: generation) else {
        return nil
      }
      store.setAIActionFailureMessage(
        CoreL10n.format("写作风格提炼失败：%@", error.localizedDescription)
      )
      return nil
    }
  }

  /// Commits only a reviewed preview. The same-site/public eligibility check
  /// runs again, preventing a stale preview from applying after an article is
  /// moved, hidden, or made private.
  @discardableResult
  public func applyAIWritingStyleProfile(
    _ preview: AIWritingStyleProfilePreview
  ) -> Bool {
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = aiChatQuickHideOperationMessage()
      return false
    }
    store.flushDraftBodyEditorBuffers()
    let service = AIWritingStyleProfileService()
    guard
      let validated = service.validatedPreview(
        preview,
        profile: store.activeProfile,
        drafts: store.drafts
      )
    else {
      aiActionMessage = CoreL10n.text("写作风格预览已过期，请重新提炼后再应用。")
      return false
    }
    var profile = store.activeProfile
    var normalizedStyle = validated.style
    normalizedStyle.normalizeWhitespace()
    profile.resolvedAIWritingStyle = normalizedStyle
    guard store.commitActiveProfileSynchronously(profile) else {
      aiActionMessage = CoreL10n.text("写作风格未保存；请先处理当前项目文件的保存问题。")
      return false
    }
    aiWritingStylePreview = nil
    aiActionMessage = CoreL10n.text("已保存当前站点的个人写作风格和术语。")
    return true
  }

  public func discardAIWritingStyleProfilePreview() {
    aiWritingStylePreview = nil
  }
}
