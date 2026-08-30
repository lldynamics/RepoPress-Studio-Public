import PublishingWorkbenchCore
import SwiftUI

struct RepositoryWorkspaceGitManagementSection: View {
  let store: WorkbenchStore
  @ObservedObject private var workspaceObservation:
    WorkbenchRepositoryWorkspaceObservationFacade
  @State private var isExpanded = false
  @State private var newBranchName = ""
  @State private var showAllCommits = false
  @State private var showAllBranches = false
  @State private var branchSearchQuery = ""

  init(store: WorkbenchStore) {
    self.store = store
    _workspaceObservation = ObservedObject(
      wrappedValue: store.repositoryWorkspaceObservation
    )
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        branchSummary
        Divider()
        branchList
        Divider()
        newBranchControls
        if let branchActionUnavailableReason {
          Text(branchActionUnavailableReason)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Divider()
        commitHistory
      }
      .padding(.top, 10)
    } label: {
      Label("分支管理", systemImage: "arrow.triangle.branch")
        .font(.headline)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-git-management")
  }

  private var branchSummary: some View {
    VStack(alignment: .leading, spacing: 8) {
      repositoryInfoRow(
        title: "当前分支",
        value: currentBranch,
        systemImage: "pin.circle"
      )
      Divider()
      repositoryInfoRow(
        title: "目标分支",
        value: store.activeProfile.branch.nilIfEmpty ?? String(localized: "未配置"),
        systemImage: "flag"
      )
      Divider()
      repositoryInfoRow(
        title: "上游",
        value: currentBranchUpstream ?? String(localized: "未配置"),
        systemImage: "link"
      )

      Text("切换或新建分支前，工作区必须没有未提交变更；成功后会同步更新发布目标。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineSpacing(1)
    }
  }

  @ViewBuilder
  private var branchList: some View {
    if store.localRepositoryBranches.isEmpty {
      Text("未检测到可用分支。")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("本地工作分支")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          if store.localRepositoryBranches.count > 6 {
            Text("共 \(store.localRepositoryBranches.count) 个")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if showAllBranches {
          TextField("搜索分支...", text: $branchSearchQuery)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .accessibilityLabel("搜索本地分支")

          let query = branchSearchQuery.trimmedForPublishing
          let filtered = store.localRepositoryBranches.filter { branch in
            query.isEmpty || branch.name.localizedCaseInsensitiveContains(query)
          }

          if filtered.isEmpty {
            Text("未找到匹配的分支。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.vertical, 4)
          } else {
            ScrollView {
              VStack(alignment: .leading, spacing: 5) {
                ForEach(filtered) { branch in
                  branchRow(for: branch)
                }
              }
              .padding(.vertical, 2)
            }
            .frame(maxHeight: 180)
          }

          Button("收起完整分支列表") {
            showAllBranches = false
            branchSearchQuery = ""
          }
          .buttonStyle(.borderless)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.documentForeground)
          .padding(.top, 2)
        } else {
          ForEach(Array(store.localRepositoryBranches.prefix(6))) { branch in
            branchRow(for: branch)
          }

          if store.localRepositoryBranches.count > 6 {
            Button("展开更多分支并搜索（共 \(store.localRepositoryBranches.count) 个）") {
              showAllBranches = true
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.documentForeground)
            .padding(.top, 2)
            .accessibilityIdentifier("repository-git-management-expand-branches")
          }
        }
      }
    }
  }

  private func branchRow(for branch: RepositoryBranch) -> some View {
    HStack {
      Text(branch.name)
        .font(.caption.monospaced())
        .workbenchTruncatedIdentity(branch.name)
      Spacer()
      if branch.isCurrent {
        Label("当前", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.navigationSelection)
      } else {
        Button("切换") {
          Task {
            await switchBranch(to: branch.name)
          }
        }
        .controlSize(.small)
        .disabled(!canRunBranchOperation)
        .help(branchActionUnavailableReason ?? switchBranchLabel(branch.name))
        .accessibilityLabel(switchBranchLabel(branch.name))
      }
    }
  }

  private var newBranchControls: some View {
    HStack {
      TextField("新建分支名", text: $newBranchName)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("新建分支名")
        .accessibilityValue(newBranchName.isEmpty ? String(localized: "未填写") : newBranchName)

      Button {
        Task {
          await createAndSwitchBranch()
        }
      } label: {
        if store.isLocalRepositoryBranchOperationRunning {
          Label("处理中", systemImage: "hourglass")
        } else {
          Text("创建并切换")
        }
      }
      .controlSize(.small)
      .disabled(
        newBranchName.trimmedForPublishing.isEmpty
          || !canRunBranchOperation
      )
      .help(branchActionUnavailableReason ?? String(localized: "创建并切换"))
      .accessibilityLabel("创建并切换到新分支")
    }
  }

  private var commitHistory: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("提交历史", systemImage: "clock.arrow.circlepath")
        .font(.caption.weight(.semibold))

      if store.localRepositoryRecentCommits.isEmpty {
        Text("未查询到提交记录。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        let defaultCount = 6
        let displayCount = min(
          showAllCommits ? store.localRepositoryRecentCommits.count : defaultCount,
          store.localRepositoryRecentCommits.count
        )
        let displayCommits = Array(store.localRepositoryRecentCommits.prefix(displayCount))

        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(displayCommits.enumerated()), id: \.offset) { index, commit in
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .top, spacing: 6) {
                Text(commit.shortSHA)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(commit.message)
                  .font(.caption.weight(.medium))
                  .workbenchTruncatedIdentity(commit.message)
                Spacer(minLength: 0)
              }
              Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if index != displayCommits.count - 1 {
              Divider()
            }
          }

          if store.localRepositoryRecentCommits.count > defaultCount {
            Button(showAllCommits ? String(localized: "收起") : String(localized: "显示更多")) {
              showAllCommits.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.documentForeground)
            .padding(.top, 4)
            .accessibilityLabel(
              showAllCommits ? String(localized: "收起提交历史") : String(localized: "显示更多提交历史")
            )
          }
        }
      }
    }
  }

  private var currentBranch: String {
    store.repositoryReport?.branchStatus?.branchName
      ?? store.localRepositoryBranches.first(where: \.isCurrent)?.name
      ?? String(localized: "未识别")
  }

  private var currentBranchUpstream: String? {
    store.localRepositoryBranches.first(where: \.isCurrent)?.upstreamName
      ?? store.repositoryReport?.branchStatus?.upstreamName
  }

  private var hasUsableGitRepository: Bool {
    !store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty
      && store.repositoryReport?.hasGitDirectory == true
  }

  private var canRunBranchOperation: Bool {
    hasUsableGitRepository
      && !store.repository.scanState.isScanning
      && !store.isLocalRepositoryBranchOperationRunning
  }

  private var branchActionUnavailableReason: String? {
    if store.activeProfile.localRepositoryRootPath.trimmedForPublishing.isEmpty {
      return String(localized: "请先选择站点文件夹")
    }
    if store.repository.scanState.isScanning {
      return String(localized: "正在扫描仓库")
    }
    if store.repositoryReport?.hasGitDirectory != true {
      return String(localized: "未检测到可用分支。")
    }
    if store.isLocalRepositoryBranchOperationRunning {
      return String(localized: "正在处理分支")
    }
    return nil
  }

  private func repositoryInfoRow(
    title: LocalizedStringKey,
    value: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      Text(title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(value)
        .workbenchTruncatedIdentity(value)
    }
    .font(.caption)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(title))
    .accessibilityValue(value)
  }

  private func switchBranchLabel(_ branchName: String) -> String {
    String.localizedStringWithFormat(
      String(localized: "切换到 %@"),
      branchName
    )
  }

  @MainActor
  private func createAndSwitchBranch() async {
    guard canRunBranchOperation else { return }
    let branchName = newBranchName
    await store.createAndSwitchActiveProfileRepositoryBranch(name: branchName)
    if store.activeProfile.branch == branchName.trimmedForPublishing {
      newBranchName = ""
    }
  }

  @MainActor
  private func switchBranch(to branchName: String) async {
    guard canRunBranchOperation else { return }
    await store.switchActiveProfileRepositoryBranch(to: branchName)
  }
}
