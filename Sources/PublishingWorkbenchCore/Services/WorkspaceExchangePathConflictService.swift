import Foundation
import PublishingBackupCore
import PublishingDomainContracts

/// Checks the destination publish paths after the user has mapped source sites.
/// General drafts have no publish path until they are assigned to a site.
public enum WorkspaceExchangePathConflictService {
  public static func conflicts(
    package: WorkspaceExchangePackage,
    profileMappings: [UUID: WorkspaceExchangeProfileMapping],
    slugOverrides: [UUID: String] = [:],
    existingProfiles: [SiteProfile],
    existingDrafts: [ArticleDraft]
  ) throws -> [WorkspaceExchangePublishPathConflict] {
    let sourceDraftsByID = Dictionary(
      uniqueKeysWithValues: package.payload.drafts.map { ($0.id, $0) })
    guard slugOverrides.keys.allSatisfy({ sourceDraftsByID[$0]?.scope == "site" }) else {
      throw WorkspaceExchangeError.invalidReference("Slug 调整只能应用于包内站点草稿")
    }

    let sourceProfilesByID = Dictionary(
      uniqueKeysWithValues: package.payload.profiles.map { ($0.id, $0) })
    let existingProfilesByID = Dictionary(
      uniqueKeysWithValues: existingProfiles.map { ($0.id, $0) })
    let existingSiteDrafts = Dictionary(
      grouping: existingDrafts.compactMap { draft -> (UUID, ArticleDraft)? in
        guard case .site(let siteID) = draft.scope else { return nil }
        return (siteID, draft)
      }, by: { $0.0 })

    var candidates: [Candidate] = []
    candidates.reserveCapacity(package.payload.drafts.count)
    for sourceDraft in package.payload.drafts where sourceDraft.scope == "site" {
      guard let sourceProfileID = sourceDraft.sourceProfileID,
        let mapping = profileMappings[sourceProfileID]
      else {
        throw WorkspaceExchangeError.invalidReference("站点草稿缺少目标配置映射")
      }

      let destination: Destination
      let profile: SiteProfile
      switch mapping {
      case .existing(let destinationID):
        guard let existing = existingProfilesByID[destinationID] else {
          throw WorkspaceExchangeError.invalidReference("目标站点配置已不存在")
        }
        destination = .existing(destinationID)
        profile = existing
      case .importAsNewProfile:
        guard let source = sourceProfilesByID[sourceProfileID],
          let siteKind = SiteKind(rawValue: source.siteKind)
        else {
          throw WorkspaceExchangeError.invalidReference("来源站点配置无法重建")
        }
        destination = .new(sourceProfileID)
        profile = SiteProfile(
          id: sourceProfileID,
          name: source.name,
          siteKind: siteKind,
          repoOwner: source.repoOwner,
          repoName: source.repoName,
          branch: source.branch
        )
      }

      let slug = slugOverrides[sourceDraft.id] ?? sourceDraft.slug
      if slugOverrides[sourceDraft.id] != nil {
        guard slug == slug.trimmingCharacters(in: .whitespacesAndNewlines),
          !slug.contains("/"), !slug.contains("\\"),
          SlugService.isValid(slug, rule: profile.slugValidationRule)
        else { throw WorkspaceExchangeError.invalidSlug(slug) }
      }
      guard let visibility = ArticleVisibility(rawValue: sourceDraft.visibility) else {
        throw WorkspaceExchangeError.invalidFormat
      }
      let draft = ArticleDraft(
        id: sourceDraft.id,
        siteProfileID: profile.id,
        scope: .site(profile.id),
        title: sourceDraft.title,
        date: sourceDraft.date,
        slug: slug,
        visibility: visibility
      )
      candidates.append(
        Candidate(
          sourceDraftID: sourceDraft.id,
          title: sourceDraft.title,
          slug: slug,
          destination: destination,
          profileName: profile.name,
          path: profile.markdownPath(for: draft)
        ))
    }

    let incomingCounts = Dictionary(grouping: candidates, by: { $0.key }).mapValues(\.count)
    var existingPathsBySite: [UUID: Set<String>] = [:]
    for candidate in candidates {
      guard case .existing(let destinationID) = candidate.destination,
        existingPathsBySite[destinationID] == nil,
        let profile = existingProfilesByID[destinationID]
      else { continue }
      existingPathsBySite[destinationID] = Set(
        (existingSiteDrafts[destinationID] ?? []).map { candidate in
          profile.markdownPath(for: candidate.1).lowercased()
        }
      )
    }

    return candidates.compactMap { candidate in
      let collidesWithIncoming = (incomingCounts[candidate.key] ?? 0) > 1
      let collidesWithExisting: Bool
      switch candidate.destination {
      case .existing(let siteID):
        collidesWithExisting =
          existingPathsBySite[siteID]?.contains(candidate.path.lowercased()) == true
      case .new:
        collidesWithExisting = false
      }
      guard collidesWithIncoming || collidesWithExisting else { return nil }
      return WorkspaceExchangePublishPathConflict(
        sourceDraftID: candidate.sourceDraftID,
        title: candidate.title,
        slug: candidate.slug,
        destinationProfileName: candidate.profileName,
        path: candidate.path
      )
    }
    .sorted { $0.sourceDraftID.uuidString < $1.sourceDraftID.uuidString }
  }

  private enum Destination: Hashable {
    case existing(UUID)
    case new(UUID)
  }

  private struct Candidate {
    let sourceDraftID: UUID
    let title: String
    let slug: String
    let destination: Destination
    let profileName: String
    let path: String

    var key: Key { Key(destination: destination, path: path.lowercased()) }
  }

  private struct Key: Hashable {
    let destination: Destination
    let path: String
  }
}
