extension SiteProfile {
  public var resolvedWarnsWhenBodyH1DuplicatesTitle: Bool {
    get {
      warnsWhenBodyH1DuplicatesTitle
        ?? ThemeTitleH1Detector.cachedRendersTitleAsH1(profile: self)
        ?? true
    }
    set { warnsWhenBodyH1DuplicatesTitle = newValue }
  }
}
