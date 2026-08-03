import Foundation

@testable import PublishingWorkbenchCore

struct WorkbenchMigrationAttachmentFixtureURLs {
  var managed: URL
  var optimized: URL
  var external: URL
  var unknownRoot: URL
}

extension WorkbenchDataRootMigrationTests {
  func createWorkbenchCompanionFixture(
    in layout: WorkbenchDataRootLayout
  ) throws {
    let persistence = WorkbenchPersistence(fileURL: layout.workbenchFileURL)
    let urls = try createAttachmentFixtureFiles(in: layout, persistence: persistence)
    let snapshot = makeWorkbenchSnapshot(
      title: "Legacy workbench",
      managedAttachmentURL: urls.managed,
      optimizedAttachmentURL: urls.optimized,
      externalAttachmentURL: urls.external,
      unknownRootAttachmentURL: urls.unknownRoot
    )
    let migratedSnapshot = try persistLegacySnapshots(snapshot, with: persistence)
    try createDraftRecoveryFixture(
      draft: requiredDraft(from: migratedSnapshot),
      persistence: persistence
    )
    try createRecoveryArchiveFixtures(with: persistence)
  }

  func createAttachmentFixtureFiles(
    in layout: WorkbenchDataRootLayout,
    persistence: WorkbenchPersistence
  ) throws -> WorkbenchMigrationAttachmentFixtureURLs {
    let urls = WorkbenchMigrationAttachmentFixtureURLs(
      managed: layout.managedAttachmentsURL
        .appendingPathComponent("article-id/managed.png"),
      optimized: persistence.imageOptimizationDirectoryURL
        .appendingPathComponent(".image-batch-preserved/optimized.jpg"),
      external: layout.rootURL.deletingLastPathComponent()
        .appendingPathComponent("external-user-file.png"),
      unknownRoot: layout.rootURL
        .appendingPathComponent("LegacyExports/user-selected.png")
    )
    try writeFixtureData(Data([0, 1, 2, 3]), to: urls.managed)
    try writeFixtureData(Data([9, 8, 7, 6]), to: urls.optimized)
    try writeFixtureData(Data([5, 4, 3, 2]), to: urls.external)
    try writeFixtureData(Data([6, 7, 8, 9]), to: urls.unknownRoot)
    return urls
  }

  func writeFixtureData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url)
  }

  func persistLegacySnapshots(
    _ snapshot: WorkbenchSnapshot,
    with persistence: WorkbenchPersistence
  ) throws -> WorkbenchSnapshot {
    _ = try persistence.save(snapshot)
    var legacyObject = try requireJSONObject(
      from: JSONEncoder.workbench.encode(snapshot)
    )
    legacyObject["formatVersion"] = 5
    legacyObject["scheduledPublishJobs"] = [[
      "id": "11111111-1111-1111-1111-111111111111",
      "draftTitle": "Retired scheduled draft",
      "status": "scheduled"
    ]]
    try JSONSerialization.data(withJSONObject: legacyObject).write(
      to: persistence.fileURL,
      options: .atomic
    )
    guard let migratedSnapshot = try persistence.load() else {
      throw FixtureError.missingWorkbenchSnapshot
    }
    _ = try persistence.save(migratedSnapshot)
    return migratedSnapshot
  }

  func createDraftRecoveryFixture(
    draft: ArticleDraft,
    persistence: WorkbenchPersistence
  ) throws {
    let journal = DraftRecoveryJournal(fileURL: persistence.draftRecoveryJournalURL)
    try Data("malformed journal".utf8).write(to: journal.fileURL, options: .atomic)
    guard try journal.quarantineUnreadableFile() != nil else {
      throw FixtureError.missingQuarantine
    }
    try journal.save([
      DraftRecoveryRecord(
        draft: draft,
        recoveredBodyMarkdown: "Recovered unsaved body",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
      )
    ])
  }

  func createRecoveryArchiveFixtures(
    with persistence: WorkbenchPersistence
  ) throws {
    _ = try persistence.archiveUnrecoverableSnapshotFiles()
    let corruptArchiveURL = persistence.recoveryArchiveDirectoryURL
      .appendingPathComponent("CorruptFixture/workbench.json")
    try writeFixtureData(
      Data("corrupt recovery snapshot".utf8),
      to: corruptArchiveURL
    )
  }

  func makeWorkbenchSnapshot(
    title: String,
    managedAttachmentURL: URL? = nil,
    optimizedAttachmentURL: URL? = nil,
    externalAttachmentURL: URL? = nil,
    unknownRootAttachmentURL: URL? = nil
  ) -> WorkbenchSnapshot {
    let profile = SiteProfile.defaultProfile
    let draft = makeActiveFixtureDraft(
      profile: profile,
      title: title,
      managedAttachmentURL: managedAttachmentURL,
      externalAttachmentURL: externalAttachmentURL,
      unknownRootAttachmentURL: unknownRootAttachmentURL
    )
    return WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      draftVersions: makeFixtureDraftVersions(
        draft: draft,
        optimizedAttachmentURL: optimizedAttachmentURL
      ),
      recycledDrafts: makeFixtureRecycledDrafts(
        profile: profile,
        optimizedAttachmentURL: optimizedAttachmentURL
      ),
      releaseRecords: []
    )
  }

  func makeActiveFixtureDraft(
    profile: SiteProfile,
    title: String,
    managedAttachmentURL: URL?,
    externalAttachmentURL: URL?,
    unknownRootAttachmentURL: URL?
  ) -> ArticleDraft {
    var draft = ArticleDraft.empty(profile: profile)
    draft.title = title
    draft.bodyMarkdown = "Legacy body"
    let candidates = [
      ("managed-active.png", managedAttachmentURL),
      ("external-active.png", externalAttachmentURL),
      ("unknown-root-active.png", unknownRootAttachmentURL)
    ]
    draft.attachments = candidates.compactMap { filename, sourceURL in
      sourceURL.map { fixtureAttachment(filename: filename, sourceURL: $0) }
    }
    return draft
  }

  func makeFixtureDraftVersions(
    draft: ArticleDraft,
    optimizedAttachmentURL: URL?
  ) -> [DraftVersionSnapshot] {
    guard !draft.attachments.isEmpty else { return [] }
    var versionDraft = draft
    if let optimizedAttachmentURL {
      versionDraft.attachments.append(
        fixtureAttachment(
          filename: "optimized-version.jpg",
          sourceURL: optimizedAttachmentURL
        )
      )
    }
    return [
      DraftVersionSnapshot(
        draft: versionDraft,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_050),
        reason: .manual
      )
    ]
  }

  func makeFixtureRecycledDrafts(
    profile: SiteProfile,
    optimizedAttachmentURL: URL?
  ) -> [RecycledDraft] {
    guard let optimizedAttachmentURL else { return [] }
    var draft = ArticleDraft.empty(profile: profile)
    draft.title = "Recycled legacy workbench"
    draft.attachments = [
      fixtureAttachment(
        filename: "optimized-recycled.jpg",
        sourceURL: optimizedAttachmentURL
      )
    ]
    return [
      RecycledDraft(
        draft: draft,
        deletedAt: Date(timeIntervalSince1970: 1_700_000_060)
      )
    ]
  }

  func fixtureAttachment(filename: String, sourceURL: URL) -> DraftAttachment {
    DraftAttachment(
      originalFilename: filename,
      relativePublishPath: "images/\(filename)",
      repositoryPath: "static/images/\(filename)",
      byteSize: 4,
      sourceFilePath: sourceURL.path
    )
  }

  func requireJSONObject(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FixtureError.invalidWorkbenchJSON
    }
    return object
  }

  func requiredDraft(from snapshot: WorkbenchSnapshot) throws -> ArticleDraft {
    guard let draft = snapshot.drafts.first else {
      throw FixtureError.missingDraft
    }
    return draft
  }
}
