import Foundation
import PublishingGitCore

extension LocalRepositoryService {
  public func releaseHistory(
    profile: SiteProfile,
    request: RepositoryReleaseHistoryRequest = .init()
  ) -> RepositoryReleaseHistorySnapshot {
    guard let snapshot = profile.withLocalRepositoryRootAccess({ rootURL in
      releaseHistory(rootURL: rootURL, request: request)
    }) else {
      return RepositoryReleaseHistorySnapshot(
        historyAvailability: .unavailable,
        notesAvailability: .unavailable,
        diagnostics: [
          RepositoryReleaseHistoryDiagnostic(
            message: "No local repository is configured for the active site.",
            source: "repository"
          )
        ]
      )
    }
    return snapshot
  }

  func releaseHistory(
    rootURL: URL,
    request: RepositoryReleaseHistoryRequest
  ) -> RepositoryReleaseHistorySnapshot {
    let gitMarkerURL = rootURL.appendingPathComponent(".git", isDirectory: false)
    guard fileManager.fileExists(atPath: gitMarkerURL.path) else {
      return RepositoryReleaseHistorySnapshot(
        historyAvailability: .unavailable,
        notesAvailability: .unavailable,
        diagnostics: [
          RepositoryReleaseHistoryDiagnostic(
            message: "The selected directory is not itself a Git repository.",
            source: "repository"
          )
        ]
      )
    }

    let repositoryResult = gitCommandRunner.run(
      ["rev-parse", "--is-inside-work-tree"],
      rootURL: rootURL
    )
    guard repositoryResult.terminationStatus == 0,
          repositoryResult.standardOutput.trimmedForPublishing == "true" else {
      return unavailableReleaseHistory(
        source: "repository",
        result: repositoryResult,
        fallbackMessage: "Git could not verify the selected repository."
      )
    }

    let headResult = gitCommandRunner.run(
      ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
      rootURL: rootURL
    )
    guard headResult.terminationStatus == 0 else {
      if !headResult.didTimeOut,
         headResult.terminationStatus == 1 || headResult.terminationStatus == 128 {
        return RepositoryReleaseHistorySnapshot(
          historyAvailability: .available,
          notesAvailability: .unavailable,
          diagnostics: [],
          shallow: false
        )
      }
      return unavailableReleaseHistory(
        source: "history",
        result: headResult,
        fallbackMessage: "Git could not resolve the repository HEAD."
      )
    }

    let plan = RepositoryReleaseHistoryCommandPolicy().plan(request: request)
    let commitResult = gitCommandRunner.run(plan.commitArguments, rootURL: rootURL)
    let tagResult = gitCommandRunner.run(plan.tagArguments, rootURL: rootURL)
    let shallowResult = gitCommandRunner.run(
      ["rev-parse", "--is-shallow-repository"],
      rootURL: rootURL
    )
    let notesReferenceResult = gitCommandRunner.run(
      ["show-ref", "--verify", "--quiet", RepositoryReleaseHistoryCommandPlan.notesReference],
      rootURL: rootURL
    )

    let parser = RepositoryReleaseHistoryParser()
    var snapshot = parser.parse(
      commitResult: commitResult,
      tagResult: tagResult,
      request: request,
      shallowResult: shallowResult,
      fallbackDate: Date(timeIntervalSince1970: 0)
    )

    guard notesReferenceResult.terminationStatus == 0 else {
      if notesReferenceResult.terminationStatus == 1, !notesReferenceResult.didTimeOut {
        snapshot.notesAvailability = .unavailable
      } else {
        snapshot.notesAvailability = .unknown
        snapshot.partial = true
        snapshot.diagnostics.append(
          releaseHistoryDiagnostic(
            source: "notes",
            result: notesReferenceResult,
            fallbackMessage: "Git could not inspect the RepoPress release-notes ref."
          )
        )
      }
      return snapshot
    }

    let notesListResult = gitCommandRunner.run(plan.notesArguments, rootURL: rootURL)
    guard notesListResult.terminationStatus == 0 else {
      snapshot.notesAvailability = .unknown
      snapshot.partial = true
      snapshot.diagnostics.append(
        releaseHistoryDiagnostic(
          source: "notes",
          result: notesListResult,
          fallbackMessage: "Git could not list RepoPress release notes."
        )
      )
      return snapshot
    }

    let notedCommitSHAs = releaseNoteCommitSHAs(in: notesListResult.standardOutput)
    var notes: [RepositoryReleaseNote] = []
    var noteDiagnostics: [RepositoryReleaseHistoryDiagnostic] = []
    for commit in snapshot.commits where notedCommitSHAs.contains(commit.sha.lowercased()) {
      guard let arguments = plan.noteShowArguments(for: commit.sha) else { continue }
      let result = gitCommandRunner.run(arguments, rootURL: rootURL)
      guard result.terminationStatus == 0 else {
        noteDiagnostics.append(
          releaseHistoryDiagnostic(
            source: "notes",
            result: result,
            fallbackMessage: "Git could not read a RepoPress release note."
          )
        )
        continue
      }
      let parsed = parser.parseNoteOutput(
        "\(commit.sha)\0\(result.standardOutput)\0\0"
      )
      notes.append(contentsOf: parsed.notes)
      noteDiagnostics.append(contentsOf: parsed.diagnostics)
    }

    snapshot.notes = notes
    snapshot.notesAvailability = noteDiagnostics.isEmpty ? .available : .unknown
    snapshot.partial = snapshot.partial || !noteDiagnostics.isEmpty
    snapshot.diagnostics.append(contentsOf: noteDiagnostics)
    return snapshot
  }

  private func releaseNoteCommitSHAs(in output: String) -> Set<String> {
    Set(
      output
        .split(whereSeparator: \Character.isWhitespace)
        .map(String.init)
        .enumerated()
        .compactMap { index, value in
          guard index.isMultiple(of: 2) == false,
                RepositoryReleaseHistoryRequest.isValidCursor(value) else {
            return nil
          }
          return value.lowercased()
        }
    )
  }

  private func unavailableReleaseHistory(
    source: String,
    result: GitCommandResult,
    fallbackMessage: String
  ) -> RepositoryReleaseHistorySnapshot {
    RepositoryReleaseHistorySnapshot(
      historyAvailability: .unknown,
      notesAvailability: .unknown,
      diagnostics: [
        releaseHistoryDiagnostic(
          source: source,
          result: result,
          fallbackMessage: fallbackMessage
        )
      ],
      partial: true
    )
  }

  private func releaseHistoryDiagnostic(
    source: String,
    result: GitCommandResult,
    fallbackMessage: String
  ) -> RepositoryReleaseHistoryDiagnostic {
    let output = result.output.trimmedForPublishing
    return RepositoryReleaseHistoryDiagnostic(
      message: output.isEmpty ? fallbackMessage : output,
      source: source,
      terminationStatus: result.terminationStatus
    )
  }
}
