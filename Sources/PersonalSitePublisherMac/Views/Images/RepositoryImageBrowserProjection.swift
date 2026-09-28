import Foundation
import PublishingDomainContracts

enum RepositoryImageSortOrder: String, CaseIterable, Identifiable, Sendable {
  case nameAsc
  case nameDesc
  case dateNewest
  case dateOldest
  case sizeLargest
  case sizeSmallest
  case unregisteredFirst
  case registeredFirst

  var id: String { rawValue }

  var title: String {
    switch self {
    case .nameAsc: String(localized: "名称 (A → Z)")
    case .nameDesc: String(localized: "名称 (Z → A)")
    case .dateNewest: String(localized: "修改日期 (最新优先)")
    case .dateOldest: String(localized: "修改日期 (最早优先)")
    case .sizeLargest: String(localized: "文件大小 (从大到小)")
    case .sizeSmallest: String(localized: "文件大小 (从小到大)")
    case .unregisteredFirst: String(localized: "引用状态 (未登记优先)")
    case .registeredFirst: String(localized: "引用状态 (已登记优先)")
    }
  }

  var shortTitle: String {
    switch self {
    case .nameAsc, .nameDesc: String(localized: "按名称")
    case .dateNewest, .dateOldest: String(localized: "按修改时间")
    case .sizeLargest, .sizeSmallest: String(localized: "按文件大小")
    case .unregisteredFirst, .registeredFirst: String(localized: "按引用状态")
    }
  }
}

enum RepositoryImageFilter: String, CaseIterable, Identifiable, Sendable {
  case all
  case registered
  case unregistered

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "全部")
    case .registered: String(localized: "已登记")
    case .unregistered: String(localized: "未登记")
    }
  }

  func includes(_ asset: RepositoryImageAsset) -> Bool {
    switch self {
    case .all: true
    case .registered: asset.isRegisteredToArticle
    case .unregistered: !asset.isRegisteredToArticle
    }
  }
}

enum RepositoryImageBrowserPresentationState: Equatable {
  case preparing
  case inventoryEmpty
  case filteredEmpty
  case results

  static func resolve(
    isLoading: Bool,
    inventoryCount: Int,
    projectedCount: Int
  ) -> Self {
    if isLoading { return .preparing }
    if projectedCount > 0 { return .results }
    return inventoryCount == 0 ? .inventoryEmpty : .filteredEmpty
  }
}

enum RepositoryImageBrowserProjection {
  static func project(
    _ assets: [RepositoryImageAsset], scope: RepositoryImageBrowserScope,
    includesSubfolders: Bool, query: String, filter: RepositoryImageFilter,
    sortOrder: RepositoryImageSortOrder, now: Date = Date()
  ) -> [RepositoryImageAsset] {
    let scoped = assets.filter { asset in
      switch scope {
      case .all: return true
      case .recent:
        guard let modifiedAt = asset.modifiedAt else { return false }
        return modifiedAt >= now.addingTimeInterval(-30 * 24 * 60 * 60)
      case .folder(let path):
        if includesSubfolders { return asset.repositoryPath.hasPrefix(path + "/") }
        return (asset.repositoryPath as NSString).deletingLastPathComponent == path
      }
    }
    return project(
      scoped, query: query, filter: filter,
      sortOrder: scope == .recent ? .dateNewest : sortOrder
    )
  }

  nonisolated static func project(
    _ assets: [RepositoryImageAsset],
    query: String,
    filter: RepositoryImageFilter,
    sortOrder: RepositoryImageSortOrder
  ) -> [RepositoryImageAsset] {
    let base = assets.filter { asset in
      filter.includes(asset)
        && (query.isEmpty || asset.filename.localizedStandardContains(query)
          || asset.repositoryPath.localizedStandardContains(query))
    }
    return base.sorted { lhs, rhs in
      switch sortOrder {
      case .nameAsc: return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
      case .nameDesc:
        return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedDescending
      case .dateNewest:
        let l = lhs.modifiedAt ?? .distantPast
        let r = rhs.modifiedAt ?? .distantPast
        return l == r
          ? lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending : l > r
      case .dateOldest:
        let l = lhs.modifiedAt ?? .distantPast
        let r = rhs.modifiedAt ?? .distantPast
        return l == r
          ? lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending : l < r
      case .sizeLargest:
        return lhs.byteSize == rhs.byteSize
          ? lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
          : lhs.byteSize > rhs.byteSize
      case .sizeSmallest:
        return lhs.byteSize == rhs.byteSize
          ? lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
          : lhs.byteSize < rhs.byteSize
      case .unregisteredFirst:
        return lhs.isRegisteredToArticle == rhs.isRegisteredToArticle
          ? lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
          : !lhs.isRegisteredToArticle
      case .registeredFirst:
        return lhs.isRegisteredToArticle == rhs.isRegisteredToArticle
          ? lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
          : lhs.isRegisteredToArticle
      }
    }
  }

}
