import Foundation

extension WorkbenchAIStore {
  /// Context choices exposed by the independent general chat window. These
  /// are only choices; none of them is attached to a request until the user
  /// explicitly selects it.
  public func availableGeneralAIChatContextReferences() -> [AIContextReference] {
    var references: [AIContextReference] = []
    if let draft = store.selectedDraft {
      if let selection = store.activeEditorSelection,
        selection.draftID == draft.id,
        selection.validatedRange(in: draft) != nil
      {
        references.append(
          .currentSelection(
            draftID: draft.id,
            range: selection.range,
            characterCount: selection.selectedText.count
          )
        )
      }
      references.append(
        .currentArticle(
          draftID: draft.id,
          title: draft.title,
          characterCount: draft.bodyMarkdown.count
        )
      )
      references.append(
        .publishCheck(
          draftID: draft.id,
          // This list is a choice preview only. Do not calculate preflight or
          // repository state until the user explicitly selects @发布检查.
          issueCount: 0,
          characterCount: 0
        )
      )
    }
    references.append(
      contentsOf: store.visibleDrafts.prefix(30).map {
        .specifiedArticle(
          draftID: $0.id,
          title: $0.title,
          characterCount: $0.bodyMarkdown.count
        )
      }
    )
    references.append(
      contentsOf: store.profiles.prefix(30).map {
        .siteProfile(
          profileID: $0.id,
          name: $0.name,
          characterCount: siteProfileContext($0).count
        )
      }
    )
    references.append(
      contentsOf: store.knowledge.documents
        .filter { !$0.isArchived && $0.allowsRemoteAIUse }
        .prefix(30)
        .map { document in
          let source =
            document.sourceURL?.absoluteString.nilIfEmpty
            ?? document.sourceName.nilIfEmpty
          return .knowledgeEntry(
            documentID: document.id,
            title: source.map { "\(document.title) · \($0)" } ?? document.title,
            characterCount: Int(clamping: document.sourceByteCount)
          )
        }
    )
    return references
  }

  func approvedGeneralAIChatContextReferences(
    _ references: [AIContextReference]
  ) -> [AIContextReference] {
    var seen = Set<String>()
    return references.prefix(8).filter { reference in
      let rangeKey = reference.sourceRange.map { "\($0.location):\($0.length)" } ?? ""
      let key = "\(reference.kind.rawValue)|\(reference.resourceID ?? "")|\(rangeKey)"
      guard seen.insert(key).inserted else { return false }

      switch reference.kind {
      case .currentSelection:
        guard
          let draftID = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let draft = store.visibleDrafts.first(where: { $0.id == draftID }),
          let requestedRange = reference.sourceRange?.nsRange,
          let active = store.activeEditorSelection,
          active.draftID == draftID,
          active.range == requestedRange
        else { return false }
        return active.validatedRange(in: draft) != nil
      case .currentArticle, .publishCheck:
        guard let draftID = reference.resourceID.flatMap(UUID.init(uuidString:)) else {
          return false
        }
        return store.selectedDraftID == draftID
      case .specifiedArticle:
        guard let draftID = reference.resourceID.flatMap(UUID.init(uuidString:)) else {
          return false
        }
        return store.visibleDrafts.contains { $0.id == draftID }
      case .siteProfile:
        guard let profileID = reference.resourceID.flatMap(UUID.init(uuidString:)) else {
          return false
        }
        return store.profiles.contains { $0.id == profileID }
      case .knowledgeEntry:
        guard let documentID = reference.resourceID.flatMap(UUID.init(uuidString:)) else {
          return false
        }
        return store.knowledge.documents.contains {
          $0.id == documentID && !$0.isArchived && $0.allowsRemoteAIUse
        }
      }
    }
  }

  func explicitGeneralAIChatContextPromptSnapshot(
    references: [AIContextReference]
  ) async -> AIContextPromptSnapshot? {
    let approved = approvedGeneralAIChatContextReferences(references)
    guard !approved.isEmpty else { return nil }

    var remaining = 24_000
    var sections: [String] = []
    var authorizationBindings: [KnowledgeAuthorizationBinding] = []
    func appendSection(
      _ value: String,
      authorizationBinding: KnowledgeAuthorizationBinding? = nil
    ) {
      guard remaining > 0 else { return }
      let minimized = AIOutboundPayloadPrivacyService().sanitize(value).text
      let bounded = String(minimized.prefix(remaining))
      guard !bounded.isEmpty else { return }
      sections.append(bounded)
      remaining -= bounded.count
      if let authorizationBinding {
        authorizationBindings.append(authorizationBinding)
      }
    }

    for reference in approved where remaining > 0 {
      switch reference.kind {
      case .currentSelection:
        guard
          let draftID = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let draft = store.visibleDrafts.first(where: { $0.id == draftID }),
          let range = reference.sourceRange?.nsRange
        else { continue }
        let body = draft.bodyMarkdown as NSString
        guard range.location >= 0, range.length >= 0,
          range.location <= body.length,
          range.length <= body.length - range.location
        else { continue }
        appendSection(
          """
          <explicit_current_selection>
          \(body.substring(with: range))
          </explicit_current_selection>
          """)
      case .currentArticle, .specifiedArticle:
        guard
          let draftID = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let draft = store.visibleDrafts.first(where: { $0.id == draftID })
        else { continue }
        appendSection(
          articleContext(
            draft,
            tag: reference.kind == .currentArticle
              ? "explicit_current_article"
              : "explicit_specified_article"
          ))
      case .siteProfile:
        guard
          let profileID = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let profile = store.profiles.first(where: { $0.id == profileID })
        else { continue }
        appendSection(
          """
          <explicit_site_profile>
          \(siteProfileContext(profile))
          </explicit_site_profile>
          """)
      case .knowledgeEntry:
        guard
          let documentID = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let document = store.knowledge.documents.first(where: { $0.id == documentID }),
          let snapshot = await store.knowledge.explicitAIContextSnapshot(documentID: documentID)
        else { continue }
        appendSection(
          """
          <explicit_knowledge_entry title="\(document.title)">
          来源：\(document.sourceURL?.absoluteString.nilIfEmpty ?? document.sourceName.nilIfEmpty ?? "本地资料库")
          \(String(snapshot.text.prefix(8_000)))
          </explicit_knowledge_entry>
          """,
          authorizationBinding: snapshot.authorizationBinding
        )
      case .publishCheck:
        guard
          let draftID = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let draft = store.visibleDrafts.first(where: { $0.id == draftID })
        else { continue }
        appendSection(
          """
          <explicit_publish_check>
          \(publishCheckContext(store.preflightIssues(for: draft)))
          </explicit_publish_check>
          """)
      }
    }
    guard let prompt = sections.joined(separator: "\n\n").nilIfEmpty else { return nil }
    return AIContextPromptSnapshot(
      prompt: prompt,
      authorizationBindings: authorizationBindings
    )
  }

  func explicitGeneralAIChatContextPrompt(
    references: [AIContextReference]
  ) async -> String? {
    await explicitGeneralAIChatContextPromptSnapshot(references: references)?.prompt
  }

  public func availableAIChatContextReferences(
    for draft: ArticleDraft
  ) -> [AIContextReference] {
    let profile = store.profile(for: draft)
    let issues = store.preflightIssues(for: draft)
    var references: [AIContextReference] = []

    if let selection = store.activeEditorSelection,
      selection.validatedRange(in: draft) != nil
    {
      references.append(
        .currentSelection(
          draftID: draft.id,
          range: selection.range,
          characterCount: selection.selectedText.count
        )
      )
    }
    references.append(
      .currentArticle(
        draftID: draft.id,
        title: draft.title,
        characterCount: draft.bodyMarkdown.count
      )
    )
    references.append(
      .siteProfile(
        profileID: profile.id,
        name: profile.name,
        characterCount: siteProfileContext(profile).count
      )
    )
    references.append(
      .publishCheck(
        draftID: draft.id,
        issueCount: issues.count,
        characterCount: publishCheckContext(issues).count
      )
    )
    references.append(
      contentsOf: store.visibleDrafts
        .filter { $0.id != draft.id }
        .prefix(30)
        .map {
          .specifiedArticle(
            draftID: $0.id,
            title: $0.title,
            characterCount: $0.bodyMarkdown.count
          )
        }
    )
    references.append(
      contentsOf: store.knowledge.documents
        .filter { !$0.isArchived && $0.allowsRemoteAIUse }
        .prefix(30)
        .map { document in
          let source =
            document.sourceURL?.absoluteString.nilIfEmpty
            ?? document.sourceName.nilIfEmpty
          let displayName =
            source.map { "\(document.title) · \($0)" }
            ?? document.title
          return AIContextReference.knowledgeEntry(
            documentID: document.id,
            title: displayName,
            characterCount: Int(clamping: document.sourceByteCount)
          )
        }
    )
    return references
  }

  func approvedAIChatContextReferences(
    _ references: [AIContextReference],
    for draft: ArticleDraft
  ) -> [AIContextReference] {
    let profile = store.profile(for: draft)
    var seen = Set<String>()
    return references.prefix(8).filter { reference in
      let rangeKey =
        reference.sourceRange.map {
          "\($0.location):\($0.length)"
        } ?? ""
      let key = "\(reference.kind.rawValue)|\(reference.resourceID ?? "")|\(rangeKey)"
      guard seen.insert(key).inserted else { return false }

      switch reference.kind {
      case .currentSelection:
        guard
          reference.resourceID == draft.id.uuidString,
          let requestedRange = reference.sourceRange?.nsRange,
          let active = store.activeEditorSelection,
          active.draftID == draft.id,
          active.range == requestedRange
        else {
          return false
        }
        return active.validatedRange(in: draft) != nil
      case .currentArticle, .publishCheck:
        return reference.resourceID == draft.id.uuidString
      case .specifiedArticle:
        guard let id = reference.resourceID.flatMap(UUID.init(uuidString:)) else {
          return false
        }
        return store.visibleDrafts.contains { $0.id == id && $0.id != draft.id }
      case .siteProfile:
        return reference.resourceID == profile.id.uuidString
      case .knowledgeEntry:
        guard let id = reference.resourceID.flatMap(UUID.init(uuidString:)) else {
          return false
        }
        return store.knowledge.documents.contains {
          $0.id == id && !$0.isArchived && $0.allowsRemoteAIUse
        }
      }
    }
  }

  func explicitAIChatContextPromptSnapshot(
    references: [AIContextReference],
    draft: ArticleDraft
  ) async -> AIContextPromptSnapshot? {
    let approved = approvedAIChatContextReferences(references, for: draft)
    guard !approved.isEmpty else { return nil }

    let profile = store.profile(for: draft)
    let characterBudget = 24_000
    var remaining = characterBudget
    var sections: [String] = []
    var authorizationBindings: [KnowledgeAuthorizationBinding] = []

    func appendSection(
      _ value: String,
      authorizationBinding: KnowledgeAuthorizationBinding? = nil
    ) {
      guard remaining > 0 else { return }
      let minimized = AIOutboundPayloadPrivacyService().sanitize(value).text
      let bounded = String(minimized.prefix(remaining))
      guard !bounded.isEmpty else { return }
      sections.append(bounded)
      remaining -= bounded.count
      if let authorizationBinding {
        authorizationBindings.append(authorizationBinding)
      }
    }

    for reference in approved where remaining > 0 {
      switch reference.kind {
      case .currentSelection:
        guard let range = reference.sourceRange?.nsRange else { continue }
        let body = draft.bodyMarkdown as NSString
        guard
          range.location >= 0,
          range.length >= 0,
          range.location <= body.length,
          range.length <= body.length - range.location
        else {
          continue
        }
        appendSection(
          """
          <explicit_current_selection>
          \(body.substring(with: range))
          </explicit_current_selection>
          """)
      case .currentArticle:
        appendSection(articleContext(draft, tag: "explicit_current_article"))
      case .specifiedArticle:
        guard
          let id = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let article = store.visibleDrafts.first(where: { $0.id == id })
        else {
          continue
        }
        appendSection(articleContext(article, tag: "explicit_specified_article"))
      case .siteProfile:
        appendSection(
          """
          <explicit_site_profile>
          \(siteProfileContext(profile))
          </explicit_site_profile>
          """)
      case .knowledgeEntry:
        guard
          let id = reference.resourceID.flatMap(UUID.init(uuidString:)),
          let document = store.knowledge.documents.first(where: { $0.id == id }),
          let snapshot = await store.knowledge.explicitAIContextSnapshot(documentID: id)
        else {
          continue
        }
        appendSection(
          """
          <explicit_knowledge_entry title="\(document.title)">
          来源：\(document.sourceURL?.absoluteString.nilIfEmpty ?? document.sourceName.nilIfEmpty ?? "本地资料库")
          \(String(snapshot.text.prefix(8_000)))
          </explicit_knowledge_entry>
          """,
          authorizationBinding: snapshot.authorizationBinding
        )
      case .publishCheck:
        appendSection(
          """
          <explicit_publish_check>
          \(publishCheckContext(store.preflightIssues(for: draft)))
          </explicit_publish_check>
          """)
      }
    }
    guard let prompt = sections.joined(separator: "\n\n").nilIfEmpty else { return nil }
    return AIContextPromptSnapshot(
      prompt: prompt,
      authorizationBindings: authorizationBindings
    )
  }

  func explicitAIChatContextPrompt(
    references: [AIContextReference],
    draft: ArticleDraft
  ) async -> String? {
    await explicitAIChatContextPromptSnapshot(references: references, draft: draft)?.prompt
  }

  func articleContext(_ article: ArticleDraft, tag: String) -> String {
    """
    <\(tag)>
    标题：\(article.title)
    摘要：\(article.summary.nilIfEmpty ?? "未设置")
    标签：\(article.tags.joined(separator: "、"))
    正文：
    \(String(article.bodyMarkdown.prefix(12_000)))
    </\(tag)>
    """
  }

  func siteProfileContext(_ profile: SiteProfile) -> String {
    """
    站点：\(profile.name)
    生成器：\(profile.siteKind.displayName)
    Front Matter：\(profile.frontMatterStyle.rawValue)
    内容目录：\(profile.contentRoot)
    资源目录：\(profile.assetRoot)
    Markdown 路径规则：\(profile.markdownPathPattern)
    图片路径规则：\(profile.imagePathPattern)
    公开图片规则：\(profile.publicImagePathPattern)
    默认作者：\(profile.defaultAuthor.nilIfEmpty ?? "未设置")
    默认标签：\(profile.defaultTags.joined(separator: "、"))
    默认分类：\(profile.defaultCategories.joined(separator: "、"))
    写作风格：\(profile.aiWritingStylePromptInstructions)
    """
  }

  func publishCheckContext(_ issues: [PreflightIssue]) -> String {
    guard !issues.isEmpty else { return "当前发布检查没有发现问题。" }
    return issues.prefix(40).map { issue in
      "- [\(issue.severity.rawValue)] \(issue.title)：\(issue.message)"
    }.joined(separator: "\n")
  }
}
