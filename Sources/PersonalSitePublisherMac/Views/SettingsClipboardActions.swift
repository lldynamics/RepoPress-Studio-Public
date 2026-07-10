struct SettingsClipboardActions {
  static func copy(
    _ value: String,
    successMessage: String,
    setMessage: @escaping (String) -> Void
  ) {
    ClipboardWriter.copy(value, successMessage: successMessage) { message in
      setMessage(message)
    }
  }
}
