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

    var updated = previewDraft
    var markdownBlocks: [String] = []
    var insertedMetadata: [InsertedImageMetadataDraft] = []
    for url in imageURLs {
      let selectedAlt = selectedText(in: updated.bodyMarkdown).trimmedForPublishing
      var attachment = store.makeAttachment(from: url, draft: updated)
      if !selectedAlt.isEmpty {
        attachment.altText = selectedAlt
      }
      updated.attachments.append(attachment)
      markdownBlocks.append(
        imageMetadataEditingService.markdownReference(
          altText: attachment.altText,
          imagePath: attachment.relativePublishPath
        )
      )
      insertedMetadata.append(
        InsertedImageMetadataDraft(
          attachment: attachment,
          coverAttachmentID: updated.coverAttachmentID
        )
      )
    }

    let insertedDraft = replacingSelection(
      in: updated,
      with: markdownBlocks.joined(separator: "\n")
    )
    guard applyDraftUpdate(insertedDraft) else { return }

    insertedImageMetadataDrafts = insertedMetadata
    activeInsertedImageMetadataID = insertedMetadata.first?.id
    store.scheduleImageWorkbenchCachesRefresh(for: insertedDraft)
    selectionActionMessage = "已在光标位置插入 \(imageURLs.count) 张图片，请完善图片信息。"
    EditorAccessibilityAnnouncementCenter.announceImageInsertion(count: imageURLs.count)
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

    var updated = previewDraft
    let selectedTitle = selectedText(in: updated.bodyMarkdown).trimmedForPublishing
    let htmlBlocks = videoURLs.map { url in
      let attachment = store.makeVideoAttachment(from: url, draft: updated)
      updated.attachments.append(attachment)
      let accessibleTitle = videoURLs.count == 1 && !selectedTitle.isEmpty
        ? selectedTitle
        : VideoFileSupport.accessibleTitle(for: url)
      return VideoFileSupport.htmlEmbed(
        publicPath: attachment.relativePublishPath,
        accessibleTitle: accessibleTitle
      )
    }

    let insertedDraft = replacingSelection(
      in: updated,
      with: htmlBlocks.joined(separator: "\n\n")
    )
    guard applyDraftUpdate(insertedDraft) else { return }
    selectionActionMessage = String(
      format: String(localized: "已在光标位置插入 %@ 个视频。"),
      "\(videoURLs.count)"
    )
    EditorAccessibilityAnnouncementCenter.announceVideoInsertion(count: videoURLs.count)
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
  }
}
