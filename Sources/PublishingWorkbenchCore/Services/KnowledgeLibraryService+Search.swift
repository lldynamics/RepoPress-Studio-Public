import Foundation
import PublishingCoreSupport
import PublishingKnowledgeCore

private enum KnowledgeSearchTokenSupport {
  static let tokenizer = LocalBPETokenizer(encoding: .o200kBase)
}

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

    // `search` remains a hybrid API even when a caller later filters signals.
    // The agent's dedicated lexical path calls the FTS store directly, so it
    // does not need this public API to weaken normal retrieval semantics.
    let queryVectors = semanticEmbeddingService.vectors(for: trimmedQuery, role: .query)
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
    guard
      let anchor = anchorChunkID.flatMap({ chunkID in
        documentRecords.first { $0.chunk.id == chunkID }
      }) ?? documentRecords.first
    else { return [] }

    let anchorText: String
    if anchorChunkID != nil {
      anchorText = anchor.searchableText
    } else {
      anchorText =
        ([
          anchor.document.title,
          anchor.document.summary,
          anchor.document.authors.joined(separator: " "),
          anchor.document.tags.joined(separator: " "),
        ] + documentRecords.prefix(3).map(\.chunk.content))
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    var semanticScores: [UUID: Double] = [:]
    for queryVector in semanticEmbeddingService.vectors(for: anchorText, role: .query) {
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
    var authorizationBindings: [KnowledgeAuthorizationBinding] = []
    var usedTokens = 0
    var documentUseCounts: [UUID: Int] = [:]

    for result in candidates {
      guard citations.count < maximumCitations else { break }
      let currentDocumentCount = documentUseCounts[result.document.id, default: 0]
      guard currentDocumentCount < 2 else { continue }
      let remainingBudget = tokenBudget - usedTokens
      guard remainingBudget > 100 else { break }

      let maximumTokens = min(1_500, remainingBudget)
      let excerpt = clippedToTokenBudget(
        result.chunk.content,
        maximumTokens: maximumTokens
      )
      let estimatedTokens = max(1, KnowledgeSearchTokenSupport.tokenizer.tokenCount(excerpt))
      guard estimatedTokens <= remainingBudget else { continue }

      citations.append(
        KnowledgeCitation(
          id: "K\(citations.count + 1)",
          documentID: result.document.id,
          chunkID: result.chunk.id,
          title: result.document.title,
          authors: result.document.authors,
          locator: result.chunk.locator?.nilIfEmpty ?? result.chunk.headingPath?.nilIfEmpty,
          excerpt: excerpt,
          sourceURL: result.document.sourceURL
        ))
      authorizationBindings.append(
        KnowledgeAuthorizationBinding(
          documentID: result.document.id,
          revisionID: result.chunk.revisionID,
          chunkID: result.chunk.id,
          contentHash: result.chunk.contentHash
        ))
      usedTokens += estimatedTokens
      documentUseCounts[result.document.id] = currentDocumentCount + 1
    }

    guard !citations.isEmpty else { return nil }
    return KnowledgeContextSnapshot(
      query: query,
      citations: citations,
      authorizationBindings: authorizationBindings
    )
  }

  private func clippedToTokenBudget(_ text: String, maximumTokens: Int) -> String {
    guard maximumTokens > 0 else { return "" }
    let tokenizer = KnowledgeSearchTokenSupport.tokenizer
    guard tokenizer.tokenCount(text) > maximumTokens else { return text }

    let paragraphs =
      text
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard paragraphs.count >= 2 else {
      let scalars = Array(text.unicodeScalars)
      var low = 0
      var high = scalars.count
      var best = ""
      while low <= high {
        let middle = (low + high) / 2
        let prefix = String(String.UnicodeScalarView(scalars.prefix(middle)))
        if tokenizer.tokenCount(prefix + "…") <= maximumTokens {
          best = prefix
          low = middle + 1
        } else {
          high = middle - 1
        }
      }
      return (best + "…").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var head = paragraphs[0]
    var tail = paragraphs[paragraphs.count - 1]
    var candidate = head + "\n…\n" + tail
    while tokenizer.tokenCount(candidate) > maximumTokens {
      if head.count >= tail.count, head.count > 1 {
        head = String(head.dropLast(max(1, head.count / 8)))
      } else if tail.count > 1 {
        tail = String(tail.dropFirst(max(1, tail.count / 8)))
      } else {
        break
      }
      candidate = head + "\n…\n" + tail
    }
    return tokenizer.tokenCount(candidate) <= maximumTokens
      ? candidate
      : String(head.prefix(1)) + "…"
  }

  public func contextAsync(
    query: String,
    documentIDs: Set<UUID>? = nil,
    maximumCitations: Int = 8,
    tokenBudget: Int = 2_200
  ) async throws -> KnowledgeContextSnapshot? {
    let service = self
    let task = Task.detached(priority: .userInitiated) {
      try service.checkSearchCancellation()
      service.semanticEmbeddingService.prepareContextualModelIfNeeded(for: query)
      try service.checkSearchCancellation()
      return try service.context(
        query: query,
        documentIDs: documentIDs,
        maximumCitations: maximumCitations,
        tokenBudget: tokenBudget
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
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
    let modelIdentifier = queryVector.modelIdentifier
    let isAlreadyBackfilled = backfilledSemanticModelIDs.contains(modelIdentifier)
    let generation = semanticBackfillGeneration
    semanticBackfillLock.unlock()
    try checkSearchCancellation()
    guard !isAlreadyBackfilled else { return }

    // The deterministic fallback is the baseline retrieval contract.  Repair
    // one small page synchronously after an old-schema upgrade so an existing
    // library regains local semantic recall without waiting for a detached
    // task; dense/new providers are always background-only.
    if modelIdentifier == KnowledgeSemanticEmbeddingService.fallbackModelIdentifier {
      let page = try database.semanticIndexRepairScanPage(
        modelIdentifier: modelIdentifier,
        expectedDimension: queryVector.values.count,
        expectedEncodingVersion: queryVector.encodingVersion,
        offset: 0,
        maximumScannedRecords: 24
      )
      _ = try backfillSemanticRecords(
        page.records,
        database: database,
        modelIdentifier: modelIdentifier,
        expectedDimension: queryVector.values.count,
        expectedEncodingVersion: queryVector.encodingVersion,
        generation: generation
      )
    }
    // A newly available dense model must never make the first search wait for
    // a whole-library rebuild.  Existing hash vectors are searched now; the
    // incremental writer is cancellable and resumes from repair state later.
    scheduleSemanticBackfill(
      modelIdentifier: modelIdentifier,
      expectedDimension: queryVector.values.count,
      expectedEncodingVersion: queryVector.encodingVersion
    )
  }

  /// Processes bounded scan/write pages. The offset advances by inspected
  /// current chunks, not by repaired rows, so one run is linear in library
  /// size. Interruption safely restarts because each upsert is idempotent.
  func scheduleSemanticBackfill(
    modelIdentifier: String,
    expectedDimension: Int,
    expectedEncodingVersion: String
  ) {
    guard
      semanticEmbeddingService.availability(forStoredModelIdentifier: modelIdentifier) == .available
    else {
      return
    }
    let shouldSchedule: Bool
    let generation: Int
    semanticBackfillLock.lock()
    shouldSchedule =
      !backfilledSemanticModelIDs.contains(modelIdentifier)
      && inflightSemanticModelIDs.insert(modelIdentifier).inserted
    generation = semanticBackfillGeneration
    semanticBackfillLock.unlock()
    guard shouldSchedule else { return }

    let service = self
    let task = Task.detached(priority: .utility) {
      defer {
        service.finishSemanticBackfill(modelIdentifier, generation: generation)
      }
      do {
        let database = try service.database()
        var scanOffset = 0
        while !Task.isCancelled {
          let page = try database.semanticIndexRepairScanPage(
            modelIdentifier: modelIdentifier,
            expectedDimension: expectedDimension,
            expectedEncodingVersion: expectedEncodingVersion,
            offset: scanOffset,
            maximumScannedRecords: 24
          )
          if !page.records.isEmpty {
            let didWrite = try service.backfillSemanticRecords(
              page.records,
              database: database,
              modelIdentifier: modelIdentifier,
              expectedDimension: expectedDimension,
              expectedEncodingVersion: expectedEncodingVersion,
              generation: generation
            )
            guard didWrite else { return }
          }
          guard let nextOffset = page.nextOffset else {
            service.markSemanticBackfillComplete(
              modelIdentifier,
              generation: generation,
              cancelled: Task.isCancelled
            )
            return
          }
          scanOffset = nextOffset
        }
      } catch is CancellationError {
        return
      } catch {
        // Fail soft.  The repair query keeps outstanding rows visible for a
        // later scheduler invocation and the hash provider remains searchable.
        return
      }
    }
    semanticBackfillLock.lock()
    if semanticBackfillGeneration == generation,
      inflightSemanticModelIDs.contains(modelIdentifier),
      !task.isCancelled
    {
      semanticBackfillTasks[modelIdentifier] = task
    } else {
      task.cancel()
    }
    semanticBackfillLock.unlock()
  }

  /// Returns true only if a durable batch was written.  A provider that goes
  /// unavailable mid-run leaves rows repairable instead of replacing them with
  /// invalid data.
  func backfillSemanticRecords(
    _ records: [KnowledgeSemanticIndexRecord],
    database: KnowledgeDatabase,
    modelIdentifier: String,
    expectedDimension: Int,
    expectedEncodingVersion: String,
    generation: Int
  ) throws -> Bool {
    guard !records.isEmpty else { return false }
    var embeddings: [KnowledgeChunkEmbedding] = []
    embeddings.reserveCapacity(records.count)
    for record in records {
      try Task.checkCancellation()
      guard
        let vector = semanticEmbeddingService.vector(
          for: record.searchableText,
          modelIdentifier: modelIdentifier,
          role: .passage
        ), vector.values.count == expectedDimension,
        vector.encodingVersion == expectedEncodingVersion
      else { return false }
      embeddings.append(
        KnowledgeChunkEmbedding(
          chunkID: record.chunk.id,
          revisionID: record.chunk.revisionID,
          vector: vector,
          inputHash: record.searchableTextHash
        ))
    }
    while !semanticBackfillLock.lock(before: Date(timeIntervalSinceNow: 0.02)) {
      try Task.checkCancellation()
    }
    defer { semanticBackfillLock.unlock() }
    guard semanticBackfillGeneration == generation, !Task.isCancelled else {
      throw CancellationError()
    }
    try database.upsertSemanticEmbeddings(embeddings)
    return true
  }

  func repairSemanticVectorsSynchronously() throws -> KnowledgeSemanticRepairReport {
    try Task.checkCancellation()
    cancelSemanticBackfillTasks()
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }

    let database = try database()
    let records = try database.semanticIndexRecords()
    let rebuilt = try rebuiltSemanticEmbeddings(for: records)
    try database.replaceAllSemanticEmbeddings(
      rebuilt.embeddings,
      preservingModelIdentifiers: try temporarilyUnavailableStoredModelIdentifiers(database)
    )
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
    cancelSemanticBackfillTasks()
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }

    let database = try database()
    let records = try database.semanticIndexRecords().filter {
      documentIDs.contains($0.document.id)
    }
    let rebuilt = try rebuiltSemanticEmbeddings(for: records)
    try database.replaceSemanticEmbeddings(
      documentIDs: documentIDs,
      embeddings: rebuilt.embeddings,
      preservingModelIdentifiers: try temporarilyUnavailableStoredModelIdentifiers(database)
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
      let vectors = semanticEmbeddingService.vectors(for: record.searchableText, role: .passage)
      try Task.checkCancellation()
      for vector in vectors {
        modelIdentifiers.insert(vector.modelIdentifier)
        embeddings.append(
          KnowledgeChunkEmbedding(
            chunkID: record.chunk.id,
            revisionID: record.chunk.revisionID,
            vector: vector,
            inputHash: record.searchableTextHash
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
    cancelSemanticBackfillTasks()
  }

  func cancelSemanticBackfillTasks() {
    semanticBackfillLock.lock()
    semanticBackfillGeneration &+= 1
    let tasks = Array(semanticBackfillTasks.values)
    semanticBackfillTasks.removeAll()
    backfilledSemanticModelIDs.removeAll()
    inflightSemanticModelIDs.removeAll()
    semanticBackfillLock.unlock()
    for task in tasks {
      task.cancel()
    }
  }

  func finishSemanticBackfill(_ modelIdentifier: String, generation: Int) {
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }
    guard semanticBackfillGeneration == generation else { return }
    inflightSemanticModelIDs.remove(modelIdentifier)
    semanticBackfillTasks.removeValue(forKey: modelIdentifier)
  }

  func markSemanticBackfillComplete(
    _ modelIdentifier: String,
    generation: Int,
    cancelled: Bool
  ) {
    semanticBackfillLock.lock()
    defer { semanticBackfillLock.unlock() }
    guard semanticBackfillGeneration == generation, !cancelled else { return }
    backfilledSemanticModelIDs.insert(modelIdentifier)
  }

  func temporarilyUnavailableStoredModelIdentifiers(_ database: KnowledgeDatabase) throws -> Set<
    String
  > {
    Set(
      try database.semanticEmbeddingChunkIDsByModelIdentifier().keys.filter {
        semanticEmbeddingService.availability(forStoredModelIdentifier: $0)
          == .temporarilyUnavailable
      })
  }
}
