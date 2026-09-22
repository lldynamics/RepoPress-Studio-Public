import Foundation

/// Validation shared by AI suggestion application entry points. Suggestions
/// are only safe to apply when the draft, editor buffer, and site profile are
/// still the versions that produced them.
enum AIApplicationContract {
  static func draftStillMatches(
    baseline: DraftOperationBaseline,
    profile: SiteProfile,
    currentDraft: ArticleDraft?,
    currentProfile: SiteProfile,
    bodyBuffer: DraftBodyEditorBuffer
  ) -> Bool {
    guard let currentDraft,
      !bodyBuffer.isDirty,
      bodyBuffer.revision == baseline.bodyRevision
    else {
      return false
    }

    var baselineDraft = baseline.draft
    var normalizedCurrentDraft = currentDraft
    _ = baselineDraft.storeWordCount(0, for: baselineDraft.bodyMarkdown)
    _ = normalizedCurrentDraft.storeWordCount(0, for: normalizedCurrentDraft.bodyMarkdown)
    return normalizedCurrentDraft == baselineDraft && currentProfile == profile
  }

  /// A metadata panel may apply one field from a multi-field suggestion. Each
  /// supplied value must nevertheless come from the retained suggestion.
  static func metadataSuggestion(
    _ proposal: AIPublishingMetadataSuggestion,
    belongsTo retained: AIPublishingMetadataSuggestion
  ) -> Bool {
    proposal.titles.allSatisfy(retained.titles.contains)
      && proposal.slugs.allSatisfy { proposalSlug in
        let normalizedProposal = SlugService.slug(
          from:
            proposalSlug
            .replacingOccurrences(of: ".markdown", with: "")
            .replacingOccurrences(of: ".md", with: "")
        )
        return retained.slugs.contains { retainedSlug in
          SlugService.slug(
            from:
              retainedSlug
              .replacingOccurrences(of: ".markdown", with: "")
              .replacingOccurrences(of: ".md", with: "")) == normalizedProposal
        }
      }
      && (proposal.summary == nil || proposal.summary == retained.summary)
      && AIPublishingMetadataSuggestionParser.parseTagCandidates(
        proposal.tags.joined(separator: "\n")
      )
      .allSatisfy(
        AIPublishingMetadataSuggestionParser.parseTagCandidates(
          retained.tags.joined(separator: "\n")
        ).contains)
  }

  static func imageTextSuggestions(
    _ proposals: [AIPublishingImageTextSuggestion],
    belongTo retained: [AIPublishingImageTextSuggestion]
  ) -> Bool {
    let proposedIDs = proposals.map(\.id)
    guard Set(proposedIDs).count == proposedIDs.count else { return false }
    return proposals.allSatisfy { proposal in
      retained.first { $0.id == proposal.id } == proposal
    }
  }
}
