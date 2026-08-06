import Foundation

public struct ArticleGraphNode: Hashable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var siteProfileID: UUID
  public var tags: [String]
  public var isPrivate: Bool
  public var incomingLinkCount: Int
  public var outgoingLinkCount: Int

  public init(
    id: UUID,
    title: String,
    siteProfileID: UUID,
    tags: [String],
    isPrivate: Bool,
    incomingLinkCount: Int = 0,
    outgoingLinkCount: Int = 0
  ) {
    self.id = id
    self.title = title
    self.siteProfileID = siteProfileID
    self.tags = tags
    self.isPrivate = isPrivate
    self.incomingLinkCount = incomingLinkCount
    self.outgoingLinkCount = outgoingLinkCount
  }
}

public struct ArticleGraphEdge: Hashable, Identifiable, Sendable {
  public var id: String { "\(sourceID.uuidString)->\(targetID.uuidString)" }
  public var sourceID: UUID
  public var targetID: UUID
  public var relationshipType: RelationshipType
  public var weight: Double

  public enum RelationshipType: String, Hashable, Sendable {
    case internalLink = "双向链接"
    case sharedTag = "同标签关联"
    case categoryGroup = "同分类分组"
  }

  public init(
    sourceID: UUID,
    targetID: UUID,
    relationshipType: RelationshipType,
    weight: Double = 1.0
  ) {
    self.sourceID = sourceID
    self.targetID = targetID
    self.relationshipType = relationshipType
    self.weight = weight
  }
}

public struct ArticleGraphTopology: Sendable {
  public var nodes: [ArticleGraphNode]
  public var edges: [ArticleGraphEdge]

  public init(nodes: [ArticleGraphNode] = [], edges: [ArticleGraphEdge] = []) {
    self.nodes = nodes
    self.edges = edges
  }
}

public struct ArticleGraphRelationService: Sendable {
  public init() {}

  public func buildTopology(
    drafts: [ArticleDraft],
    profileID: UUID? = nil
  ) -> ArticleGraphTopology {
    let targetDrafts = drafts.filter { draft in
      guard !draft.isGeneralDraft else { return false }
      if let profileID {
        return draft.belongs(toSiteProfileID: profileID)
      }
      return true
    }

    var nodeMap: [UUID: ArticleGraphNode] = [:]
    var edges: [ArticleGraphEdge] = []
    var incomingCounts: [UUID: Int] = [:]
    var outgoingCounts: [UUID: Int] = [:]

    for draft in targetDrafts {
      nodeMap[draft.id] = ArticleGraphNode(
        id: draft.id,
        title: draft.title.isEmpty ? CoreL10n.text("untitled") : draft.title,
        siteProfileID: draft.siteProfileID,
        tags: draft.tags,
        isPrivate: draft.isPrivate
      )
    }

    // 1. Build Internal Wiki Link / Counterpart Edges
    let titleToIDMap = Dictionary(targetDrafts.map { ($0.title.lowercased(), $0.id) }) { first, _ in first }

    for draft in targetDrafts {
      let body = draft.bodyMarkdown
      let internalLinkRegex = try? NSRegularExpression(pattern: #"\b(?:\[\[([^\]]+)\]\]|\[([^\]]+)\]\(([^)]+)\))"#)
      let matches = internalLinkRegex?.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) ?? []

      for match in matches {
        let nsBody = body as NSString
        let candidateText: String
        if match.range(at: 1).location != NSNotFound {
          candidateText = nsBody.substring(with: match.range(at: 1))
        } else if match.range(at: 2).location != NSNotFound {
          candidateText = nsBody.substring(with: match.range(at: 2))
        } else {
          continue
        }

        let targetTitle = candidateText.trimmedForPublishing.lowercased()
        if let targetID = titleToIDMap[targetTitle], targetID != draft.id {
          edges.append(ArticleGraphEdge(
            sourceID: draft.id,
            targetID: targetID,
            relationshipType: .internalLink,
            weight: 2.0
          ))
          outgoingCounts[draft.id, default: 0] += 1
          incomingCounts[targetID, default: 0] += 1
        }
      }

      // 2. Build Tag Overlap Edges
      for other in targetDrafts where other.id != draft.id {
        let commonTags = Set(draft.tags).intersection(Set(other.tags))
        if !commonTags.isEmpty {
          let edgeID1 = "\(draft.id.uuidString)->\(other.id.uuidString)"
          let edgeID2 = "\(other.id.uuidString)->\(draft.id.uuidString)"
          if !edges.contains(where: { $0.id == edgeID1 || $0.id == edgeID2 }) {
            edges.append(ArticleGraphEdge(
              sourceID: draft.id,
              targetID: other.id,
              relationshipType: .sharedTag,
              weight: Double(commonTags.count) * 0.5
            ))
          }
        }
      }
    }

    var finalNodes: [ArticleGraphNode] = []
    for (id, var node) in nodeMap {
      node.incomingLinkCount = incomingCounts[id] ?? 0
      node.outgoingLinkCount = outgoingCounts[id] ?? 0
      finalNodes.append(node)
    }

    return ArticleGraphTopology(nodes: finalNodes, edges: edges)
  }
}
