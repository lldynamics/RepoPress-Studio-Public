import Combine
import Foundation
import PublishingWorkbenchCore

struct RepositoryHTMLSourceOpenRequest: Equatable, Identifiable {
  let id = UUID()
  let repositoryPath: String
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

@MainActor
final class RepositoryHTMLSourceSession: ObservableObject {
  @Published private(set) var files: [RepositoryHTMLFileDescriptor] = []
  @Published var activeDocument: RepositoryTextDocument?
  @Published private(set) var diagnostics: [HTMLSourceDiagnostic] = []
  @Published private(set) var isLoading = false
  @Published private(set) var isOpeningDocument = false
  @Published private(set) var isSaving = false
  @Published private(set) var editorResetGeneration = 0
  @Published private(set) var statusMessage: String?
  @Published private(set) var errorMessage: String?
  @Published private(set) var hasExternalConflict = false

  private var diagnosticTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private var documentOperationGeneration = 0
  private var documentRevision = 0
  private var diagnosticGeneration = 0
  private var loadingOperationCount = 0

  var hasUnsavedChanges: Bool {
    activeDocument?.hasUnsavedChanges == true
  }

  func isDocumentFromCurrentRepository(_ profile: SiteProfile) -> Bool {
    guard let activeDocument else { return true }
    let currentRoot = profile.resolvedLocalRepositoryRootURL?
      .resolvingSymlinksInPath().standardizedFileURL.path
    return currentRoot == activeDocument.repositoryRootPath
  }

  func refreshFiles(profile: SiteProfile) async {
    refreshGeneration += 1
    let generation = refreshGeneration
    beginLoading()
    defer { endLoading() }
    errorMessage = nil
    do {
      let updated = try await Task.detached(priority: .userInitiated) {
        try HTMLSourceEditingService().listDocuments(profile: profile)
      }.value
      guard generation == refreshGeneration else { return }
      files = updated
      statusMessage = updated.isEmpty
        ? String(localized: "仓库中没有 HTML 或 HTM 文件。")
        : String(localized: "已找到 \(updated.count) 个 HTML 源文件。")
    } catch {
      guard generation == refreshGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  func open(path: String, profile: SiteProfile) async {
    guard !isSaving else { return }
    documentOperationGeneration += 1
    let generation = documentOperationGeneration
    let startingDocumentID = activeDocument?.id
    let startingRevision = documentRevision
    beginLoading()
    isOpeningDocument = true
    defer {
      endLoading()
      if generation == documentOperationGeneration {
        isOpeningDocument = false
      }
    }
    errorMessage = nil
    hasExternalConflict = false
    do {
      let document = try await Task.detached(priority: .userInitiated) {
        try HTMLSourceEditingService().open(profile: profile, repositoryPath: path)
      }.value
      guard generation == documentOperationGeneration else { return }
      guard documentRevision == startingRevision,
            activeDocument?.id == startingDocumentID else {
        errorMessage = String(localized: "载入期间源码发生了新的编辑；为避免丢失内容，本次打开已取消。")
        return
      }
      activeDocument = document
      documentRevision += 1
      editorResetGeneration += 1
      diagnostics = await Task.detached(priority: .utility) {
        HTMLSourceDiagnosticService.diagnostics(in: document.text)
      }.value
      statusMessage = String(localized: "已打开 \(path)")
    } catch {
      guard generation == documentOperationGeneration else { return }
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func save(profile: SiteProfile) async -> Bool {
    guard !isSaving, let document, document.hasUnsavedChanges else { return false }
    let revision = documentRevision
    isSaving = true
    errorMessage = nil
    hasExternalConflict = false
    defer { isSaving = false }
    do {
      let saved = try await Task.detached(priority: .userInitiated) {
        try HTMLSourceEditingService().save(document, profile: profile)
      }.value
      guard let currentDocument = activeDocument,
            currentDocument.id == document.id else { return false }
      var resolvedDocument = saved
      if documentRevision != revision || currentDocument.text != document.text {
        resolvedDocument.text = currentDocument.text
      }
      let diagnosticText = resolvedDocument.text
      let resolvedDiagnostics = await Task.detached(priority: .utility) {
        HTMLSourceDiagnosticService.diagnostics(in: diagnosticText)
      }.value
      activeDocument = resolvedDocument
      documentRevision += 1
      diagnostics = resolvedDiagnostics
      statusMessage = String(localized: "已保存 \(saved.repositoryPath)")
      return true
    } catch {
      hasExternalConflict = (error as? HTMLSourceEditingError) == .externalModification
      errorMessage = error.localizedDescription
      return false
    }
  }

  func reload(profile: SiteProfile) async {
    guard let path = activeDocument?.repositoryPath else { return }
    await open(path: path, profile: profile)
  }

  func updateText(_ text: String) {
    guard !isOpeningDocument, activeDocument?.text != text else { return }
    activeDocument?.text = text
    documentRevision += 1
    scheduleDiagnostics(for: text)
  }

  func close() {
    guard !isSaving else { return }
    documentOperationGeneration += 1
    isOpeningDocument = false
    diagnosticTask?.cancel()
    diagnosticGeneration += 1
    activeDocument = nil
    documentRevision += 1
    diagnostics = []
    errorMessage = nil
    hasExternalConflict = false
    statusMessage = nil
  }

  func dismissError() {
    errorMessage = nil
  }

  @Published private(set) var openRequest: RepositoryHTMLSourceOpenRequest?

  func requestOpen(repositoryPath: String) {
    openRequest = RepositoryHTMLSourceOpenRequest(repositoryPath: repositoryPath)
  }

  func consumeOpenRequest(id: UUID) {
    guard openRequest?.id == id else { return }
    openRequest = nil
  }

  func saveSynchronously(profile: SiteProfile) -> Bool {
    guard !isSaving else {
      errorMessage = String(localized: "HTML 源文件仍在保存，请稍后再试。")
      return false
    }
    guard let document, document.hasUnsavedChanges else { return true }
    do {
      let saved = try HTMLSourceEditingService().save(document, profile: profile)
      activeDocument = saved
      documentRevision += 1
      diagnostics = HTMLSourceDiagnosticService.diagnostics(in: saved.text)
      statusMessage = String(localized: "已保存 \(saved.repositoryPath)")
      errorMessage = nil
      hasExternalConflict = false
      return true
    } catch {
      hasExternalConflict = (error as? HTMLSourceEditingError) == .externalModification
      errorMessage = error.localizedDescription
      return false
    }
  }

  private var document: RepositoryTextDocument? {
    activeDocument
  }

  private func scheduleDiagnostics(for text: String) {
    diagnosticTask?.cancel()
    diagnosticGeneration += 1
    let generation = diagnosticGeneration
    diagnosticTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      let result = await Task.detached(priority: .utility) {
        HTMLSourceDiagnosticService.diagnostics(in: text)
      }.value
      guard !Task.isCancelled, self?.diagnosticGeneration == generation else { return }
      self?.diagnostics = result
    }
  }

  private func beginLoading() {
    loadingOperationCount += 1
    isLoading = true
  }

  private func endLoading() {
    loadingOperationCount = max(0, loadingOperationCount - 1)
    isLoading = loadingOperationCount > 0
  }
}

@MainActor
final class RepositoryHTMLSourceSessionRegistry {
  static let shared = RepositoryHTMLSourceSessionRegistry()

  private var entries: [ObjectIdentifier: Entry] = [:]

  private init() {}

  var hasUnsavedChanges: Bool {
    pruneReleasedSessions()
    return entries.values.contains { $0.session?.hasUnsavedChanges == true }
  }

  var lastErrorMessage: String? {
    pruneReleasedSessions()
    return entries.values.compactMap { $0.session?.errorMessage }.first
  }

  func register(
    session: RepositoryHTMLSourceSession,
    profileProvider: @escaping () -> SiteProfile
  ) {
    entries[ObjectIdentifier(session)] = Entry(
      session: session,
      profileProvider: profileProvider
    )
  }

  func saveBeforeTermination() -> Bool {
    pruneReleasedSessions()
    for entry in entries.values {
      guard let session = entry.session else { continue }
      if !session.saveSynchronously(profile: entry.profileProvider()) {
        return false
      }
    }
    return true
  }

  private func pruneReleasedSessions() {
    entries = entries.filter { $0.value.session != nil }
  }

  private final class Entry {
    weak var session: RepositoryHTMLSourceSession?
    let profileProvider: () -> SiteProfile

    init(
      session: RepositoryHTMLSourceSession,
      profileProvider: @escaping () -> SiteProfile
    ) {
      self.session = session
      self.profileProvider = profileProvider
    }
  }
}
