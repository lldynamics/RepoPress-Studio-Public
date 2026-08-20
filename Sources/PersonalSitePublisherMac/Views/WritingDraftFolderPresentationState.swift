enum WritingDraftListDisplayMode: String, CaseIterable, Identifiable {
  case flat
  case folders

  var id: String { rawValue }
}

/// Presentation-only expansion state for the writing-draft folder projection.
///
/// Folder IDs are deliberately opaque. The projection owns the relationship
/// between a folder and its ancestors; this value type only remembers which
/// IDs should currently be visible. Draft IDs and path persistence do not
/// belong here.
struct WritingDraftFolderExpansionState: Equatable, Hashable {
  private(set) var userExpandedFolderIDs: Set<String>
  private(set) var transientlyRevealedFolderIDs: Set<String>

  /// Starts with every folder collapsed. A caller can use the other
  /// initializer when a projection has roots it wants open on first render.
  init() {
    userExpandedFolderIDs = []
    transientlyRevealedFolderIDs = []
  }

  /// Creates state with the supplied root IDs expanded for this presentation.
  ///
  /// This is intentionally an in-memory initializer. Callers may choose a
  /// deterministic set of root IDs without making raw or private paths a
  /// process-wide persisted preference.
  init<S: Sequence>(initiallyExpandedFolderIDs: S) where S.Element == String {
    userExpandedFolderIDs = Set(initiallyExpandedFolderIDs)
    transientlyRevealedFolderIDs = []
  }

  /// Convenience spelling for callers whose projection already calls these
  /// IDs its roots.
  init<S: Sequence>(rootFolderIDs: S) where S.Element == String {
    self.init(initiallyExpandedFolderIDs: rootFolderIDs)
  }

  /// The IDs rendered as expanded. Transient reveals never remove a user's
  /// explicit choice; they only add to it while the reveal is active.
  var expandedFolderIDs: Set<String> {
    userExpandedFolderIDs.union(transientlyRevealedFolderIDs)
  }

  /// Alias that makes the union semantics explicit at call sites.
  var effectiveExpandedFolderIDs: Set<String> {
    expandedFolderIDs
  }

  func isExpanded(_ folderID: String) -> Bool {
    expandedFolderIDs.contains(folderID)
  }

  /// Applies a user disclosure action. Transient search reveals are
  /// intentionally left untouched and are cleared by the caller's lifecycle.
  mutating func toggle(_ folderID: String) {
    if userExpandedFolderIDs.contains(folderID) {
      userExpandedFolderIDs.remove(folderID)
    } else {
      userExpandedFolderIDs.insert(folderID)
    }
  }

  mutating func toggle(folderID: String) {
    toggle(folderID)
  }

  mutating func setExpanded(_ isExpanded: Bool, for folderID: String) {
    if isExpanded {
      userExpandedFolderIDs.insert(folderID)
    } else {
      userExpandedFolderIDs.remove(folderID)
    }
  }

  mutating func setExpanded(_ folderID: String, to isExpanded: Bool) {
    setExpanded(isExpanded, for: folderID)
  }

  /// Drops expansion IDs that no longer exist in the current projection.
  /// Both persistent-in-this-session and transient IDs are reconciled so a
  /// deleted or filtered folder cannot remain logically expanded forever.
  mutating func reconcile<S: Sequence>(validFolderIDs: S) where S.Element == String {
    let validIDs = Set(validFolderIDs)
    userExpandedFolderIDs.formIntersection(validIDs)
    transientlyRevealedFolderIDs.formIntersection(validIDs)
  }

  /// Reveals the complete ancestor chain needed to show a programmatically
  /// selected draft. The projection supplies the chain because this type does
  /// not know how folder IDs map to paths.
  mutating func revealAncestorsForSelection<S: Sequence>(_ ancestorFolderIDs: S)
  where S.Element == String {
    userExpandedFolderIDs.formUnion(ancestorFolderIDs)
  }

  mutating func revealAncestors<S: Sequence>(forSelection ancestorFolderIDs: S)
  where S.Element == String {
    revealAncestorsForSelection(ancestorFolderIDs)
  }

  /// Temporarily reveals search-result ancestors. This does not change the
  /// user's explicit expansion choices and can be removed when search ends.
  mutating func revealSearchResultAncestors<S: Sequence>(_ ancestorFolderIDs: S)
  where S.Element == String {
    transientlyRevealedFolderIDs.formUnion(ancestorFolderIDs)
  }

  /// Ends the transient reveal lifecycle (normally when search is cleared).
  mutating func clearTransientReveal() {
    transientlyRevealedFolderIDs.removeAll(keepingCapacity: true)
  }

  mutating func clearTransientReveals() {
    clearTransientReveal()
  }
}
