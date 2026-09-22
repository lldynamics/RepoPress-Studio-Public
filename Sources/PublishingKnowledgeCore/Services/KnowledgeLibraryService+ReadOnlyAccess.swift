import Foundation

extension KnowledgeLibraryService {
  /// Lexical lookup for remote AI excludes unapproved documents and does not
  /// trigger semantic-index creation or backfill.
  package func lexicalSearchForRemoteAI(
    query: String,
    limit: Int
  ) throws -> [KnowledgeSearchResult] {
    let database = try database()
    try Task.checkCancellation()
    return try database.search(query: query, limit: limit, onlyRemoteAIAllowed: true)
  }

  /// The caller owns authorization; storage binds the lookup to both document
  /// and revision so a chunk from another version cannot be substituted.
  package func chunk(
    id: UUID,
    documentID: UUID,
    revisionID: UUID
  ) throws -> KnowledgeChunk? {
    try database().chunk(id: id, documentID: documentID, revisionID: revisionID)
  }
}
