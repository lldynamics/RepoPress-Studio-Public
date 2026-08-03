import Foundation

extension KnowledgeLibraryService {
  public func search(
    query: String,
    limit: Int = 30,
    onlyRemoteAIAllowed: Bool = false,
    documentIDs: Set<UUID>? = nil,
    requiredSignal: KnowledgeRetrievalSignal? = nil
  ) throws -> [KnowledgeSearchResult] {
    try checkSearchCancellation()
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty, limit > 0 else { return [] }
    let candidateLimit = min(max(limit * 4, 48), 240)
    let database = try database()
    try checkSearchCancellation()
    let rawFullTextResults = try database.search(
      query: trimmedQuery,
      limit: candidateLimit,
      onlyRemoteAIAllowed: onlyRemoteAIAllowed,
      documentIDs: documentIDs
    )
    var fullTextResults: [KnowledgeSearchResult] = []
    fullTextResults.reserveCapacity(rawFullTextResults.count)
    for result in rawFullTextResults {
      try checkSearchCancellation()
      var explainedResult = result
      explainedResult.signals = searchPresentationService.lexicalSignals(
        for: result,
        query: trimmedQuery
      )
      fullTextResults.append(explainedResult)
    }

    let queryVectors = semanticEmbeddingService.vectors(for: trimmedQuery)
    try checkSearchCancellation()
    var semanticRankings: [[KnowledgeSearchResult]] = []
    semanticRankings.reserveCapacity(queryVectors.count)
    for queryVector in queryVectors {
      try checkSearchCancellation()
      try ensureSemanticIndex(for: queryVector, database: database)
      try checkSearchCancellation()
      let ranking = try database.semanticSearch(
        queryVector: queryVector,
        limit: candidateLimit,
        onlyRemoteAIAllowed: onlyRemoteAIAllowed,
        documentIDs: documentIDs
      )
      try checkSearchCancellation()
      semanticRankings.append(ranking)
    }

    let eligibleFullTextResults: [KnowledgeSearchResult]
    let eligibleSemanticRankings: [[KnowledgeSearchResult]]
    switch requiredSignal {
    case nil:
      eligibleFullTextResults = fullTextResults
      eligibleSemanticRankings = semanticRankings
    case .semantic:
      eligibleFullTextResults = []
      eligibleSemanticRankings = semanticRankings
    case .title, .fullText:
      var eligibleFullText: [KnowledgeSearchResult] = []
      for result in fullTextResults {
        try checkSearchCancellation()
        if requiredSignal.map(result.signals.contains) ?? true {
          eligibleFullText.append(result)
        }
      }
      let eligibleResultIDs = Set(eligibleFullText.map(\.id))
      eligibleFullTextResults = eligibleFullText
      var filteredRankings: [[KnowledgeSearchResult]] = []
      filteredRankings.reserveCapacity(semanticRankings.count)
      for ranking in semanticRankings {
        var filteredRanking: [KnowledgeSearchResult] = []
        filteredRanking.reserveCapacity(ranking.count)
        for result in ranking {
          try checkSearchCancellation()
          if eligibleResultIDs.contains(result.id) {
            filteredRanking.append(result)
          }
        }
        filteredRankings.append(filteredRanking)
      }
      eligibleSemanticRankings = filteredRankings
    }

    try checkSearchCancellation()
    return try fusedSearchResults(
      fullText: eligibleFullTextResults,
      semanticRankings: eligibleSemanticRankings,
      limit: limit
    )
  }

  public func searchAsync(
    query: String,
    limit: Int = 30,
    onlyRemoteAIAllowed: Bool = false,
    documentIDs: Set<UUID>? = nil,
    requiredSignal: KnowledgeRetrievalSignal? = nil
  ) async throws -> [KnowledgeSearchResult] {
    try Task.checkCancellation()
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try service.checkSearchCancellation()
      service.semanticEmbeddingService.prepareContextualModelIfNeeded(for: query)
      try service.checkSearchCancellation()
      return try service.search(
        query: query,
        limit: limit,
        onlyRemoteAIAllowed: onlyRemoteAIAllowed,
        documentIDs: documentIDs,
        requiredSignal: requiredSignal
      )
    }
    // An unstructured detached task does not inherit cancellation that arrives
    // after creation, so explicitly forward the outer search cancellation.
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func relatedChapters(
    documentID: UUID,
    anchorChunkID: UUID? = nil,
    limit: Int = 8
  ) throws -> [KnowledgeRelatedChapter] {
    guard limit > 0 else { return [] }
    let database = try database()
    let records = try database.semanticIndexRecords()
    let documentRecords = records.filter { $0.document.id == documentID }
    guard let anchor = anchorChunkID.flatMap({ chunkID in
      documentRecords.first { $0.chunk.id == chunkID }
    }) ?? documentRecords.first else { return [] }

    let anchorText: String
    if anchorChunkID != nil {
      anchorText = anchor.searchableText
    } else {
      anchorText = ([
        anchor.document.title,
        anchor.document.summary,
        anchor.document.authors.joined(separator: " "),
        anchor.document.tags.joined(separator: " "),
      ] + documentRecords.prefix(3).map(\.chunk.content))
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    var semanticScores: [UUID: Double] = [:]
    for queryVector in semanticEmbeddingService.vectors(for: anchorText) {
      try ensureSemanticIndex(for: queryVector, database: database)
      let matches = try database.semanticSearch(
        queryVector: queryVector,
        limit: min(max(records.count, limit * 12), 240),
      onlyRemoteAIAllowed: false
      )
      for match in matches {
        semanticScores[match.chunk.id] = max(
          semanticScores[match.chunk.id, default: 0],
          match.score
        )
      }
    }

    return KnowledgeRelatedChapterRankingService().recommendations(
      anchor: anchor,
      candidates: records,
      semanticScores: semanticScores,
      limit: limit
    )
  }

  public func relatedChaptersAsync(
    documentID: UUID,
    anchorChunkID: UUID? = nil,
    limit: Int = 8
  ) async throws -> [KnowledgeRelatedChapter] {
    let service = self
    return try await Task.detached(priority: .utility) {
      try service.relatedChapters(
        documentID: documentID,
        anchorChunkID: anchorChunkID,
        limit: limit
      )
    }.value
  }

  public func context(
    query: String,
    documentIDs: Set<UUID>? = nil,
    maximumCitations: Int = 8,
    tokenBudget: Int = 2_200
  ) throws -> KnowledgeContextSnapshot? {
    let candidates = try search(
      query: query,
      limit: max(maximumCitations * 4, 16),
      onlyRemoteAIAllowed: true,
      documentIDs: documentIDs
    )
    guard !candidates.isEmpty else { return nil }

    var citations: [KnowledgeCitation] = []
    var usedTokens = 0
    var documentUseCounts: [UUID: Int] = [:]

    for result in candidates {
      guard citations.count < maximumCitations else { break }
      let currentDocumentCount = documentUseCounts[result.document.id, default: 0]
      guard currentDocumentCount < 2 else { continue }
      let remainingBudget = tokenBudget - usedTokens
      guard remainingBudget > 100 else { break }

      let maximumCharacters = min(1_500, remainingBudget * 3)
      let excerpt = clipped(result.chunk.content, maximumCharacters: maximumCharacters)
      let estimatedTokens = max(1, Int(ceil(Double(excerpt.count) / 3.0)))
      guard estimatedTokens <= remainingBudget else { continue }

      citations.append(KnowledgeCitation(
        id: "K\(citations.count + 1)",
        documentID: result.document.id,
        chunkID: result.chunk.id,
        title: result.document.title,
        authors: result.document.authors,
        locator: result.chunk.locator?.nilIfEmpty ?? result.chunk.headingPath?.nilIfEmpty,
        excerpt: excerpt,
        sourceURL: result.document.sourceURL
      ))
      usedTokens += estimatedTokens
      documentUseCounts[result.document.id] = currentDocumentCount + 1
    }

    guard !citations.isEmpty else { return nil }
    return KnowledgeContextSnapshot(query: query, citations: citations)
  }

  public func contextAsync(
    query: String,
    documentIDs: Set<UUID>? = nil,
    maximumCitations: Int = 8,
    tokenBudget: Int = 2_200
  ) async throws -> KnowledgeContextSnapshot? {
    semanticEmbeddingService.prepareContextualModelIfNeeded(for: query)
    let service = self
    return try await Task.detached(priority: .userInitiated) {
      try service.context(
        query: query,
        documentIDs: documentIDs,
        maximumCitations: maximumCitations,
        tokenBudget: tokenBudget
      )
    }.value
  }

  public func repairSemanticVectors() async throws -> KnowledgeSemanticRepairReport {
    try Task.checkCancellation()
    let service = self
    let task = Task.detached(priority: .utility) {
      try service.repairSemanticVectorsSynchronously()
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  public func repairSemanticVectors(
    documentIDs: Set<UUID>
  ) async throws -> KnowledgeSemanticRepairReport {
    try Task.checkCancellation()
    let service = self
    let task = Task.detached(priority: .utility) {
      try service.repairSemanticVectorsSynchronously(documentIDs: documentIDs)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  func ensureSemanticIndex(
    for queryVector: KnowledgeSemanticVector,
    database: KnowledgeDatabase
  ) throws {
    try checkSearchCancellation()
    while !semanticBackfillLock.lock(before: Date(timeIntervalSinceNow: 0.02)) {
      try checkSearchCancellation()
    }
    defer { semanticBackfillLock.unlock() }
    try checkSearchCancellation()
    let modelIdentifier = queryVector.modelIdentifier
    guard !backfilledSemanticModelIDs.contains(modelIdentifier) else { return }

    let repairRecords = try database.semanticIndexRecordsNeedingRepair(
      modelIdentifier: modelIdentifier,
      expectedDimension: queryVector.values.count
    )
    try checkSearchCancellation()
    var embeddings: [KnowledgeChunkEmbedding] = []
    embeddings.reserveCapacity(repairRecords.count)
    for record in repairRecords {
      try checkSearchCancellation()
      guard let vector = semanticEmbeddingService.vector(
        for: record.searchableText,
        modelIdentifier: modelIdentifier
      ) else {
        continue
      }
      try checkSearchCancellation()
      embeddings.append(KnowledgeChunkEmbedding(
        chunkID: record.chunk.id,
        revisionID: record.chunk.revisionID,
        vector: vector
      ))
    }
    try checkSearchCancellation()
    try database.upsertSemanticEmbeddings(embeddings)
    try checkSearchCancellation()
    backfilledSemanticModelIDs.insert(modelIdentifier)
  }

  func repairSemanticVectorsSynchronously() throws -> KnowledgeSemanticRepairReport {
    try Task.checkCancellation()
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }

    let database = try database()
    let records = try database.semanticIndexRecords()
    let rebuilt = try rebuiltSemanticEmbeddings(for: records)
    try database.replaceAllSemanticEmbeddings(rebuilt.embeddings)
    backfilledSemanticModelIDs.removeAll()
    return KnowledgeSemanticRepairReport(
      scannedChunkCount: records.count,
      regeneratedVectorCount: rebuilt.embeddings.count,
      modelIdentifiers: Array(rebuilt.modelIdentifiers)
    )
  }

  func repairSemanticVectorsSynchronously(
    documentIDs: Set<UUID>
  ) throws -> KnowledgeSemanticRepairReport {
    guard !documentIDs.isEmpty else {
      return KnowledgeSemanticRepairReport(
        scannedChunkCount: 0,
        regeneratedVectorCount: 0,
        modelIdentifiers: []
      )
    }
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }

    let database = try database()
    let records = try database.semanticIndexRecords().filter {
      documentIDs.contains($0.document.id)
    }
    let rebuilt = try rebuiltSemanticEmbeddings(for: records)
    try database.replaceSemanticEmbeddings(
      documentIDs: documentIDs,
      embeddings: rebuilt.embeddings
    )
    backfilledSemanticModelIDs.removeAll()
    return KnowledgeSemanticRepairReport(
      scannedChunkCount: records.count,
      regeneratedVectorCount: rebuilt.embeddings.count,
      modelIdentifiers: Array(rebuilt.modelIdentifiers)
    )
  }

  func rebuiltSemanticEmbeddings(
    for records: [KnowledgeSemanticIndexRecord]
  ) throws -> (embeddings: [KnowledgeChunkEmbedding], modelIdentifiers: Set<String>) {
    var embeddings: [KnowledgeChunkEmbedding] = []
    var modelIdentifiers = Set<String>()
    for record in records {
      try Task.checkCancellation()
      let vectors = semanticEmbeddingService.vectors(for: record.searchableText)
      try Task.checkCancellation()
      for vector in vectors {
        modelIdentifiers.insert(vector.modelIdentifier)
        embeddings.append(KnowledgeChunkEmbedding(
          chunkID: record.chunk.id,
          revisionID: record.chunk.revisionID,
          vector: vector
        ))
      }
    }
    try Task.checkCancellation()
    return (embeddings, modelIdentifiers)
  }

  func fusedSearchResults(
    fullText: [KnowledgeSearchResult],
    semanticRankings: [[KnowledgeSearchResult]],
    limit: Int
  ) throws -> [KnowledgeSearchResult] {
    let rankConstant = 60.0
    var resultByID: [UUID: KnowledgeSearchResult] = [:]
    var scoreByID: [UUID: Double] = [:]
    var signalsByID: [UUID: Set<KnowledgeRetrievalSignal>] = [:]

    for (offset, result) in fullText.enumerated() {
      try checkSearchCancellation()
      let contribution = 0.62 / (rankConstant + Double(offset + 1))
      resultByID[result.id] = result
      scoreByID[result.id, default: 0] += contribution
      signalsByID[result.id, default: []].formUnion(result.signals)
    }

    var bestSemanticContribution: [UUID: Double] = [:]
    var bestSemanticResult: [UUID: KnowledgeSearchResult] = [:]
    for ranking in semanticRankings {
      for (offset, result) in ranking.enumerated() {
        try checkSearchCancellation()
        let rankContribution = 0.38 / (rankConstant + Double(offset + 1))
        let similarityContribution = max(0, result.score) * 0.0015
        let contribution = rankContribution + similarityContribution
        if contribution > bestSemanticContribution[result.id, default: -.infinity] {
          bestSemanticContribution[result.id] = contribution
          bestSemanticResult[result.id] = result
        }
      }
    }

    for (id, contribution) in bestSemanticContribution {
      try checkSearchCancellation()
      if resultByID[id] == nil, let semanticResult = bestSemanticResult[id] {
        resultByID[id] = semanticResult
      }
      scoreByID[id, default: 0] += contribution
      signalsByID[id, default: []].formUnion([.semantic])
    }

    var fused: [KnowledgeSearchResult] = []
    fused.reserveCapacity(resultByID.count)
    for (id, storedResult) in resultByID {
      try checkSearchCancellation()
      var result = storedResult
      result.score = scoreByID[id, default: 0]
      result.signals = signalsByID[id, default: []]
      fused.append(result)
    }
    try checkSearchCancellation()
    fused.sort {
      if $0.score != $1.score { return $0.score > $1.score }
      if $0.document.updatedAt != $1.document.updatedAt {
        return $0.document.updatedAt > $1.document.updatedAt
      }
      return $0.chunk.ordinal < $1.chunk.ordinal
    }
    try checkSearchCancellation()
    return try searchDiversificationService.rankCancellable(fused, limit: limit)
  }

  func checkSearchCancellation() throws {
    try searchCancellationCheck()
  }

  func invalidateSemanticBackfillCache() {
    semanticBackfillLock.lock()
    backfilledSemanticModelIDs.removeAll()
    semanticBackfillLock.unlock()
  }
}
