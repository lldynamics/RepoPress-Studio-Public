import Combine
import Foundation
import PublishingWorkbenchCore

struct RepositoryHTMLSourceRepositoryIdentity: Hashable {
  let profileID: UUID
  let repositoryRootPath: String

  init(profile: SiteProfile) {
    profileID = profile.id
    repositoryRootPath = profile.localRepositoryRootPath
  }
}

struct RepositoryHTMLSourceOpenRequest: Equatable, Identifiable {
  let id = UUID()
  let repositoryPath: String
  let repositoryIdentity: RepositoryHTMLSourceRepositoryIdentity
}

enum RepositoryHTMLSourceFileFilter {
  static func filtered(
    _ files: [RepositoryHTMLFileDescriptor],
    query: String
  ) -> [RepositoryHTMLFileDescriptor] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return files }
    return files.filter {
      $0.repositoryPath.localizedCaseInsensitiveContains(normalizedQuery)
    }
  }
}

/// Read-only state for browsing HTML files in the active repository.
@MainActor
final class RepositoryHTMLSourceSession: ObservableObject {
  @Published private(set) var files: [RepositoryHTMLFileDescriptor] = []
  @Published private(set) var isLoading = false
  @Published private(set) var statusMessage: String?
  @Published private(set) var errorMessage: String?
  @Published private(set) var openRequest: RepositoryHTMLSourceOpenRequest?

  private var refreshGeneration = 0
  private(set) var repositoryIdentity: RepositoryHTMLSourceRepositoryIdentity?

  func refreshFiles(profile: SiteProfile) async {
    let identity = RepositoryHTMLSourceRepositoryIdentity(profile: profile)
    if repositoryIdentity != identity {
      repositoryIdentity = identity
      files = []
      statusMessage = nil
      if openRequest?.repositoryIdentity != identity {
        openRequest = nil
      }
    }
    refreshGeneration += 1
    let generation = refreshGeneration
    isLoading = true
    errorMessage = nil
    defer {
      if generation == refreshGeneration { isLoading = false }
    }
    do {
      let updated = try await Task.detached(priority: .userInitiated) {
        try RepositoryHTMLFileService().listDocuments(profile: profile)
      }.value
      guard generation == refreshGeneration else { return }
      files = updated
      statusMessage =
        updated.isEmpty
        ? String(localized: "仓库中没有 HTML 或 HTM 文件。")
        : String(localized: "已找到 \(updated.count) 个 HTML 源文件。")
    } catch {
      guard generation == refreshGeneration else { return }
      files = []
      statusMessage = nil
      errorMessage = error.localizedDescription
    }
  }

  func requestOpen(repositoryPath: String, profile: SiteProfile) {
    openRequest = RepositoryHTMLSourceOpenRequest(
      repositoryPath: repositoryPath,
      repositoryIdentity: RepositoryHTMLSourceRepositoryIdentity(profile: profile)
    )
  }

  func includeValidatedFile(_ file: RepositoryHTMLFileDescriptor, profile: SiteProfile) {
    guard repositoryIdentity == RepositoryHTMLSourceRepositoryIdentity(profile: profile) else {
      return
    }
    guard !files.contains(where: { $0.repositoryPath == file.repositoryPath }) else { return }
    files.append(file)
    files.sort {
      $0.repositoryPath.localizedStandardCompare($1.repositoryPath) == .orderedAscending
    }
    statusMessage = String(localized: "已找到 \(files.count) 个 HTML 源文件。")
  }

  func consumeOpenRequest(id: UUID) {
    guard openRequest?.id == id else { return }
    openRequest = nil
  }

  func reportError(_ error: Error) {
    errorMessage = error.localizedDescription
  }

  func dismissError() {
    errorMessage = nil
  }
}
