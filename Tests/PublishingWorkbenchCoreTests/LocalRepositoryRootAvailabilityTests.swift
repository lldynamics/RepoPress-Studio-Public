import Foundation
import Testing

@testable import PublishingWorkbenchCore

struct LocalRepositoryRootAvailabilityTests {
  @Test
  func reportsMissingSelectedDirectoryBeforeGitCheck() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repository-root-missing-\(UUID().uuidString)", isDirectory: true)
    let profile = publishingProfile(rootURL: rootURL)

    #expect(throws: LocalPublishPreviewError.repositoryDirectoryMissing(rootURL.path)) {
      try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: rootURL)
    }
  }

  @Test
  func reportsSelectedRegularFileAsMissingDirectory() throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repository-root-file-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try Data("not a directory".utf8).write(to: rootURL)
    let profile = publishingProfile(rootURL: rootURL)

    #expect(throws: LocalPublishPreviewError.repositoryDirectoryMissing(rootURL.path)) {
      try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: rootURL)
    }
  }

  @Test
  func reportsUnavailableExternalVolumeBeforeGitCheck() throws {
    let volumeName = "RepoPress-unavailable-\(UUID().uuidString)"
    let rootURL = URL(
      fileURLWithPath: "/Volumes/\(volumeName)/site",
      isDirectory: true
    )
    #expect(!FileManager.default.fileExists(atPath: "/Volumes/\(volumeName)"))
    let profile = publishingProfile(rootURL: rootURL)

    #expect(throws: LocalPublishPreviewError.repositoryVolumeUnavailable(rootURL.path)) {
      try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: rootURL)
    }
  }

  @Test
  func reportsNonGitDirectoryAfterAvailabilityChecks() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let profile = publishingProfile(rootURL: rootURL)

    #expect(throws: LocalPublishPreviewError.notGitRepositoryRoot(rootURL.path)) {
      try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: rootURL)
    }
  }

  @Test
  func acceptsGitDirectoryAndWorktreeGitFile() throws {
    let directoryRepositoryURL = try makeTemporaryDirectory()
    let worktreeRepositoryURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directoryRepositoryURL)
      try? FileManager.default.removeItem(at: worktreeRepositoryURL)
    }
    let service = LocalPublishPreviewService()

    try FileManager.default.createDirectory(
      at: directoryRepositoryURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "gitdir: /private/tmp/worktree-admin".write(
      to: worktreeRepositoryURL.appendingPathComponent(".git"),
      atomically: true,
      encoding: .utf8
    )

    try service.validateRepositoryRoot(
      profile: publishingProfile(rootURL: directoryRepositoryURL),
      rootURL: directoryRepositoryURL
    )
    try service.validateRepositoryRoot(
      profile: publishingProfile(rootURL: worktreeRepositoryURL),
      rootURL: worktreeRepositoryURL
    )
  }

  @Test
  func rejectsGitMarkerSymlink() throws {
    let rootURL = try makeTemporaryDirectory()
    let targetURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: targetURL)
    }
    try FileManager.default.createDirectory(
      at: targetURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: rootURL.appendingPathComponent(".git"),
      withDestinationURL: targetURL.appendingPathComponent(".git", isDirectory: true)
    )
    let profile = publishingProfile(rootURL: rootURL)

    #expect(throws: LocalPublishPreviewError.notGitRepositoryRoot(rootURL.path)) {
      try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: rootURL)
    }
  }

  @Test
  func reportsReadOnlyDirectoryAsAccessDenied() throws {
    let rootURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
      try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rootURL.path)
    let profile = publishingProfile(rootURL: rootURL)

    #expect(throws: LocalPublishPreviewError.repositoryAccessDenied(rootURL.path)) {
      try LocalPublishPreviewService().validateRepositoryRoot(profile: profile, rootURL: rootURL)
    }
  }

  @Test
  func trustedBindingReportsMissingDirectoryInsteadOfExternalConflict() throws {
    let rootURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent(".git", isDirectory: true),
      withIntermediateDirectories: true
    )
    let profile = publishingProfile(rootURL: rootURL)
    var draft = ArticleDraft.empty(profile: profile)
    draft.slug = "trusted-binding"
    draft.bodyMarkdown = "Saved document"
    let store = SiteDraftFileStore()

    let firstWrite = try store.write(draft: draft, profile: profile)
    let documentURL = rootURL.appendingPathComponent(firstWrite.repositoryPath)
    let document = try String(contentsOf: documentURL, encoding: .utf8)
    draft.recordProjectFile(
      profile: profile,
      repositoryPath: firstWrite.repositoryPath,
      renderedContentDigest: ArticleDraft.repositoryDocumentDigest(document)
    )
    draft.bodyMarkdown = "Pending edit"
    try FileManager.default.removeItem(at: rootURL)

    #expect(throws: LocalPublishPreviewError.repositoryDirectoryMissing(rootURL.path)) {
      try store.write(draft: draft, profile: profile)
    }
  }

  private func publishingProfile(rootURL: URL) -> SiteProfile {
    SiteProfile(name: "Test", localRepositoryRootPath: rootURL.path)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("repository-root-availability-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
  }
}
