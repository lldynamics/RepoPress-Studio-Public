import Foundation

public enum ReleaseRecordDraftResolver {
  /// Returns the first matching record from a newest-first release history.
  public static func latestRecord(
    for draft: ArticleDraft,
    in records: [ReleaseRecord]
  ) -> ReleaseRecord? {
    if let exactRecord = records.first(where: { record in
      record.draftID == draft.id
        || record.batchItems.contains { $0.draftID == draft.id }
    }) {
      return exactRecord
    }

    return records.first { record in
      record.draftID == nil
        && record.batchItems.isEmpty
        && record.siteProfileID == draft.siteProfileID
        && record.draftTitle == draft.title
    }
  }
}
