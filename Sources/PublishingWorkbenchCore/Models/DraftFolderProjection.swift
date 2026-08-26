import Foundation

/// A folder-shaped view of the drafts in a writing list.
///
/// Nodes intentionally contain draft IDs rather than `ArticleDraft` values.
/// The writing view can resolve those IDs through its existing store/cache,
/// while a protected node never carries a path-bearing value that could be
/// rendered accidentally.  A general draft is placed in the unfiled virtual
/// node because it has no publishing directory of its own.
public enum DraftFolderNodeKind: String, Hashable, Sendable {
  case directory
  case root
  case protectedContent
  case unfiled
}

/// Exact cache identity of a draft's projected folder assignment. Raw source
/// paths are intentionally hidden: two path states that resolve to the same
/// safe folder share this key, while unsafe/private transitions remain visible.
public enum DraftFolderAssignmentCacheKey: Hashable, Sendable {
  case protectedContent
  case unfiled
  case folder(canonicalDirectory: String, visibleDirectory: String)
}

public struct DraftFolderNode: Identifiable, Hashable, Sendable {
  public typealias Kind = DraftFolderNodeKind

  public let id: String
  public let kind: DraftFolderNodeKind
  public let name: String
  /// The path shown in the public tree, after stripping the profile's
  /// content root.  Virtual nodes deliberately do not expose a path.
  public let visiblePath: String?
  /// The visible directory path used by the tree.  It is relative to the
  /// profile content root for ordinary directories and nil for virtual nodes.
  public var directoryPath: String? { visiblePath }
  /// The complete repository directory used to derive this node's stable ID.
  /// Virtual nodes have no repository directory.
  public let canonicalDirectory: String?
  public let draftIDs: [UUID]
  public let children: [DraftFolderNode]

  /// IDs are used instead of embedding path-bearing drafts in the node.  The
  /// existing writing-store cache resolves these IDs to row presentations.
  public var drafts: [UUID] { draftIDs }

  public var displayName: String { name }

  public var isVirtual: Bool {
    kind == .protectedContent || kind == .unfiled
  }

  /// Number of drafts directly in this node and all of its descendants.
  public var totalDescendantDraftCount: Int {
    draftIDs.count + children.reduce(0) { $0 + $1.totalDescendantDraftCount }
  }

  /// Alias that reads naturally at call sites rendering a folder badge.
  public var descendantDraftCount: Int { totalDescendantDraftCount }

  public var totalDraftCount: Int { totalDescendantDraftCount }

  /// All visible directory and virtual-node IDs below this node.  The root's
  /// own ID is intentionally omitted because it is a structural container.
  public var allFolderIDs: [String] {
    children.flatMap { [$0.id] + $0.allFolderIDs }
  }

  /// Returns the visible folder/virtual-node path from this node to a draft.
  /// The structural root is omitted.  A draft directly in this node returns
  /// an empty array.
  public func ancestorFolderIDs(containing draftID: UUID) -> [String] {
    pathToDraft(draftID) ?? []
  }

  private func pathToDraft(_ draftID: UUID) -> [String]? {
    if drafts.contains(draftID) {
      return []
    }
    for child in children {
      if let path = child.pathToDraft(draftID) {
        return [child.id] + path
      }
    }
    return nil
  }

  public static func stableFolderID(
    profileID: UUID,
    canonicalDirectory: String
  ) -> String {
    "site:\(profileID.uuidString.lowercased())/directory:\(canonicalDirectory.normalizedRelativePath())"
  }

  public static func stableVirtualID(
    profileID: UUID,
    kind: DraftFolderNodeKind
  ) -> String {
    "site:\(profileID.uuidString.lowercased())/virtual:\(kind.rawValue)"
  }

  fileprivate init(
    id: String,
    kind: Kind,
    name: String,
    visiblePath: String?,
    canonicalDirectory: String?,
    draftIDs: [UUID],
    children: [DraftFolderNode]
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.visiblePath = visiblePath
    self.canonicalDirectory = canonicalDirectory
    self.draftIDs = draftIDs
    self.children = children
  }
}

/// Pure, deterministic projection of writing drafts into a recursive folder
/// tree.  It performs no repository or filesystem access and has no persisted
/// state.  The caller supplies the current privacy mask and sort order.
public struct DraftFolderProjection: Sendable {
  public typealias Node = DraftFolderNode

  public let profileID: UUID
  public let root: DraftFolderNode

  private let ancestorIDsByDraftID: [UUID: [String]]

  public init(
    profile: SiteProfile,
    drafts: [ArticleDraft],
    sortOrder: DraftListSortOrder = .updatedNewest,
    maskedDraftIDs: Set<UUID> = []
  ) {
    profileID = profile.id

    let draftsByID = Dictionary(drafts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    let contentRootComponents = Self.safeComponents(profile.contentRoot) ?? []

    var mutableRoot = MutableNode(
      kind: .root,
      name: "根目录",
      visiblePath: "",
      canonicalDirectory: profile.contentRoot.normalizedRelativePath()
    )
    var ancestorIDs: [UUID: [String]] = [:]

    for draft in drafts {
      let assignment = Self.assignment(
        for: draft,
        profile: profile,
        contentRootComponents: contentRootComponents,
        isMasked: maskedDraftIDs.contains(draft.id)
      )

      switch assignment {
      case .protected:
        mutableRoot.protectedDraftIDs.append(draft.id)
        ancestorIDs[draft.id] = [
          DraftFolderNode.stableVirtualID(profileID: profile.id, kind: .protectedContent)
        ]

      case .unfiled:
        mutableRoot.unfiledDraftIDs.append(draft.id)
        ancestorIDs[draft.id] = [
          DraftFolderNode.stableVirtualID(profileID: profile.id, kind: .unfiled)
        ]

      case .folder(let canonicalDirectoryComponents, let visibleDirectoryComponents):
        let folderIDs = Self.folderIDs(
          profileID: profile.id,
          canonicalDirectoryComponents: canonicalDirectoryComponents,
          visibleDirectoryComponents: visibleDirectoryComponents
        )
        ancestorIDs[draft.id] = folderIDs
        Self.insert(
          draftID: draft.id,
          canonicalDirectoryComponents: canonicalDirectoryComponents,
          visibleDirectoryComponents: visibleDirectoryComponents,
          depth: 0,
          into: &mutableRoot
        )
      }
    }

    root = Self.materialize(
      mutableRoot,
      profileID: profile.id,
      sortOrder: sortOrder,
      draftsByID: draftsByID
    )
    ancestorIDsByDraftID = ancestorIDs
  }

  /// Convenience overload for callers whose list is the first argument.
  public init(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sortOrder: DraftListSortOrder = .updatedNewest,
    maskedDraftIDs: Set<UUID> = []
  ) {
    self.init(
      profile: profile,
      drafts: drafts,
      sortOrder: sortOrder,
      maskedDraftIDs: maskedDraftIDs
    )
  }

  public var topLevelNodes: [DraftFolderNode] { root.children }

  public var totalDraftCount: Int { root.totalDescendantDraftCount }

  /// Returns folder/virtual-node IDs from the top-most visible node to the
  /// selected draft's nearest folder.  The hidden root node is omitted.
  public func ancestorFolderIDs(for draftID: UUID) -> [String] {
    ancestorIDsByDraftID[draftID] ?? []
  }

  /// Alias for selection code that treats protected and unfiled nodes as
  /// navigation nodes rather than literal folders.
  public func ancestorNodeIDs(for draftID: UUID) -> [String] {
    ancestorFolderIDs(for: draftID)
  }

  public func node(withID id: String) -> DraftFolderNode? {
    Self.findNode(withID: id, in: root)
  }

  /// Builds the root node consumed by the writing-list tree view.
  public static func make(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    sortOrder: DraftListSortOrder = .updatedNewest,
    maskedDraftIDs: Set<UUID> = []
  ) -> DraftFolderNode {
    Self(
      profile: profile,
      drafts: drafts,
      sortOrder: sortOrder,
      maskedDraftIDs: maskedDraftIDs
    ).root
  }

  public static func assignmentCacheKey(
    for draft: ArticleDraft,
    profile: SiteProfile,
    isMasked: Bool
  ) -> DraftFolderAssignmentCacheKey {
    let contentRootComponents = safeComponents(profile.contentRoot) ?? []
    switch assignment(
      for: draft,
      profile: profile,
      contentRootComponents: contentRootComponents,
      isMasked: isMasked
    ) {
    case .protected:
      return .protectedContent
    case .unfiled:
      return .unfiled
    case .folder(let canonicalComponents, let visibleComponents):
      return .folder(
        canonicalDirectory: canonicalComponents.joined(separator: "/"),
        visibleDirectory: visibleComponents.joined(separator: "/")
      )
    }
  }

  private enum Assignment {
    case folder(
      canonicalDirectoryComponents: [String],
      visibleDirectoryComponents: [String]
    )
    case protected
    case unfiled
  }

  private struct MutableNode {
    let kind: DraftFolderNodeKind
    let name: String
    let visiblePath: String?
    let canonicalDirectory: String?
    var directDraftIDs: [UUID] = []
    var folderChildren: [String: MutableNode] = [:]
    var protectedDraftIDs: [UUID] = []
    var unfiledDraftIDs: [UUID] = []
  }

  private static func assignment(
    for draft: ArticleDraft,
    profile: SiteProfile,
    contentRootComponents: [String],
    isMasked: Bool
  ) -> Assignment {
    if isMasked {
      return .protected
    }

    // General drafts intentionally do not get a fabricated repository folder.
    if draft.isGeneralDraft {
      return .unfiled
    }

    let targetPath = profile.markdownPath(for: draft)
    var rawPathCandidates = [targetPath]

    // Private drafts may use their existing private repository path as the
    // target.  The normalized helper on SiteProfile removes leading slashes,
    // so validate the original value too before trusting that target.
    if draft.isPrivate,
      let repositoryPath = draft.repositoryPath?.trimmedForPublishing,
      !repositoryPath.isEmpty,
      profile.isPrivateContentPath(repositoryPath.normalizedRelativePath())
    {
      rawPathCandidates.append(repositoryPath)
    } else {
      // markdownPath(for:) normalizes its pattern.  Keep the original pattern
      // available so an absolute URL/path cannot become apparently relative.
      rawPathCandidates.append(profile.markdownPathPattern)
    }

    guard rawPathCandidates.allSatisfy(Self.isSafeRawPath) else {
      return .unfiled
    }
    guard let targetComponents = Self.safeComponents(targetPath) else {
      return .unfiled
    }

    let canonicalDirectoryComponents = Array(targetComponents.dropLast())
    let visibleDirectoryComponents: [String]
    if !contentRootComponents.isEmpty,
      canonicalDirectoryComponents.starts(with: contentRootComponents)
    {
      visibleDirectoryComponents = Array(
        canonicalDirectoryComponents.dropFirst(contentRootComponents.count)
      )
    } else {
      visibleDirectoryComponents = canonicalDirectoryComponents
    }

    return .folder(
      canonicalDirectoryComponents: canonicalDirectoryComponents,
      visibleDirectoryComponents: visibleDirectoryComponents
    )
  }

  private static func isSafeRawPath(_ path: String) -> Bool {
    let trimmed = path.trimmedForPublishing
    guard !trimmed.isEmpty else { return false }
    guard !trimmed.contains("\\") else { return false }
    guard !trimmed.hasPrefix("/") else { return false }

    // This catches Windows drive paths and URI schemes (for example,
    // `C:/...`, `https://...`, and `file:...`).
    if trimmed.range(
      of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
      options: .regularExpression
    ) != nil {
      return false
    }

    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty,
      !components.contains(where: { $0.isEmpty || $0 == ".." })
    else {
      return false
    }
    return true
  }

  private static func safeComponents(_ path: String) -> [String]? {
    let normalized = path.trimmedForPublishing.normalizedRelativePath()
    guard !normalized.isEmpty else { return nil }
    let components = normalized.split(separator: "/").map(String.init)
    guard !components.isEmpty,
      !components.contains(where: { $0 == ".." || $0 == "." })
    else {
      return nil
    }
    return components
  }

  private static func folderIDs(
    profileID: UUID,
    canonicalDirectoryComponents: [String],
    visibleDirectoryComponents: [String]
  ) -> [String] {
    guard !visibleDirectoryComponents.isEmpty else { return [] }
    let offset = canonicalDirectoryComponents.count - visibleDirectoryComponents.count
    return visibleDirectoryComponents.indices.map { index in
      let prefixEnd = offset + index + 1
      let canonicalDirectory =
        canonicalDirectoryComponents
        .prefix(prefixEnd)
        .joined(separator: "/")
      return DraftFolderNode.stableFolderID(
        profileID: profileID,
        canonicalDirectory: canonicalDirectory
      )
    }
  }

  private static func insert(
    draftID: UUID,
    canonicalDirectoryComponents: [String],
    visibleDirectoryComponents: [String],
    depth: Int,
    into node: inout MutableNode
  ) {
    guard !visibleDirectoryComponents.isEmpty else {
      node.directDraftIDs.append(draftID)
      return
    }

    let offset = canonicalDirectoryComponents.count - visibleDirectoryComponents.count
    let component = visibleDirectoryComponents[depth]
    let canonicalDirectory =
      canonicalDirectoryComponents
      .prefix(offset + depth + 1)
      .joined(separator: "/")
    let visiblePath =
      visibleDirectoryComponents
      .prefix(depth + 1)
      .joined(separator: "/")
    var child =
      node.folderChildren[component]
      ?? MutableNode(
        kind: .directory,
        name: component,
        visiblePath: visiblePath,
        canonicalDirectory: canonicalDirectory
      )

    if depth + 1 == visibleDirectoryComponents.count {
      child.directDraftIDs.append(draftID)
    } else {
      Self.insert(
        draftID: draftID,
        canonicalDirectoryComponents: canonicalDirectoryComponents,
        visibleDirectoryComponents: visibleDirectoryComponents,
        depth: depth + 1,
        into: &child
      )
    }
    node.folderChildren[component] = child
  }

  private static func materialize(
    _ mutableNode: MutableNode,
    profileID: UUID,
    sortOrder: DraftListSortOrder,
    draftsByID: [UUID: ArticleDraft]
  ) -> DraftFolderNode {
    func sortedDraftIDs(_ ids: [UUID]) -> [UUID] {
      DraftListProjection
        .sorted(ids.compactMap { draftsByID[$0] }, by: sortOrder)
        .map(\.id)
    }

    var children = mutableNode.folderChildren.values.map {
      materialize(
        $0,
        profileID: profileID,
        sortOrder: sortOrder,
        draftsByID: draftsByID
      )
    }

    if mutableNode.kind == .root {
      if !mutableNode.protectedDraftIDs.isEmpty {
        children.append(
          DraftFolderNode(
            id: DraftFolderNode.stableVirtualID(profileID: profileID, kind: .protectedContent),
            kind: .protectedContent,
            name: "私密文章",
            visiblePath: nil,
            canonicalDirectory: nil,
            draftIDs: sortedDraftIDs(mutableNode.protectedDraftIDs),
            children: []
          )
        )
      }
      if !mutableNode.unfiledDraftIDs.isEmpty {
        children.append(
          DraftFolderNode(
            id: DraftFolderNode.stableVirtualID(profileID: profileID, kind: .unfiled),
            kind: .unfiled,
            name: "未分类",
            visiblePath: nil,
            canonicalDirectory: nil,
            draftIDs: sortedDraftIDs(mutableNode.unfiledDraftIDs),
            children: []
          )
        )
      }
    }

    children.sort(by: localizedNodeOrder)
    let directDraftIDs = sortedDraftIDs(mutableNode.directDraftIDs)
    let id: String
    switch mutableNode.kind {
    case .root:
      id = DraftFolderNode.stableFolderID(
        profileID: profileID,
        canonicalDirectory: mutableNode.canonicalDirectory ?? ""
      )
    case .directory:
      id = DraftFolderNode.stableFolderID(
        profileID: profileID,
        canonicalDirectory: mutableNode.canonicalDirectory ?? ""
      )
    case .protectedContent, .unfiled:
      id = DraftFolderNode.stableVirtualID(profileID: profileID, kind: mutableNode.kind)
    }

    return DraftFolderNode(
      id: id,
      kind: mutableNode.kind,
      name: mutableNode.name,
      visiblePath: mutableNode.visiblePath,
      canonicalDirectory: mutableNode.canonicalDirectory,
      draftIDs: directDraftIDs,
      children: children
    )
  }

  private static func localizedNodeOrder(
    _ lhs: DraftFolderNode,
    _ rhs: DraftFolderNode
  ) -> Bool {
    let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
    guard nameComparison == .orderedSame else {
      return nameComparison == .orderedAscending
    }

    // The canonical path tie-breaker keeps same-leaf nodes deterministic,
    // while kind/id make virtual and regular nodes with equal names stable.
    let lhsPath = lhs.canonicalDirectory ?? ""
    let rhsPath = rhs.canonicalDirectory ?? ""
    if lhsPath != rhsPath {
      return lhsPath < rhsPath
    }
    if lhs.kind != rhs.kind {
      return lhs.kind.rawValue < rhs.kind.rawValue
    }
    return lhs.id < rhs.id
  }

  private static func findNode(
    withID id: String,
    in node: DraftFolderNode
  ) -> DraftFolderNode? {
    if node.id == id {
      return node
    }
    for child in node.children {
      if let match = findNode(withID: id, in: child) {
        return match
      }
    }
    return nil
  }
}
