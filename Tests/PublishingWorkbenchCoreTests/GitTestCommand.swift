import Foundation

@discardableResult
internal func gitTestCommand(
  _ arguments: [String],
  rootURL: URL,
  errorDomain: String
) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-C", rootURL.path] + arguments

  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe

  try process.run()
  process.waitUntilExit()

  let output =
    String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  let error =
    String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  guard process.terminationStatus == 0 else {
    throw NSError(
      domain: errorDomain,
      code: Int(process.terminationStatus),
      userInfo: [NSLocalizedDescriptionKey: output + error]
    )
  }
  return output.trimmingCharacters(in: .whitespacesAndNewlines)
}
