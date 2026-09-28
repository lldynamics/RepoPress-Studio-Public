/// Named idle windows shared by production scheduling and clock-driven tests.
/// Keep different interaction contracts separate even when their durations match.
public enum DebounceIntervals {
  public static let markdownBindingFlush: Duration = .milliseconds(240)
  public static let markdownFindMatches: Duration = .milliseconds(120)
  public static let commandPaletteArticles: Duration = .milliseconds(140)
  public static let commandPaletteContent: Duration = .milliseconds(180)
  public static let knowledgeContextQuery: Duration = .milliseconds(420)
  public static let preflightRefresh: Duration = .milliseconds(600)
}
