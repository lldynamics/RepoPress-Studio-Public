import Foundation
import PublishingDomainContracts

/// The collection shown by the image browser. Folder paths are repository
/// relative and remain stable when the inventory is refreshed.
public enum RepositoryImageBrowserScope: Hashable, Sendable {
  case all
  case recent
  case folder(String)
}

public struct RepositoryImageFolderNode: Identifiable, Hashable, Sendable {
  public let id: String
  public let repositoryPath: String
  public let name: String
  public let directImageCount: Int
  public let recursiveImageCount: Int
  public let children: [RepositoryImageFolderNode]

  public var imageCount: Int { recursiveImageCount }
  public var isEmpty: Bool { recursiveImageCount == 0 }

  init(
    repositoryPath: String,
    name: String,
    directImageCount: Int,
    recursiveImageCount: Int,
    children: [RepositoryImageFolderNode]
  ) {
    self.id = repositoryPath
    self.repositoryPath = repositoryPath
    self.name = name
    self.directImageCount = directImageCount
    self.recursiveImageCount = recursiveImageCount
    self.children = children
  }
}

/// A pure, deterministic projection of directory metadata and image paths.
public struct RepositoryImageFolderTree: Hashable, Sendable {
  public let root: RepositoryImageFolderNode

  public init(
    assetRootPath: String,
    directoryPaths: [String],
    assets: [RepositoryImageAsset]
  ) {
    let rootPath = Self.normalized(assetRootPath)
    var directories = Set<String>()
    directories.insert(rootPath)

    for path in directoryPaths {
      let normalized = Self.normalized(path)
      guard Self.isContained(normalized, by: rootPath) else { continue }
      directories.formUnion(Self.ancestors(of: normalized, root: rootPath))
    }

    var directCounts: [String: Int] = [:]
    var seenAssets = Set<String>()
    for asset in assets {
      let path = Self.normalized(asset.repositoryPath)
      guard Self.isContained(path, by: rootPath), seenAssets.insert(path).inserted else {
        continue
      }
      let parent = Self.parent(of: path) ?? rootPath
      guard Self.isContained(parent, by: rootPath) else { continue }
      directories.formUnion(Self.ancestors(of: parent, root: rootPath))
      directCounts[parent, default: 0] += 1
    }

    var childrenByParent: [String: [String]] = [:]
    for directory in directories where directory != rootPath {
      guard let parent = Self.parent(of: directory) else { continue }
      childrenByParent[parent, default: []].append(directory)
    }
    for parent in childrenByParent.keys {
      childrenByParent[parent]?.sort(by: Self.pathSort)
    }

    self.root = Self.build(
      path: rootPath,
      rootPath: rootPath,
      childrenByParent: childrenByParent,
      directCounts: directCounts
    )
  }

  public init(
    assetRootPath: String,
    directoryPaths: [String],
    imagePaths: [String]
  ) {
    let assets = imagePaths.map {
      RepositoryImageAsset(
        repositoryPath: $0,
        absoluteFilePath: $0,
        filename: URL(fileURLWithPath: $0).lastPathComponent,
        fileExtension: URL(fileURLWithPath: $0).pathExtension,
        byteSize: 0,
        modifiedAt: nil,
        references: []
      )
    }
    self.init(assetRootPath: assetRootPath, directoryPaths: directoryPaths, assets: assets)
  }

  public var allNodes: [RepositoryImageFolderNode] {
    var result: [RepositoryImageFolderNode] = []
    walk(root, into: &result)
    return result
  }

  public func node(withPath path: String) -> RepositoryImageFolderNode? {
    let wanted = Self.normalized(path)
    return allNodes.first { $0.repositoryPath == wanted }
  }

  /// Returns matching folders and their ancestors. An empty query matches all
  /// folders and keeps the caller's expansion state meaningful.
  public func matchingPaths(query: String) -> Set<String> {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return Set(allNodes.map(\.repositoryPath)) }
    var paths = Set<String>()
    for node in allNodes where node.name.localizedCaseInsensitiveContains(query) {
      paths.insert(node.repositoryPath)
      paths.formUnion(Self.ancestors(of: node.repositoryPath, root: root.repositoryPath))
    }
    paths.insert(root.repositoryPath)
    return paths
  }

  public func expandedPaths(for query: String) -> Set<String> {
    let paths = matchingPaths(query: query)
    return paths
  }

  private func walk(
    _ node: RepositoryImageFolderNode, into result: inout [RepositoryImageFolderNode]
  ) {
    result.append(node)
    for child in node.children { walk(child, into: &result) }
  }

  private static func build(
    path: String,
    rootPath: String,
    childrenByParent: [String: [String]],
    directCounts: [String: Int]
  ) -> RepositoryImageFolderNode {
    let children = (childrenByParent[path] ?? []).map {
      build(
        path: $0,
        rootPath: rootPath,
        childrenByParent: childrenByParent,
        directCounts: directCounts
      )
    }
    return RepositoryImageFolderNode(
      repositoryPath: path,
      name: displayName(path: path, rootPath: rootPath),
      directImageCount: directCounts[path, default: 0],
      recursiveImageCount: directCounts[path, default: 0]
        + children.reduce(0) { $0 + $1.recursiveImageCount },
      children: children
    )
  }

  private static func displayName(path: String, rootPath: String) -> String {
    guard !path.isEmpty else { return String(localized: "图片") }
    return path.split(separator: "/").last.map(String.init) ?? rootPath
  }

  private static func pathSort(_ lhs: String, _ rhs: String) -> Bool {
    let leftName = lhs.split(separator: "/").last.map(String.init) ?? lhs
    let rightName = rhs.split(separator: "/").last.map(String.init) ?? rhs
    let comparison = leftName.localizedStandardCompare(rightName)
    return comparison == .orderedSame ? lhs < rhs : comparison == .orderedAscending
  }

  private static func normalized(_ path: String) -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.contains(where: { $0 == ".." }) else { return "\u{0}" }
    return components.filter { $0 != "." }.joined(separator: "/")
  }

  private static func isContained(_ path: String, by root: String) -> Bool {
    guard !path.contains("\u{0}"), !root.contains("\u{0}") else { return false }
    return root.isEmpty ? !path.isEmpty : path == root || path.hasPrefix(root + "/")
  }

  private static func parent(of path: String) -> String? {
    guard let slash = path.lastIndex(of: "/") else { return nil }
    return String(path[..<slash])
  }

  private static func ancestors(of path: String, root: String) -> [String] {
    guard isContained(path, by: root) else { return [] }
    if path == root { return [root] }
    let suffix = String(path.dropFirst(root.isEmpty ? 0 : root.count + 1))
    var result = [root]
    var current = root
    for segment in suffix.split(separator: "/") {
      current = current.isEmpty ? String(segment) : current + "/" + segment
      result.append(current)
    }
    return result
  }
}
