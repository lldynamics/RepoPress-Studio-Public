import Foundation

public struct DraftOwnershipTransferService: Sendable {
  public init() {}

  public func plan(
    draftIDs: [UUID],
    operation: DraftOwnershipTransferOperation,
    targetProfileID: UUID?,
    drafts: [ArticleDraft],
    profiles: [SiteProfile]
  ) -> DraftOwnershipTransferPlan {
    let requestedIDs = Set(draftIDs)
    let sources = drafts.filter { requestedIDs.contains($0.id) }
    var globalConflicts: [DraftOwnershipTransferConflict] = []

    for missingID in requestedIDs.subtracting(Set(sources.map(\.id))) {
      globalConflicts.append(
        DraftOwnershipTransferConflict(
          id: "missing-source-\(missingID.uuidString)",
          kind: .unavailableSource,
          draftID: missingID,
          title: CoreL10n.text("文章已不存在"),
          message: CoreL10n.text("所选文章已被删除或移动，请关闭面板后重新选择。")
        )
      )
    }

    let targetProfile = targetProfileID.flatMap { id in profiles.first(where: { $0.id == id }) }
    if operation != .moveToGeneral {
      if targetProfile == nil || targetProfile?.purpose == .generalDraftBackup {
        globalConflicts.append(
          DraftOwnershipTransferConflict(
            id: "missing-target-\(targetProfileID?.uuidString ?? "none")",
            kind: .unavailableTarget,
            draftID: nil,
            title: CoreL10n.text("目标站点不可用"),
            message: CoreL10n.text("目标站点已不存在或不是可接收文章的站点，请重新选择。")
          )
        )
      }
    }

    var items = sources.map { source in
      makeItem(
        source: source,
        operation: operation,
        targetProfile: targetProfile,
        profiles: profiles
      )
    }

    for index in items.indices {
      let source = sources[index]
      let isNoOp = operation == .moveToGeneral
        ? source.isGeneralDraft
        : targetProfile.map { source.belongs(toSiteProfileID: $0.id) } == true
      guard isNoOp else { continue }
      let conflict = DraftOwnershipTransferConflict(
        id: "same-destination-\(source.id.uuidString)",
        kind: .sameDestination,
        draftID: source.id,
        title: CoreL10n.text("文章已属于该位置"),
        message: operation == .moveToGeneral
          ? CoreL10n.text("所选内容已经是通用草稿。")
          : CoreL10n.text("所选文章已经属于目标站点。")
      )
      items[index].conflicts.append(conflict)
      globalConflicts.append(conflict)
    }

    if let targetProfile, operation != .moveToGeneral {
      let selectedIDs = Set(items.map(\.draftID))
      let occupiedPaths = Dictionary(grouping: drafts.filter { draft in
        draft.belongs(toSiteProfileID: targetProfile.id) && !selectedIDs.contains(draft.id)
      }) { draft in
        collisionKey(for: targetProfile.markdownPath(for: draft))
      }

      for index in items.indices {
        guard let displayPath = items[index].targetMarkdownPath?.normalizedRelativePath().nilIfEmpty,
              let occupied = occupiedPaths[collisionKey(for: displayPath)],
              !occupied.isEmpty else {
          continue
        }
        let conflict = DraftOwnershipTransferConflict(
          id: "occupied-\(items[index].draftID.uuidString)-\(collisionKey(for: displayPath))",
          kind: .targetPathOccupied,
          draftID: items[index].draftID,
          title: CoreL10n.text("目标路径已被占用"),
          message: CoreL10n.format(
            "目标站点已有文章使用 %@。请先修改当前文章的 slug 或日期。",
            displayPath
          )
        )
        items[index].conflicts.append(conflict)
        globalConflicts.append(conflict)
      }

      let targetPathGroups = Dictionary(grouping: items.indices) { index in
        collisionKey(for: items[index].targetMarkdownPath ?? "")
      }
      for (collisionPath, indices) in targetPathGroups where !collisionPath.isEmpty && indices.count > 1 {
        for index in indices {
          let displayPath = items[index].targetMarkdownPath?.normalizedRelativePath() ?? collisionPath
          let conflict = DraftOwnershipTransferConflict(
            id: "batch-duplicate-\(items[index].draftID.uuidString)-\(collisionPath)",
            kind: .duplicateTargetPath,
            draftID: items[index].draftID,
            title: CoreL10n.text("批量目标路径重复"),
            message: CoreL10n.format(
              "多篇所选文章都会生成 %@。请先为它们设置不同的 slug 或日期。",
              displayPath
            )
          )
          items[index].conflicts.append(conflict)
          globalConflicts.append(conflict)
        }
      }
    }

    return DraftOwnershipTransferPlan(
      operation: operation,
      targetProfileID: operation == .moveToGeneral ? nil : targetProfileID,
      items: items,
      conflicts: globalConflicts
    )
  }

  private func makeItem(
    source: ArticleDraft,
    operation: DraftOwnershipTransferOperation,
    targetProfile: SiteProfile?,
    profiles: [SiteProfile]
  ) -> DraftOwnershipTransferItem {
    let sourceProfile = source.isGeneralDraft
      ? nil
      : profiles.first(where: { $0.id == source.siteProfileID })
    let sourceMarkdownPath = sourceProfile.map { profile in
      source.repositoryPath?.normalizedRelativePath().nilIfEmpty
        ?? profile.markdownPath(for: source).normalizedRelativePath()
    }
    let sourcePermalink = sourceProfile.map {
      SEOSocialPreviewService().snapshot(draft: source, profile: $0).canonicalURLText
    }

    var targetDraft = source
    if let targetProfile {
      targetDraft.assignToSite(targetProfile.id)
      targetDraft.detachFromRepository()
    }
    let targetMarkdownPath = targetProfile.map { $0.markdownPath(for: targetDraft).normalizedRelativePath() }
    let targetPermalink = targetProfile.map {
      SEOSocialPreviewService().snapshot(draft: targetDraft, profile: $0).canonicalURLText
    }

    return DraftOwnershipTransferItem(
      draftID: source.id,
      title: source.title.trimmedForPublishing.nilIfEmpty ?? CoreL10n.text("未命名文章"),
      sourceProfileName: sourceProfile?.name ?? CoreL10n.text("通用草稿"),
      sourceMarkdownPath: sourceMarkdownPath,
      sourcePermalink: sourcePermalink,
      targetProfileName: operation == .moveToGeneral
        ? CoreL10n.text("通用草稿")
        : (targetProfile?.name ?? CoreL10n.text("不可用站点")),
      targetMarkdownPath: operation == .moveToGeneral ? nil : targetMarkdownPath,
      targetPermalink: operation == .moveToGeneral ? nil : targetPermalink,
      sourceUpdatedAt: source.updatedAt
    )
  }

  private func collisionKey(for path: String) -> String {
    path
      .normalizedRelativePath()
      .precomposedStringWithCanonicalMapping
      .lowercased()
  }
}
