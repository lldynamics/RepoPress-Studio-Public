import Combine
import Foundation
import PublishingDomainContracts

enum RepositoryImageDisplayMode: String, CaseIterable {
  case grid, list
}

struct RepositoryImageInventorySource: Equatable {
  let profileID: UUID
  let repositoryPath: String
  let assetRoot: String

}

/// Owned by a window, observed only by image feature leaves.
@MainActor
final class RepositoryImageBrowserSession: ObservableObject {
  @Published var inventory: RepositoryImageInventory?
  @Published var isLoading = false
  @Published var errorMessage: String?
  @Published var scope: RepositoryImageBrowserScope = .all
  @Published var expandedPaths: Set<String> = []
  @Published var selectedPaths: Set<String> = []
  @Published var targetDraftID: UUID?
  @Published var query = ""
  @Published var filter: RepositoryImageFilter = .all
  @Published var sortOrder: RepositoryImageSortOrder = .nameAsc
  @Published var includesSubfolders = true
  @Published var displayMode: RepositoryImageDisplayMode = .grid
  @Published var thumbnailSize: Double = 210
  @Published var visibleAssets: [RepositoryImageAsset] = []
  @Published var isProjecting = false
  @Published var resourceMode: ImageWorkbenchResourceMode = .repository
  @Published var refreshRequestID = UUID()
  @Published var previewURL: URL?
  @Published var scrollAnchor: String?
  private(set) var source: RepositoryImageInventorySource?
  private var selectionAnchor: String?
  private var focusedPath: String?
  private var projectionID = UUID()

  var selectedAsset: RepositoryImageAsset? {
    guard selectedPaths.count == 1, let path = selectedPaths.first else { return nil }
    return inventory?.assets.first { $0.repositoryPath == path }
  }

  var selectedAssets: [RepositoryImageAsset] {
    visibleAssets.filter { selectedPaths.contains($0.repositoryPath) }
  }

  var title: String {
    switch scope {
    case .all: String(localized: "全部图片")
    case .recent: String(localized: "最近修改")
    case .folder(let path): (path as NSString).lastPathComponent
    }
  }

  func prepare(for source: RepositoryImageInventorySource, preferredDraftID: UUID?) {
    guard self.source != source else { return }
    self.source = source
    inventory = nil
    visibleAssets = []
    selectedPaths = []
    expandedPaths = []
    selectionAnchor = nil
    focusedPath = nil
    scrollAnchor = nil
    scope = .all
    query = ""
    errorMessage = nil
    targetDraftID = preferredDraftID
    previewURL = nil
  }

  func matches(source: RepositoryImageInventorySource) -> Bool {
    self.source == source && inventory?.profileID == source.profileID
  }

  func apply(_ newInventory: RepositoryImageInventory) {
    inventory = newInventory
    errorMessage = nil
    expandedPaths.insert(newInventory.assetRootPath)
    let available = Set(newInventory.assets.map(\.repositoryPath))
    selectedPaths.formIntersection(available)
    if case .folder(let path) = scope,
      !newInventory.directoryPaths.contains(path),
      !newInventory.assets.contains(where: { $0.repositoryPath.hasPrefix(path + "/") }),
      !newInventory.wasTruncated
    {
      scope = .all
    }
  }

  func rebuildProjection() async {
    guard let inventory else {
      visibleAssets = []
      return
    }
    let revision = inventory.revisionID
    let scope = scope
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filter = filter
    let sorting = sortOrder
    let recursive = includesSubfolders
    let taskID = UUID()
    projectionID = taskID
    isProjecting = true
    defer { if projectionID == taskID { isProjecting = false } }
    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
    let assets = inventory.assets
    let projected = await Task.detached(priority: .userInitiated) {
      RepositoryImageBrowserProjection.project(
        assets, scope: scope, includesSubfolders: recursive,
        query: query, filter: filter, sortOrder: sorting
      )
    }.value
    guard !Task.isCancelled, self.inventory?.revisionID == revision, projectionID == taskID else {
      return
    }
    visibleAssets = projected
    selectedPaths.formIntersection(Set(projected.map(\.repositoryPath)))
    if selectedPaths.isEmpty, let first = projected.first {
      selectedPaths.insert(first.repositoryPath)
      selectionAnchor = first.repositoryPath
      focusedPath = first.repositoryPath
    }
  }

  func select(_ path: String, extending: Bool = false, toggling: Bool = false) {
    guard visibleAssets.contains(where: { $0.repositoryPath == path }) else { return }
    focusedPath = path
    if extending, let anchor = selectionAnchor,
      let start = visibleAssets.firstIndex(where: { $0.repositoryPath == anchor }),
      let end = visibleAssets.firstIndex(where: { $0.repositoryPath == path })
    {
      selectedPaths = Set(visibleAssets[min(start, end)...max(start, end)].map(\.repositoryPath))
    } else if toggling {
      if !selectedPaths.insert(path).inserted { selectedPaths.remove(path) }
      selectionAnchor = path
    } else {
      selectedPaths = [path]
      selectionAnchor = path
    }
  }

  func moveSelection(by offset: Int, extending: Bool) {
    guard !visibleAssets.isEmpty else { return }
    let active =
      focusedPath.flatMap { selectedPaths.contains($0) ? $0 : nil }
      ?? visibleAssets.first(where: { selectedPaths.contains($0.repositoryPath) })?.repositoryPath
    let current = visibleAssets.firstIndex { $0.repositoryPath == active } ?? 0
    let next = max(0, min(visibleAssets.count - 1, current + offset))
    let path = visibleAssets[next].repositoryPath
    select(path, extending: extending)
    if !extending { selectionAnchor = path }
    scrollAnchor = path
  }

  func previewSelection() {
    previewURL = selectedAsset?.fileURL
  }
}
