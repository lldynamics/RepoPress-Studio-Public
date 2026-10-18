import Foundation

extension WorkbenchStore {
  public func setSEOThemeProvidesTitleH1(
    _ providesTitleH1: Bool?,
    forProfileID profileID: UUID
  ) {
    updateSEOProfile(profileID: profileID) { profile in
      profile.themeProvidesTitleH1 = providesTitleH1
    }
  }

  public func setSEODefaultSocialImagePath(
    _ path: String,
    forProfileID profileID: UUID
  ) {
    updateSEOProfile(profileID: profileID) { profile in
      profile.defaultSocialImagePath = path.isEmpty ? nil : path
    }
  }

  public func setSEODefaultSocialImageAltText(
    _ altText: String,
    forProfileID profileID: UUID
  ) {
    updateSEOProfile(profileID: profileID) { profile in
      profile.defaultSocialImageAltText = altText.isEmpty ? nil : altText
    }
  }

  @discardableResult
  public func setSEOArticleSocialImageIntent(
    _ intent: SEOArticleSocialImageIntent?,
    draftID: UUID,
    profileID: UUID
  ) -> Bool {
    guard
      drafts.contains(where: {
        $0.id == draftID && $0.belongs(toSiteProfileID: profileID)
      })
    else { return false }

    return updateSEOProfile(profileID: profileID) { profile in
      var preferences = profile.seoArticleSocialImagePreferences ?? []
      preferences.removeAll { $0.draftID == draftID }
      if let intent {
        preferences.append(
          SEOArticleSocialImagePreference(draftID: draftID, intent: intent)
        )
      }
      preferences.sort { $0.draftID.uuidString < $1.draftID.uuidString }
      profile.seoArticleSocialImagePreferences = preferences.isEmpty ? nil : preferences
    }
  }

  @discardableResult
  private func updateSEOProfile(
    profileID: UUID,
    update: (inout SiteProfile) -> Void
  ) -> Bool {
    guard let index = publishingStore.profiles.firstIndex(where: { $0.id == profileID }) else {
      return false
    }
    update(&publishingStore.profiles[index])
    invalidateDraftDerivedCaches()
    save()
    return true
  }
}
