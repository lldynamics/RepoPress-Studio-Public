import Foundation

extension WorkbenchStore {
  public func siteAnalyticsSummary(for draft: ArticleDraft) -> SiteAnalyticsSummary? {
    siteAnalyticsSummaries[draft.id]
  }

  public func isSiteAnalyticsLoading(for draft: ArticleDraft) -> Bool {
    isSiteAnalyticsLoading && siteAnalyticsLoadingDraftID == draft.id
  }

  public func refreshSiteAnalyticsTokenAvailability(for profile: SiteProfile? = nil) {
    let profile = profile ?? activeProfile
    guard let settings = profile.siteAnalytics, settings.isEnabled else {
      siteAnalyticsTokenAvailability = KeychainTokenAvailability(hasToken: false)
      return
    }

    do {
      siteAnalyticsTokenAvailability = try siteAnalyticsTokenStore.availability(
        for: profile,
        scope: .analytics(settings.provider)
      )
    } catch {
      siteAnalyticsTokenAvailability = KeychainTokenAvailability(accessFailure: error)
    }
  }

  @discardableResult
  public func saveSiteAnalyticsAccessToken(_ token: String) -> Bool {
    let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedToken.isEmpty else {
      siteAnalyticsMessage = "请输入只读统计访问令牌。"
      return false
    }
    guard let settings = activeProfile.siteAnalytics, settings.isEnabled else {
      siteAnalyticsMessage = "请先启用阅读数据回流并保存站点配置。"
      return false
    }

    do {
      try siteAnalyticsTokenStore.saveToken(
        normalizedToken,
        for: activeProfile,
        scope: .analytics(settings.provider)
      )
      refreshSiteAnalyticsTokenAvailability()
      siteAnalyticsMessage = "阅读数据访问令牌已保存到钥匙串。"
      return true
    } catch {
      siteAnalyticsMessage = "阅读数据访问令牌保存失败：\(error.localizedDescription)"
      refreshSiteAnalyticsTokenAvailability()
      return false
    }
  }

  public func deleteSiteAnalyticsAccessToken() {
    guard let settings = activeProfile.siteAnalytics else {
      refreshSiteAnalyticsTokenAvailability()
      return
    }

    do {
      try siteAnalyticsTokenStore.deleteToken(
        for: activeProfile,
        scope: .analytics(settings.provider)
      )
      siteAnalyticsMessage = "阅读数据访问令牌已从钥匙串删除。"
    } catch {
      siteAnalyticsMessage = "阅读数据访问令牌删除失败：\(error.localizedDescription)"
    }
    refreshSiteAnalyticsTokenAvailability()
  }

  public func refreshSiteAnalytics(for draft: ArticleDraft) {
    siteAnalyticsRefreshTask?.cancel()
    siteAnalyticsRefreshRequestID = UUID()
    let requestID = siteAnalyticsRefreshRequestID
    siteAnalyticsLoadingDraftID = draft.id
    siteAnalyticsMessage = nil

    let profile = profile(for: draft)
    guard let settings = profile.siteAnalytics, settings.isEnabled else {
      siteAnalyticsLoadingDraftID = nil
      isSiteAnalyticsLoading = false
      siteAnalyticsMessage = "尚未配置阅读数据回流。可在“设置 → 仓库与部署 → 阅读数据”中启用。"
      return
    }
    guard let configuration = settings.configuration else {
      siteAnalyticsLoadingDraftID = nil
      isSiteAnalyticsLoading = false
      siteAnalyticsMessage = "阅读数据配置尚未完整，请检查统计接口和 Site ID。"
      return
    }

    let token: String?
    do {
      token = try siteAnalyticsTokenStore.token(
        for: profile,
        scope: .analytics(settings.provider)
      )
    } catch {
      siteAnalyticsLoadingDraftID = nil
      isSiteAnalyticsLoading = false
      siteAnalyticsMessage = "无法读取阅读数据访问令牌：\(error.localizedDescription)"
      refreshSiteAnalyticsTokenAvailability(for: profile)
      return
    }
    guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      siteAnalyticsLoadingDraftID = nil
      isSiteAnalyticsLoading = false
      siteAnalyticsTokenAvailability = KeychainTokenAvailability(hasToken: false)
      siteAnalyticsMessage = "尚未保存阅读数据访问令牌。可在设置中保存只读 Token。"
      return
    }

    let now = Date()
    let latestReleaseDate = releaseRecords
      .filter { $0.draftID == draft.id && $0.siteProfileID == profile.id }
      .map(\.createdAt)
      .max() ?? draft.date
    let requestedStart = now.addingTimeInterval(
      -TimeInterval(settings.normalizedDateRangeDays) * 24 * 60 * 60
    )
    let rangeStart = min(max(requestedStart, latestReleaseDate), now.addingTimeInterval(-60))
    let dateRange = SiteAnalyticsDateRange(start: rangeStart, end: now)
    let pagePath = SiteArticleURLResolver().relativeWebPath(
      from: profile.markdownPath(for: draft),
      siteKind: profile.siteKind
    )
    let service = siteAnalyticsService
    isSiteAnalyticsLoading = true

    siteAnalyticsRefreshTask = Task { [weak self] in
      do {
        let summary = try await service.fetchSummary(
          configuration: configuration,
          accessToken: token,
          dateRange: dateRange,
          pagePath: pagePath
        )
        guard !Task.isCancelled, let self, self.siteAnalyticsRefreshRequestID == requestID else {
          return
        }
        self.siteAnalyticsSummaries[draft.id] = summary
        self.siteAnalyticsMessage = "已刷新「\(draft.title.nilIfEmpty ?? "当前文章")」的阅读数据。"
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.siteAnalyticsRefreshRequestID == requestID else {
          return
        }
        self.siteAnalyticsMessage = "阅读数据刷新失败：\(error.localizedDescription)"
      }

      guard let self, self.siteAnalyticsRefreshRequestID == requestID else {
        return
      }
      self.isSiteAnalyticsLoading = false
      self.siteAnalyticsLoadingDraftID = nil
      self.siteAnalyticsRefreshTask = nil
    }
  }
}
