import Foundation

public enum RepositoryImageUsageEdit: Sendable {
  case altText(String)
  case caption(String)
  case cover(Bool)
  case fillMissing
}

extension WorkbenchStore {
  /// Applies one field to the current attachment, without changing window selection.
  /// The expected path prevents a stale inspector from editing a replaced attachment.
  @discardableResult
  public func editRepositoryImageUsage(
    draftID: UUID, attachmentID: UUID, expectedRepositoryPath: String,
    profileID: UUID, edit: RepositoryImageUsageEdit
  ) -> Bool {
    guard activeProfile.id == profileID,
      let original = draft(for: draftID), original.belongs(toSiteProfileID: profileID),
      let attachment = original.attachments.first(where: { $0.id == attachmentID }),
      attachment.mediaKind == .image,
      attachment.repositoryPath == expectedRepositoryPath
    else { return false }

    flushDraftBodyEditorBuffer(for: draftID)
    guard let current = draft(for: draftID),
      let index = current.attachments.firstIndex(where: { $0.id == attachmentID })
    else { return false }
    let buffer = draftBodyEditorBuffer(for: draftID)
    var updated = current
    switch edit {
    case .altText(let value):
      guard
        let result = ImageMetadataEditingService().updating(
          draft: current, attachmentID: attachmentID, altText: value,
          caption: current.attachments[index].caption,
          isCover: current.coverAttachmentID == attachmentID
        )
      else { return false }
      updated = result.draft
      // Preserve in-progress whitespace in the input; Markdown uses normalized, escaped text.
      updated.attachments[index].altText = value
    case .caption(let value):
      updated.attachments[index].caption = value
    case .cover(let value):
      if value {
        updated.coverAttachmentID = attachmentID
      } else if updated.coverAttachmentID == attachmentID {
        updated.coverAttachmentID = nil
      }
    case .fillMissing:
      updated =
        SiteImageWorkbenchService().fillMissingMetadata(
          draft: current, includedAttachmentIDs: [attachmentID]
        ).draft
    }
    if updated.bodyMarkdown != buffer.bodyMarkdown {
      guard
        stageDraftBody(
          updated.bodyMarkdown, for: draftID, baseRevision: buffer.revision,
          replacingBaseBody: buffer.bodyMarkdown
        )?.wasAccepted == true
      else { return false }
    }
    return updateDraftFromEditor(updated)
  }
}
