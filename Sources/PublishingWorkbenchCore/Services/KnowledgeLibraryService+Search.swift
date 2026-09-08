import Foundation
import PublishingCoreSupport
import PublishingKnowledgeCore

private enum KnowledgeSearchTokenSupport {
  static let tokenizer = LocalBPETokenizer(encoding: .o200kBase)
}

private struct KnowledgeQueryExcerptParagraph {
  let text: String
  let tokenCount: Int
  let firstMatch: Range<String.Index>?
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
      try checkSearchCancellation()
      guard citations.count < maximumCitations else { break }
      let currentDocumentCount = documentUseCounts[result.document.id, default: 0]
      guard currentDocumentCount < 2 else { continue }
      let remainingBudget = tokenBudget - usedTokens
      guard remainingBudget > 100 else { break }

      let maximumTokens = min(1_500, remainingBudget)
      let excerpt = try clippedToTokenBudget(
        result.chunk.content,
        query: query,
        maximumTokens: maximumTokens
      )
      try checkSearchCancellation()
      guard !excerpt.isEmpty else { continue }
      let estimatedTokens = max(1, KnowledgeSearchTokenSupport.tokenizer.tokenCount(excerpt))
      guard estimatedTokens <= remainingBudget else { continue }

      citations.append(
        KnowledgeCitation(
          id: "K\(citations.count + 1)",
          documentID: result.document.id,
          revisionID: result.chunk.revisionID,
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

  private func clippedToTokenBudget(
    _ text: String,
    query: String,
    maximumTokens: Int
  ) throws -> String {
    try checkSearchCancellation()
    guard maximumTokens > 0 else { return "" }
    let tokenizer = KnowledgeSearchTokenSupport.tokenizer
    guard tokenizer.tokenCount(text) > maximumTokens else { return text }

    let paragraphs =
      text
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard paragraphs.count >= 2 else {
      return try clippedParagraph(
        text,
        preferredRange: firstMatch(in: text, terms: queryTerms(in: query)),
        maximumTokens: maximumTokens
      )
    }

    let terms = queryTerms(in: query)
    let entries = try paragraphs.map { paragraph in
      try checkSearchCancellation()
      return KnowledgeQueryExcerptParagraph(
        text: paragraph,
        tokenCount: tokenizer.tokenCount(paragraph),
        firstMatch: firstMatch(in: paragraph, terms: terms)
      )
    }
    let hitIndexes = entries.indices.filter { entries[$0].firstMatch != nil }
    guard !hitIndexes.isEmpty else {
      // A semantic or title-only result has no lexical anchor in its chunk.
      // Keep a bounded beginning rather than pretending that an invented term
      // identifies a relevant passage.
      return try clippedParagraph(text, preferredRange: nil, maximumTokens: maximumTokens)
    }

    // Select hit paragraphs first. Dividing the remaining budget among the
    // remaining hits avoids allowing an early long paragraph to hide later,
    // independently matching passages.
    let omissionCost = tokenizer.tokenCount("\n…\n")
    var selected: [Int: String] = [:]
    var reservedTokens = 0
    for (offset, index) in hitIndexes.enumerated() {
      try checkSearchCancellation()
      let remainingHitCount = hitIndexes.count - offset
      let connectorCost = selected.isEmpty ? 0 : omissionCost
      let availableTokens = maximumTokens - reservedTokens - connectorCost
      guard availableTokens > 0 else { break }
      let allocation = max(1, availableTokens / remainingHitCount)
      let entry = entries[index]
      let excerpt: String
      if entry.tokenCount <= allocation {
        excerpt = entry.text
      } else {
        excerpt = try clippedParagraph(
          entry.text,
          preferredRange: entry.firstMatch,
          maximumTokens: allocation
        )
      }
      guard !excerpt.isEmpty else { continue }
      let excerptTokens = tokenizer.tokenCount(excerpt)
      guard excerptTokens + connectorCost <= maximumTokens - reservedTokens else { continue }
      selected[index] = excerpt
      reservedTokens += excerptTokens + connectorCost
    }

    // Then use any leftover capacity for nearby paragraphs. Distances are
    // computed with two linear passes so a dense document does not repeatedly
    // rescan all hits while assembling the prompt.
    let distances = distancesToNearestHit(in: entries.indices, hitIndexes: Set(hitIndexes))
    let nearbyIndexes = entries.indices
      .filter { selected[$0] == nil }
      .sorted {
        if distances[$0] == distances[$1] { return $0 < $1 }
        return distances[$0] < distances[$1]
      }
    for index in nearbyIndexes {
      try checkSearchCancellation()
      let connectorCost = selected.isEmpty ? 0 : omissionCost
      let entry = entries[index]
      guard entry.tokenCount + connectorCost <= maximumTokens - reservedTokens else { continue }
      selected[index] = entry.text
      reservedTokens += entry.tokenCount + connectorCost
    }

    let excerpt = assembledExcerpt(from: selected)
    guard tokenizer.tokenCount(excerpt) <= maximumTokens else {
      // The conservative per-part accounting above should keep this branch
      // unreachable. Keep the public budget guarantee if a future tokenizer
      // changes boundary behavior.
      let firstHit = entries[hitIndexes[0]]
      return try clippedParagraph(
        firstHit.text,
        preferredRange: firstHit.firstMatch,
        maximumTokens: maximumTokens
      )
    }
    return excerpt
  }

  private func queryTerms(in query: String) -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let tokens =
      trimmed
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
    var terms: [String] = []
    var normalized = Set<String>()
    for term in [trimmed] + tokens {
      let key = term.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
      guard normalized.insert(key).inserted else { continue }
      terms.append(term)
    }
    return terms.sorted { $0.count > $1.count }
  }

  private func firstMatch(in text: String, terms: [String]) -> Range<String.Index>? {
    terms.compactMap { term in
      text.range(
        of: term,
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
    }
    .min {
      text.distance(from: text.startIndex, to: $0.lowerBound)
        < text.distance(from: text.startIndex, to: $1.lowerBound)
    }
  }

  private func clippedParagraph(
    _ text: String,
    preferredRange: Range<String.Index>?,
    maximumTokens: Int
  ) throws -> String {
    try checkSearchCancellation()
    guard maximumTokens > 0 else { return "" }
    let tokenizer = KnowledgeSearchTokenSupport.tokenizer
    guard tokenizer.tokenCount(text) > maximumTokens else { return text }

    let characters = Array(text)
    guard !characters.isEmpty else { return "" }
    let preferredStart =
      preferredRange.map {
        text.distance(from: text.startIndex, to: $0.lowerBound)
      } ?? 0
    let preferredLength =
      preferredRange.map {
        text.distance(from: $0.lowerBound, to: $0.upperBound)
      } ?? 0
    var low = 1
    var high = characters.count
    var best = ""

    while low <= high {
      try checkSearchCancellation()
      let length = (low + high) / 2
      let unclampedStart = max(0, preferredStart - max(0, length - preferredLength) / 2)
      let end = min(characters.count, unclampedStart + length)
      let start = max(0, end - length)
      let prefix = start > 0 ? "…" : ""
      let suffix = end < characters.count ? "…" : ""
      let candidate = (prefix + String(characters[start..<end]) + suffix)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if tokenizer.tokenCount(candidate) <= maximumTokens {
        best = candidate
        low = length + 1
      } else {
        high = length - 1
      }
    }

    guard !best.isEmpty else { return "" }
    return best
  }

  private func distancesToNearestHit(
    in indexes: Range<Int>,
    hitIndexes: Set<Int>
  ) -> [Int] {
    var distances = Array(repeating: Int.max, count: indexes.count)
    var lastHit: Int?
    for index in indexes {
      if hitIndexes.contains(index) { lastHit = index }
      if let lastHit { distances[index] = index - lastHit }
    }
    lastHit = nil
    for index in indexes.reversed() {
      if hitIndexes.contains(index) { lastHit = index }
      if let lastHit { distances[index] = min(distances[index], lastHit - index) }
    }
    return distances
  }

  private func assembledExcerpt(from selected: [Int: String]) -> String {
    let indexes = selected.keys.sorted()
    var excerpt = ""
    var previousIndex: Int?
    for index in indexes {
      guard let text = selected[index] else { continue }
      if let previousIndex {
        excerpt += index == previousIndex + 1 ? "\n\n" : "\n…\n"
      }
      excerpt += text
      previousIndex = index
    }
    return excerpt
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
