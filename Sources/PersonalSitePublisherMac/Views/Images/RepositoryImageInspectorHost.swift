import ImageIO
import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

struct RepositoryImageInspectorHost: View {
  let store: WorkbenchStore
  @ObservedObject var session: RepositoryImageBrowserSession
  let onOpenDraft: (UUID) -> Void
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade

  init(
    store: WorkbenchStore, session: RepositoryImageBrowserSession,
    onOpenDraft: @escaping (UUID) -> Void
  ) {
    self.store = store
    self.session = session
    self.onOpenDraft = onOpenDraft
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
  }

  var body: some View {
    Group {
      if session.matches(store.activeProfile), let asset = session.selectedAsset,
        session.resourceMode == .repository
      {
        RepositoryImageInspectorContent(
          store: store, session: session, asset: asset,
          isWorking: imageWorkbench.isProcessingBatch, onOpenDraft: onOpenDraft)
      } else {
        EmptyStateView(
          title: session.selectedPaths.count > 1 ? "已选择多张图片" : "选择一张图片",
          message: session.selectedPaths.count > 1
            ? "使用“处理所选…”预览批处理范围，或选择单张图片查看文章用法。"
            : "在图库中选择图片，查看文件信息和文章中的用法。",
          systemImage: "photo.on.rectangle", density: .compactPane
        )
      }
    }
    .background(.bar)
  }
}

private struct RepositoryImageInspectorContent: View {
  let store: WorkbenchStore
  @ObservedObject var session: RepositoryImageBrowserSession
  let asset: RepositoryImageAsset
  let isWorking: Bool
  let onOpenDraft: (UUID) -> Void
  @StateObject private var saveStatus: WorkbenchMarkdownEditorSaveStatusFeatureFacade
  @State private var dimensionsText: String?
  @State private var editError: String?

  init(
    store: WorkbenchStore, session: RepositoryImageBrowserSession,
    asset: RepositoryImageAsset, isWorking: Bool, onOpenDraft: @escaping (UUID) -> Void
  ) {
    self.store = store
    self.session = session
    self.asset = asset
    self.isWorking = isWorking
    self.onOpenDraft = onOpenDraft
    _saveStatus = StateObject(
      wrappedValue: WorkbenchMarkdownEditorSaveStatusFeatureFacade(
        store: store, draftID: session.targetDraftID ?? store.activeProfile.id))
  }

  private var usage: RepositoryImageArticleUsage? {
    guard let draftID = session.targetDraftID,
      let draft = store.draft(for: draftID), draft.belongs(toSiteProfileID: store.activeProfile.id),
      let attachment = draft.attachments.first(where: {
        $0.mediaKind == .image && $0.repositoryPath == asset.repositoryPath
      })
    else { return nil }
    return RepositoryImageArticleUsage(
      draftID: draftID, attachmentID: attachment.id,
      altText: attachment.altText, caption: attachment.caption,
      isCover: draft.coverAttachmentID == attachment.id)
  }

  var body: some View {
    let currentUsage = usage
    VStack(spacing: 0) {
      RepositoryImageInspectorView(
        asset: asset, dimensionsText: dimensionsText,
        availableDrafts: store.visibleDrafts.map {
          RepositoryImageTargetDraft(id: $0.id, title: $0.title)
        },
        targetDraftID: $session.targetDraftID, usage: currentUsage, isWorking: isWorking,
        saveStatusText: editError ?? saveStatus.shortSaveStatus,
        saveStatusIsError: editError != nil || saveStatus.saveFailure != nil,
        onEditAlt: { edit(.altText($0), usage: currentUsage) },
        onEditCaption: { edit(.caption($0), usage: currentUsage) },
        onSetCover: { edit(.cover($0), usage: currentUsage) },
        onFillMetadata: { edit(.fillMissing, usage: currentUsage) },
        onAttach: attach,
        onOpenDraft: onOpenDraft,
        onPreview: { session.previewURL = asset.fileURL }
      )
      if let failure = saveStatus.saveFailure, currentUsage != nil {
        VStack(alignment: .leading, spacing: 6) {
          Text(failure.message).font(.caption).foregroundStyle(.red)
          if failure.canRetry {
            Button("重试保存") { saveStatus.retrySave() }.buttonStyle(.bordered)
          }
        }.padding(12)
      }
    }
    .onChange(of: session.targetDraftID) { _, draftID in
      editError = nil
      if let draftID { saveStatus.trackDraft(draftID) }
    }
    .onChange(of: asset.repositoryPath) { _, _ in editError = nil }
    .task(id: asset) {
      dimensionsText = nil
      let url = asset.fileURL
      let dimensions = await Task.detached(priority: .utility) {
        guard
          let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil as String? }
        return "\(width) × \(height)"
      }.value
      if !Task.isCancelled { dimensionsText = dimensions }
    }
  }

  private func edit(_ edit: RepositoryImageUsageEdit, usage: RepositoryImageArticleUsage?) {
    guard !isWorking, session.matches(store.activeProfile), let usage,
      session.selectedAsset?.repositoryPath == asset.repositoryPath,
      session.targetDraftID == usage.draftID
    else { return }
    if store.editRepositoryImageUsage(
      draftID: usage.draftID, attachmentID: usage.attachmentID,
      expectedRepositoryPath: asset.repositoryPath, profileID: store.activeProfile.id, edit: edit
    ) {
      editError = nil
    } else {
      editError = String(localized: "图片或文章已变化，请重新选择后编辑。")
    }
  }

  private func attach(to draftID: UUID) {
    guard !isWorking, session.matches(store.activeProfile),
      store.visibleDrafts.contains(where: { $0.id == draftID })
    else { return }
    store.imageWorkbench.attachRepositoryImage(
      repositoryPath: asset.repositoryPath, toDraftID: draftID)
    session.targetDraftID = draftID
    session.refreshRequestID = UUID()
  }
}

// Adapt store models at the feature boundary; presentation and selection state stay value-only.
extension RepositoryImageInventorySource {
  init(_ profile: SiteProfile) {
    self.init(
      profileID: profile.id, repositoryPath: profile.localRepositoryRootPath,
      assetRoot: profile.assetRoot)
  }
}

extension RepositoryImageBrowserSession {
  func prepare(for profile: SiteProfile, preferredDraftID: UUID?) {
    prepare(for: RepositoryImageInventorySource(profile), preferredDraftID: preferredDraftID)
  }

  func matches(_ profile: SiteProfile) -> Bool {
    matches(source: RepositoryImageInventorySource(profile))
  }
}

extension ImageBatchPreviewContext {
  @MainActor init(store: WorkbenchStore) {
    self.init(
      source: RepositoryImageInventorySource(store.activeProfile),
      imageRevision: store.imageWorkbenchInputRevision)
  }

  @MainActor func matches(_ store: WorkbenchStore) -> Bool {
    source == RepositoryImageInventorySource(store.activeProfile)
      && imageRevision == store.imageWorkbenchInputRevision
  }
}

extension ImageBatchSelectionValidation {
  static func isValid(
    _ selection: [UUID: Set<UUID>], affectedItems: [ImageBatchAffectedItem], drafts: [ArticleDraft]
  ) -> Bool {
    let paths = Dictionary(
      uniqueKeysWithValues: drafts.map { draft in
        (
          draft.id,
          Dictionary(
            uniqueKeysWithValues: draft.attachments.filter { $0.mediaKind == .image }.map {
              ($0.id, $0.repositoryPath)
            })
        )
      })
    return isValid(selection, affectedItems: affectedItems, draftAttachmentPaths: paths)
  }
}
