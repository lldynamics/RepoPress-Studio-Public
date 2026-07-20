import Foundation

public enum NativeHostLaunchArguments {
  public static func resolveSocketPath(
    arguments: [String],
    userID: UInt32
  ) -> String? {
    if arguments.isEmpty || isBrowserInvocation(arguments) {
      return KnowledgeNativeMessagingProtocol.unixSocketPath(userID: userID)
    }
    guard arguments.count == 2,
          arguments[0] == "--socket-path",
          arguments[1].hasPrefix("/"),
          arguments[1].utf8.count < 104 else {
      return nil
    }
    return arguments[1]
  }

  private static func isBrowserInvocation(_ arguments: [String]) -> Bool {
    if arguments.count == 1 {
      return KnowledgeNativeMessagingProtocol.chromeAllowedOrigins.contains(arguments[0])
        || KnowledgeNativeMessagingProtocol.edgeAllowedOrigins.contains(arguments[0])
    }

    guard arguments.count == 2,
          arguments[1] == KnowledgeNativeMessagingProtocol.firefoxExtensionID,
          arguments[0].hasPrefix("/") else {
      return false
    }
    return URL(fileURLWithPath: arguments[0]).lastPathComponent
      == "\(KnowledgeNativeMessagingProtocol.hostName).json"
  }
}
