import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
  func insertImageReferences(_ urls: [URL]) {
    guard requireBodyEditingContext() else { return }
    let imageURLs = ImageFileSupport.supportedImageURLs(in: urls)
    guard !imageURLs.isEmpty else {
      selectionActionMessage = "没有可插入的图片文件。"
      EditorAccessibilityAnnouncementCenter.announce(
        String(localized: "没有可插入的图片文件。"),
        priority: .high
      )
      return
    }

    cancelAttachmentImport()
    let requestID = UUID()
    let expectedDraftID = draft.id
    let sourceDraft = previewDraft
    let selectedAlt = selectedText(in: sourceDraft.bodyMarkdown).trimmedForPublishing
    let fileStore = store.managedAttachmentFileStore
    attachmentImportRequestID = requestID
    attachmentImportTask = Task { @MainActor in
      var importedAttachments: [DraftAttachment] = []
      var failureMessages: [String] = []
      defer {
        if attachmentImportRequestID == requestID {
          attachmentImportTask = nil
          attachmentImportRequestID = nil
        }
      }

      for url in imageURLs {
        do {
          var attachment = try await store.makeAttachment(
            from: url,
            draft: sourceDraft,
            fileStore: fileStore
          )
          if !selectedAlt.isEmpty {
            attachment.altText = selectedAlt
          }
          importedAttachments.append(attachment)
        } catch is CancellationError {
          discardManagedAttachments(importedAttachments, fileStore: fileStore)
          return
        } catch {
          failureMessages.append(error.localizedDescription)
        }
      }

      guard !Task.isCancelled,
            attachmentImportRequestID == requestID,
            draft.id == expectedDraftID,
            requireBodyEditingContext() else {
        discardManagedAttachments(importedAttachments, fileStore: fileStore)
        return
      }
      guard !importedAttachments.isEmpty else {
        let message = failureMessages.first
          ?? String(localized: "没有可插入的图片文件。")
        selectionActionMessage = message
        EditorAccessibilityAnnouncementCenter.announce(message, priority: .high)
        return
      }

      var updated = previewDraft
      updated.attachments.append(contentsOf: importedAttachments)
      let markdownBlocks = importedAttachments.map { attachment in
        imageMetadataEditingService.markdownReference(
          altText: attachment.altText,
          imagePath: attachment.relativePublishPath
        )
      }
      let insertedDraft = replacingSelection(
        in: updated,
        with: markdownBlocks.joined(separator: "\n")
      )
      guard applyDraftUpdate(insertedDraft) else {
        discardManagedAttachments(importedAttachments, fileStore: fileStore)
        return
      }

      let insertedMetadata = importedAttachments.map { attachment in
        InsertedImageMetadataDraft(
          attachment: attachment,
          coverAttachmentID: updated.coverAttachmentID
        )
      }

      insertedImageMetadataDrafts = insertedMetadata
      activeInsertedImageMetadataID = insertedMetadata.first?.id
      showWritingContextPanel(.imageInfo)
      store.scheduleImageWorkbenchCachesRefresh(for: insertedDraft)
      let successMessage = String(
        format: String(localized: "已插入 %@ 张图片，请完善图片信息。"),
        "\(importedAttachments.count)"
      )
      selectionActionMessage = ([successMessage] + failureMessages)
        .joined(separator: "\n")
      EditorAccessibilityAnnouncementCenter.announceImageInsertion(
        count: importedAttachments.count
      )
    }
  }

  func insertVideoReferences(_ urls: [URL]) {
    guard requireBodyEditingContext() else { return }
    let videoURLs = VideoFileSupport.supportedVideoURLs(in: urls)
    guard !videoURLs.isEmpty else {
      selectionActionMessage = "没有可插入的视频文件。"
      EditorAccessibilityAnnouncementCenter.announce(
        String(localized: "没有可插入的视频文件。"),
        priority: .high
      )
      return
    }

    cancelAttachmentImport()
    let requestID = UUID()
    let expectedDraftID = draft.id
    let sourceDraft = previewDraft
    let selectedTitle = selectedText(in: sourceDraft.bodyMarkdown).trimmedForPublishing
    let fileStore = store.managedAttachmentFileStore
    attachmentImportRequestID = requestID
    attachmentImportTask = Task { @MainActor in
      var importedAttachments: [(attachment: DraftAttachment, sourceURL: URL)] = []
      var failureMessages: [String] = []
      defer {
        if attachmentImportRequestID == requestID {
          attachmentImportTask = nil
          attachmentImportRequestID = nil
        }
      }

      for url in videoURLs {
        do {
          let attachment = try await store.makeVideoAttachment(
            from: url,
            draft: sourceDraft,
            fileStore: fileStore
          )
          importedAttachments.append((attachment, url))
        } catch is CancellationError {
          discardManagedAttachments(
            importedAttachments.map { $0.attachment },
            fileStore: fileStore
          )
          return
        } catch {
          failureMessages.append(error.localizedDescription)
        }
      }

      guard !Task.isCancelled,
            attachmentImportRequestID == requestID,
            draft.id == expectedDraftID,
            requireBodyEditingContext() else {
        discardManagedAttachments(
          importedAttachments.map { $0.attachment },
          fileStore: fileStore
        )
        return
      }
      guard !importedAttachments.isEmpty else {
        let message = failureMessages.first
          ?? String(localized: "没有可插入的视频文件。")
        selectionActionMessage = message
        EditorAccessibilityAnnouncementCenter.announce(message, priority: .high)
        return
      }

      var updated = previewDraft
      updated.attachments.append(contentsOf: importedAttachments.map { $0.attachment })
      let htmlBlocks = importedAttachments.map { item in
        let accessibleTitle = importedAttachments.count == 1 && !selectedTitle.isEmpty
          ? selectedTitle
          : VideoFileSupport.accessibleTitle(for: item.sourceURL)
        return VideoFileSupport.htmlEmbed(
          publicPath: item.attachment.relativePublishPath,
          accessibleTitle: accessibleTitle
        )
      }
      let insertedDraft = replacingSelection(
        in: updated,
        with: htmlBlocks.joined(separator: "\n\n")
      )
      guard applyDraftUpdate(insertedDraft) else {
        discardManagedAttachments(
          importedAttachments.map { $0.attachment },
          fileStore: fileStore
        )
        return
      }
      let successMessage = String(
        format: String(localized: "已在光标位置插入 %@ 个视频。"),
        "\(importedAttachments.count)"
      )
      selectionActionMessage = ([successMessage] + failureMessages)
        .joined(separator: "\n")
      EditorAccessibilityAnnouncementCenter.announceVideoInsertion(
        count: importedAttachments.count
      )
    }
  }

  func cancelAttachmentImport() {
    attachmentImportRequestID = nil
    attachmentImportTask?.cancel()
    attachmentImportTask = nil
  }

  private func discardManagedAttachments(
    _ attachments: [DraftAttachment],
    fileStore: ManagedAttachmentFileStore
  ) {
    for attachment in attachments {
      guard let sourceFilePath = attachment.sourceFilePath else { continue }
      fileStore.discardStoredFile(at: URL(fileURLWithPath: sourceFilePath))
    }
  }

  var activeInsertedImageMetadataIndex: Int? {
    guard let activeInsertedImageMetadataID else { return nil }
    return insertedImageMetadataDrafts.firstIndex { $0.id == activeInsertedImageMetadataID }
  }

  var activeInsertedImageMetadataBinding: Binding<InsertedImageMetadataDraft>? {
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

  func setPendingImageCover(_ isCover: Bool, attachmentID: UUID) {
    for index in insertedImageMetadataDrafts.indices {
      if insertedImageMetadataDrafts[index].id == attachmentID {
        insertedImageMetadataDrafts[index].isCover = isCover
      } else if isCover {
        insertedImageMetadataDrafts[index].isCover = false
      }
    }
  }

  func moveToPreviousInsertedImage() {
    guard let index = activeInsertedImageMetadataIndex, index > 0 else { return }
    activeInsertedImageMetadataID = insertedImageMetadataDrafts[index - 1].id
  }

  func applyInsertedImageMetadataAndAdvance() {
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

  func openInsertedImageInspector() {
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

  func applyInsertedImageMetadata(attachmentIDs: Set<UUID>) -> Bool {
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

  func dismissInsertedImageMetadata() {
    insertedImageMetadataDrafts = []
    activeInsertedImageMetadataID = nil
    if activeWritingContextPanel == .imageInfo {
      activeWritingContextPanel = nil
    }
  }
}
