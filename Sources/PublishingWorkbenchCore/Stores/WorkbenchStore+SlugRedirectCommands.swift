import Foundation

extension WorkbenchStore {
  public func slugChangeImpact(for draftID: UUID) -> SlugChangeImpact? {
    guard let target = draft(for: draftID), !target.isGeneralDraft else { return nil }
    let sameSiteDrafts = draftsForSlugRedirectImpact(target: target)
    return SlugChangeRedirectService().impact(
      target: target,
      drafts: draftsOverlayingEditorBuffers(sameSiteDrafts),
      profile: profile(for: target)
    )
  }

  @discardableResult
  public func updateReferencesForPendingSlugChange(
    draftID: UUID
  ) -> SlugChangeApplicationResult {
    guard let initialTarget = draft(for: draftID), !initialTarget.isGeneralDraft else {
      return slugChangeFailure("目标文章不存在或不是站点稿件。")
    }
    let initialDrafts = draftsOverlayingEditorBuffers(
      draftsForSlugRedirectImpact(target: initialTarget)
    )
    guard let initialImpact = SlugChangeRedirectService().impact(
      target: initialTarget,
      drafts: initialDrafts,
      profile: profile(for: initialTarget)
    ) else {
      return slugChangeFailure("没有待处理的 Slug 变更。")
    }

    let affectedIDs = Set(initialImpact.references.map(\.sourceDraftID)).union([draftID])
    for affectedID in affectedIDs {
      flushDraftBodyEditorBuffer(for: affectedID)
    }
    guard let target = draft(for: draftID) else {
      return slugChangeFailure("目标文章在应用前已发生变化。")
    }
    let sameSiteDrafts = draftsForSlugRedirectImpact(target: target)
    guard let impact = SlugChangeRedirectService().impact(
      target: target,
      drafts: sameSiteDrafts,
      profile: profile(for: target)
    ),
      let replacementBodies = SlugChangeRedirectService().replacementBodies(
        for: impact,
        target: target,
        drafts: sameSiteDrafts
      )
    else {
      return slugChangeFailure("文章在预览后发生变化，未更新任何引用。")
    }

    let baselines = Dictionary(uniqueKeysWithValues: replacementBodies.keys.compactMap { id in
      draftOperationBaseline(for: id).map { (id, $0) }
    })
    guard baselines.count == replacementBodies.count else {
      return slugChangeFailure("无法建立完整的文章版本基线，未更新任何引用。")
    }
    _ = publishingStore.recordVersionsBeforeBatchProcessing(
      draftIDs: Set(replacementBodies.keys).union([draftID]),
      store: self
    )
    guard baselines.values.allSatisfy(draftStillMatchesOperationBaseline) else {
      return slugChangeFailure("创建恢复版本时检测到新的编辑，未更新任何引用。")
    }

    var applied: [(draftID: UUID, originalBody: String)] = []
    for draftID in replacementBodies.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard let proposedBody = replacementBodies[draftID],
        let baseline = baselines[draftID],
        let result = replaceDraftBody(
          proposedBody,
          for: draftID,
          expectedRevision: baseline.bodyRevision
        ),
        result.wasAccepted
      else {
        restoreStagedSlugReferenceBodies(applied.reversed())
        return slugChangeFailure("写入期间检测到版本变化，已撤销本次引用更新。")
      }
      applied.append((draftID, baseline.draft.bodyMarkdown))
    }
    for draftID in replacementBodies.keys {
      flushDraftBodyEditorBuffer(for: draftID)
    }

    guard var updatedTarget = draft(for: impact.targetDraftID) else {
      restoreCommittedSlugReferenceBodies(applied.reversed())
      return slugChangeFailure("目标文章在提交时消失，已撤销本次引用更新。")
    }
    updatedTarget.clearPendingSlugRedirectPaths()
    updateDraft(updatedTarget)
    let message = impact.referenceCount == 0
      ? "已确认不需要更新站内引用。"
      : "已更新 \(impact.affectedDraftCount) 篇文章中的 \(impact.referenceCount) 处旧 Slug 引用。"
    setPublishActionMessage(message, status: .success)
    return SlugChangeApplicationResult(
      wasApplied: true,
      affectedDraftCount: impact.affectedDraftCount,
      referenceCount: impact.referenceCount,
      message: message
    )
  }

  @discardableResult
  public func addAliasesForPendingSlugChange(
    draftID: UUID
  ) -> SlugChangeApplicationResult {
    guard let target = draft(for: draftID), !target.isGeneralDraft,
      let impact = SlugChangeRedirectService().impact(
        target: target,
        drafts: draftsForSlugRedirectImpact(target: target),
        profile: profile(for: target)
      )
    else {
      return slugChangeFailure("没有待处理的 Slug 变更。")
    }
    guard impact.conflictingAliasRoutes.isEmpty else {
      return slugChangeFailure(
        "旧地址已被其他文章占用：\(impact.conflictingAliasRoutes.joined(separator: "、"))。"
      )
    }
    flushDraftBodyEditorBuffer(for: draftID)
    _ = publishingStore.recordVersionsBeforeBatchProcessing(
      draftIDs: Set([draftID]),
      store: self
    )
    guard var refreshedTarget = draft(for: draftID) else {
      return slugChangeFailure("目标文章在提交时消失，未写入 aliases。")
    }
    let existing = Set(refreshedTarget.aliases.map {
      $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    })
    refreshedTarget.aliases.append(contentsOf: impact.oldRoutes.filter {
      !existing.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    })
    refreshedTarget.clearPendingSlugRedirectPaths()
    updateDraft(refreshedTarget)
    let message = "已将旧地址写入 Front Matter 的 aliases；实际跳转由站点框架或重定向插件生成。"
    setPublishActionMessage(message, status: .success)
    return SlugChangeApplicationResult(
      wasApplied: true,
      affectedDraftCount: 1,
      referenceCount: impact.oldRoutes.count,
      message: message
    )
  }

  private func draftsForSlugRedirectImpact(target: ArticleDraft) -> [ArticleDraft] {
    drafts.filter { $0.belongs(toSiteProfileID: target.siteProfileID) }
  }

  private func draftsOverlayingEditorBuffers(_ source: [ArticleDraft]) -> [ArticleDraft] {
    source.map { draft in
      let buffer = draftBodyEditorBuffer(for: draft.id)
      guard buffer.isDirty else { return draft }
      var overlaid = draft
      overlaid.bodyMarkdown = buffer.bodyMarkdown
      return overlaid
    }
  }

  private func restoreStagedSlugReferenceBodies<S: Sequence>(
    _ applied: S
  ) where S.Element == (draftID: UUID, originalBody: String) {
    for item in applied {
      let current = draftBodyEditorBuffer(for: item.draftID)
      _ = replaceDraftBody(
        item.originalBody,
        for: item.draftID,
        expectedRevision: current.revision
      )
    }
  }

  private func restoreCommittedSlugReferenceBodies<S: Sequence>(
    _ applied: S
  ) where S.Element == (draftID: UUID, originalBody: String) {
    for item in applied {
      let current = draftBodyEditorBuffer(for: item.draftID)
      _ = replaceDraftBody(
        item.originalBody,
        for: item.draftID,
        expectedRevision: current.revision
      )
      flushDraftBodyEditorBuffer(for: item.draftID)
    }
  }

  private func slugChangeFailure(_ message: String) -> SlugChangeApplicationResult {
    setPublishActionMessage(message, status: .warning)
    return SlugChangeApplicationResult(wasApplied: false, message: message)
  }
}
