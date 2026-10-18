import Foundation
import PublishingCoreSupport
import PublishingWorkbenchCore

/// Publishing commits and pushes the site's local Git repository, so it can
/// start only once that repository and its GitHub/GitLab identity are set.
enum PublishDrawerConnectionPresentation {
  static func isWorktreeConfigured(_ profile: SiteProfile) -> Bool {
    profile.localRepositoryRootURL != nil
      && !profile.repoOwner.trimmedForPublishing.isEmpty
      && !profile.repoName.trimmedForPublishing.isEmpty
  }
}

/// Status of the publishing connection shown beside an article's checks.
enum PublishConnectionStatus: Equatable { case pending, passed, warning, blocked, running }

enum PublishReadinessIssueGrouping {
  /// Coalesce the same actionable cause, retaining all distinct explanations
  /// and the strongest severity. Different paths and unclassified findings
  /// remain separate even when their titles happen to match.
  static func coalesced(_ issues: [PreflightIssue]) -> [PreflightIssue] {
    struct Key: Hashable {
      let code: PreflightIssueCode?
      let title: String
      let field: String?
      let relatedValue: String?
      let unclassifiedMessage: String?
    }
    var result: [PreflightIssue] = []
    var indices: [Key: Int] = [:]
    var messages: [Key: [String]] = [:]
    for issue in issues {
      let key = Key(
        code: issue.code, title: issue.title, field: issue.field, relatedValue: issue.relatedValue,
        unclassifiedMessage: issue.field == nil ? issue.message : nil)
      if let index = indices[key] {
        if !(messages[key] ?? []).contains(issue.message) {
          messages[key, default: []].append(issue.message)
          result[index].message = messages[key, default: []].joined(separator: "\n")
        }
        if issue.severity.sortRank < result[index].severity.sortRank {
          result[index].severity = issue.severity
        }
      } else {
        indices[key] = result.count
        messages[key] = [issue.message]
        result.append(issue)
      }
    }
    return result
  }
}

/// Values for the inspector only. These do not authorize a remote operation.
struct PublishDrawerReadinessIssue: Identifiable {
  let id: String
  let draftID: UUID?
  let target: PublishReadinessTarget
  let severity: PreflightSeverity
  var isOptionalOptimization: Bool = false
  let title: String
  let message: String

  var actionTitle: String {
    if case .metadata(field: "date") = target { return String(localized: "修改时间") }
    return target.title
  }

  var supportsAIFix: Bool {
    switch target {
    case .body, .seo: return true
    case .metadata(let field): return ["title", "slug", "summary", "tags"].contains(field ?? "")
    case .images, .repository: return false
    }
  }

  static func preflight(_ issue: PreflightIssue, draftID: UUID?, prefix: String) -> Self {
    Self(
      id: prefix + "-"
        + [issue.field ?? "", issue.relatedValue ?? "", issue.title, issue.message]
        .joined(separator: "|"),
      draftID: draftID,
      target: issue.structuredField == .body ? .body(query: issue.relatedValue) : .preflight(issue),
      severity: issue.severity,
      isOptionalOptimization: issue.isOptionalOptimization,
      title: issue.title, message: issue.message
    )
  }
}

struct PublishDrawerReadinessSection: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let issues: [PublishDrawerReadinessIssue]
  let isLoading: Bool
}

struct PublishDrawerReadinessPresentation {
  let sections: [PublishDrawerReadinessSection]
  /// The article has no preflight result yet, not even a previous one. Its
  /// other sections alone would be a partial count, so none is shown.
  var isAwaitingPreflight = false
  /// Optional findings hidden because 站点检查 is set to ignore them. They are
  /// neither listed nor counted, matching the health report.
  var ignoredCount = 0

  var issues: [PublishDrawerReadinessIssue] {
    sections.flatMap(\.issues).enumerated().sorted {
      if $0.element.severity.sortRank != $1.element.severity.sortRank {
        return $0.element.severity.sortRank < $1.element.severity.sortRank
      }
      return $0.offset < $1.offset
    }.map(\.element)
  }

  var blockingCount: Int {
    issues.count { $0.severity == .error }
  }
  var warningCount: Int {
    issues.count { $0.severity == .warning && !$0.isOptionalOptimization }
  }
  var optimizationCount: Int {
    issues.count { $0.isOptionalOptimization && $0.severity != .error }
  }
  var isLoading: Bool { sections.contains(where: \.isLoading) }
  var passedSections: [PublishDrawerReadinessSection] {
    sections.filter {
      !$0.isLoading
        && $0.issues.allSatisfy {
          $0.isOptionalOptimization || ($0.severity == .info)
        }
    }
  }

  static func article(
    draftID: UUID, preflightIssues: [PreflightIssue], imageReport: ImageWorkbenchReport?,
    isImageReportLoading: Bool, seoReport: SEOAuditReport,
    socialSnapshot: SEOSocialPreviewSnapshot?, isSocialPreviewStale: Bool,
    isPreflightLoading: Bool = false,
    isPreflightIssueIgnored: (PreflightIssue) -> Bool = { _ in false },
    isImageIssueIgnored: (ImageWorkbenchIssue) -> Bool = { _ in false }
  ) -> Self {
    func findings(_ items: [SEOAuditFinding], prefix: String) -> [PublishDrawerReadinessIssue] {
      items.filter { $0.severity != .info }.map {
        PublishDrawerReadinessIssue(
          id: prefix + "-" + [$0.field ?? "", $0.title, $0.message].joined(separator: "|"),
          draftID: draftID, target: .seo($0), severity: $0.severity,
          isOptionalOptimization: $0.isOptionalOptimization,
          title: $0.title, message: $0.message
        )
      }
    }
    // Ignored findings leave before coalescing; the listing order is unchanged.
    let ignoredPreflight = preflightIssues.filter {
      $0.severity != .info && !$0.isDeferredRemoteIssue && isPreflightIssueIgnored($0)
    }
    let preflight = PublishReadinessIssueGrouping.coalesced(
      preflightIssues.filter { !isPreflightIssueIgnored($0) }
    )
    .filter { $0.severity != .info && !$0.isDeferredRemoteIssue }
    .map { PublishDrawerReadinessIssue.preflight($0, draftID: draftID, prefix: "preflight") }
    // Coverage uses the complete preflight list: hiding an ignored preflight
    // finding must not resurface the image finding it already stands for.
    let listedImages =
      imageReport?.issues.filter {
        $0.severity != .info && !$0.isCovered(by: preflightIssues)
      } ?? []
    let visibleImages = listedImages.filter { !isImageIssueIgnored($0) }
    let ignoredCount = ignoredPreflight.count + (listedImages.count - visibleImages.count)
    let images =
      visibleImages.map {
        PublishDrawerReadinessIssue(
          id: "image-"
            + [
              $0.kind.rawValue, $0.attachmentID?.uuidString ?? "", $0.relatedValue ?? "", $0.title,
            ]
            .joined(separator: "|"),
          draftID: draftID, target: .image($0), severity: $0.severity,
          isOptionalOptimization: $0.isOptionalOptimization,
          title: $0.title, message: $0.message
        )
      }
    var social = findings(socialSnapshot?.findings ?? [], prefix: "social")
    if socialSnapshot == nil || isSocialPreviewStale {
      social.append(
        PublishDrawerReadinessIssue(
          id: "social-preview", draftID: draftID, target: .seo, severity: .warning,
          title: socialSnapshot == nil
            ? String(localized: "社交预览尚未生成") : String(localized: "社交预览需要刷新"),
          message: socialSnapshot == nil
            ? String(localized: "刷新社交预览后才能确认 Open Graph、Twitter/X 和 JSON-LD 字段。")
            : String(localized: "文章元数据已变化，当前卡片快照不是最新版本。")
        ))
    }
    return Self(
      sections: [
        .init(
          id: "preflight", title: String(localized: "发布前检查"), systemImage: "shield.checkered",
          issues: preflight, isLoading: isPreflightLoading),
        .init(
          id: "images", title: String(localized: "图片"), systemImage: "photo",
          issues: images, isLoading: isImageReportLoading && imageReport == nil),
        .init(
          id: "seo", title: "SEO", systemImage: "magnifyingglass",
          issues: findings(seoReport.findings, prefix: "seo"), isLoading: false),
        .init(
          id: "social", title: String(localized: "社交卡片"), systemImage: "rectangle.inset.filled",
          issues: social, isLoading: false),
      ],
      ignoredCount: ignoredCount
    )
  }

  static func batch(
    plan: BatchPublishPlan?, profileID: UUID, isRefreshing: Bool,
    isIssueIgnored: (UUID, PreflightIssue) -> Bool = { _, _ in false }
  ) -> Self {
    guard let plan, plan.profileID == profileID else {
      return Self(sections: [
        .init(
          id: "batch", title: String(localized: "应用文章检查"),
          systemImage: "doc.on.doc", issues: [], isLoading: true)
      ])
    }
    var ignoredCount = 0
    let sections: [PublishDrawerReadinessSection] =
      plan.items.filter { $0.changedFileCount > 0 }.map { item in
        let ignored = Set(
          item.allIssues.indices.filter { isIssueIgnored(item.draftID, item.allIssues[$0]) })
        ignoredCount += ignored.count {
          item.allIssues[$0].severity != .info && !item.allIssues[$0].isDeferredRemoteIssue
        }
        let remaining = item.allIssues.indices.filter { !ignored.contains($0) }
          .map { item.allIssues[$0] }
        return .init(
          id: item.draftID.uuidString, title: item.draftTitle, systemImage: "doc.text",
          issues: PublishReadinessIssueGrouping.coalesced(remaining)
            .filter { $0.severity != .info && !$0.isDeferredRemoteIssue }
            .map { .preflight($0, draftID: item.draftID, prefix: item.draftID.uuidString) },
          isLoading: isRefreshing)
      }
    return Self(sections: sections, ignoredCount: ignoredCount)
  }
}

/// The single definition of what still needs attention before one article is
/// published. The toolbar publish badge, the Inspector's 发布检查 tab and the
/// publish panel's current-article header all read this value, so the three
/// numbers cannot drift apart.
struct ArticlePublishAttention {
  typealias AccountPresentation = (detail: String, status: PublishConnectionStatus)

  let readiness: PublishDrawerReadinessPresentation
  let account: AccountPresentation

  var isAccountBlocked: Bool { account.status == .blocked }

  /// Blockers and actionable warnings, including a blocked publishing account.
  var pendingCount: Int {
    Self.pendingCount(readiness: readiness, accountStatus: account.status)
  }

  var meaningfulPendingCount: Int {
    pendingCount
  }

  static func pendingCount(
    readiness: PublishDrawerReadinessPresentation,
    accountStatus: PublishConnectionStatus
  ) -> Int {
    guard !readiness.isAwaitingPreflight else { return 0 }
    return readiness.blockingCount + readiness.warningCount + (accountStatus == .blocked ? 1 : 0)
  }

  /// Resolves the article the same way the publish panel does: general drafts
  /// and drafts of another site have no current-article publish checks.
  @MainActor
  static func make(store: WorkbenchStore, draftID: UUID?) -> Self? {
    guard
      let draft = PublishDrawerDraftPresentation.resolve(
        draftID: draftID, profileID: store.activeProfileID,
        draft: draftID.flatMap { store.draft(for: $0) })
    else { return nil }
    return make(store: store, draft: draft)
  }

  @MainActor
  static func make(store: WorkbenchStore, draft: ArticleDraft) -> Self {
    Self(
      readiness: readiness(store: store, draft: draft),
      account: account(profile: store.activeProfile)
    )
  }

  /// Rendering never starts preflight. While a refresh is pending (every
  /// edit invalidates the cache) the previous complete result stays visible,
  /// marked loading, so the count does not drop to the non-preflight items
  /// and jump back after each typing pause.
  @MainActor
  static func readiness(
    store: WorkbenchStore, draft: ArticleDraft
  ) -> PublishDrawerReadinessPresentation {
    let preflight = store.displayedPreflightResult(for: draft.id)
    let imageReport = store.cachedImageWorkbenchReport(for: draft)
    var presentation = PublishDrawerReadinessPresentation.article(
      draftID: draft.id,
      preflightIssues: preflight?.result.issues ?? [],
      imageReport: imageReport,
      isImageReportLoading: store.isImageWorkbenchReportLoading(for: draft),
      seoReport: store.seoReport(for: draft),
      socialSnapshot: store.seoSocialPreviewSnapshot(for: draft),
      isSocialPreviewStale: store.isSEOSocialPreviewStale(for: draft),
      isPreflightLoading: preflight?.isCurrent != true,
      isPreflightIssueIgnored: { store.isSuppressedInContentHealth($0, draft: draft) },
      isImageIssueIgnored: { issue in
        imageReport.map { store.isSuppressedInContentHealth(issue, report: $0, draft: draft) }
          ?? false
      }
    )
    presentation.isAwaitingPreflight = preflight == nil
    return presentation
  }

  /// Publishing needs the site's local repository and origin, not an API
  /// token; credentials are checked by Git itself when it pushes.
  static func account(profile: SiteProfile) -> AccountPresentation {
    PublishDrawerConnectionPresentation.isWorktreeConfigured(profile)
      ? (String(localized: "通过本地 Git 推送到 origin"), .passed)
      : (String(localized: "请先配置本地仓库与 origin，才能发布。"), .blocked)
  }
}

enum PublishDrawerDraftPresentation {
  static func resolve(draftID: UUID?, profileID: UUID, draft: ArticleDraft?) -> ArticleDraft? {
    guard let draftID, let draft, draft.id == draftID, draft.siteProfileID == profileID else {
      return nil
    }
    return draft
  }
}
