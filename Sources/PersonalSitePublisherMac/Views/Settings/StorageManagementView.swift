import AppKit
import PublishingBackupCore
import Dispatch
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

enum StorageManagementPresentation {
  case standalone
  case embedded
}

enum StorageManagementScope {
  case all
  case storageAndCleanup
  case backupAndRestore
}

private enum SelectiveBackupDestination: String, CaseIterable, Identifiable {
  case local
  case iCloud

  var id: String { rawValue }
  var title: String {
    switch self {
    case .local: return String(localized: "本机")
    case .iCloud: return String(localized: "iCloud 云盘")
    }
  }
}

@MainActor
struct StorageManagementView: View {
  private let workbenchStore: WorkbenchStore
  @ObservedObject private var dataManagement: WorkbenchDataManagementFeatureFacade
  @ObservedObject var rssStore: RSSReaderStore
  @ObservedObject var coordinator: WorkbenchLaunchCoordinator
  @ObservedObject var backupScheduler: WorkspaceBackupScheduler
  let presentation: StorageManagementPresentation
  let scope: StorageManagementScope

  @AppStorage(RSSReaderStore.retentionDaysDefaultsKey)
  private var retentionDays = RSSReaderStore.defaultRetentionDays
  @State private var usageSnapshot: WorkbenchStorageUsageSnapshot?
  @State private var usageError: String?
  @State private var isLoadingUsage = false
  @State private var isCleaningKnowledge = false
  @State private var isKnowledgeCleanupConfirmationPresented = false
  @State private var isRSSCleanupConfirmationPresented = false
  @State private var pendingRelocationParentURL: URL?
  @State private var isRelocationConfirmationPresented = false
  @State private var isRelocating = false
  @State private var workspaceBackupPreview: WorkspaceBackupPreview?
  @State private var knowledgeBackupPreview: KnowledgeLibraryBackupPreview?
  @State private var operationMessage: String?
  @State private var operationError: String?
  @State private var selectedBackupCategories = Set(WorkspaceBackupCategory.allCases)
  @State private var backupDestination: SelectiveBackupDestination = .local
  @State private var isCreatingSelectiveBackup = false
  @State private var cloudBackupItems: [iCloudWorkspaceBackupStore.Item] = []
  @State private var isLoadingCloudBackup = false
  @State private var isResolvingAutomaticICloudDestination = false
  @State private var automaticBackupAvailableCapacity: Int64?
  @State private var isHistoryRetentionDowngradeConfirmationPresented = false
  @State private var selectiveRestorePreview: WorkspaceBackupSelectiveRestorePreview?
  @State private var isSelectiveRestorePreviewPresented = false
  @State private var selectiveRestoreStagingDirectory: URL?
  @State private var workspaceExchangePreview: WorkspaceExchangePreview?
  @State private var isExchangingWorkspace = false

  init(
    store: WorkbenchStore,
    rssStore: RSSReaderStore,
    coordinator: WorkbenchLaunchCoordinator,
    backupScheduler: WorkspaceBackupScheduler,
    presentation: StorageManagementPresentation = .standalone,
    scope: StorageManagementScope = .all
  ) {
    self.workbenchStore = store
    _dataManagement = ObservedObject(wrappedValue: store.dataManagement)
    self.rssStore = rssStore
    self.coordinator = coordinator
    self.backupScheduler = backupScheduler
    self.presentation = presentation
    self.scope = scope
  }

  var body: some View {
    Group {
      if presentation == .embedded {
        storageSections
      } else {
        Form {
          storageSections
        }
        .formStyle(.grouped)
        .padding(WorkbenchSpacing.content)
      }
    }
    .task(id: coordinator.dataRootPath) {
      await refreshUsage()
      await backupScheduler.refreshRecentBackups()
      refreshAutomaticBackupCapacity()
    }
    .sheet(item: $workspaceBackupPreview) { preview in
      WorkspaceBackupRestorePreviewView(
        preview: preview,
        dataManagement: dataManagement,
        stageWorkspaceBackupRestore: { backupURL in
          await dataManagement.stageWorkspaceBackupRestore(from: backupURL)
        }
      )
    }
    .sheet(item: $knowledgeBackupPreview) { preview in
      KnowledgeLibraryRestorePreviewView(knowledge: dataManagement.knowledge, preview: preview)
    }
    .sheet(item: $workspaceExchangePreview) { preview in
      WorkspaceExchangeRestorePreviewSheet(preview: preview, store: workbenchStore) { count in
        operationMessage = String(localized: "已将 \(count.formatted()) 篇文章作为新草稿导入。")
      }
    }
    .alert(
      String(localized: "清空资料库回收站？"),
      isPresented: $isKnowledgeCleanupConfirmationPresented
    ) {
      Button(String(localized: "永久删除"), role: .destructive) {
        cleanKnowledgeRecycleBin()
      }
      Button(String(localized: "取消"), role: .cancel) {}
    } message: {
      Text("回收站中的资料、检索索引和应用内保存的本地副本将被永久删除。此操作无法撤销。")
    }
    .alert(
      String(localized: "清理 RSS 历史文章？"),
      isPresented: $isRSSCleanupConfirmationPresented
    ) {
      Button(String(localized: "立即清理"), role: .destructive) {
        cleanRSSHistory()
      }
      Button(String(localized: "取消"), role: .cancel) {}
    } message: {
      Text(
        String(
          format: String(localized: "将清理 %@ 天前的已读文章；未读、稍后阅读和带高亮的文章会保留。"),
          retentionDays.formatted()
        )
      )
    }
    .alert(
      String(localized: "复制并切换存储位置？"),
      isPresented: $isRelocationConfirmationPresented
    ) {
      Button(String(localized: "复制并切换")) {
        relocateDataRoot()
      }
      Button(String(localized: "取消"), role: .cancel) {
        pendingRelocationParentURL = nil
      }
    } message: {
      Text(relocationConfirmationMessage)
    }
    .alert(
      String(localized: "切回默认自动备份保留策略？"),
      isPresented: $isHistoryRetentionDowngradeConfirmationPresented
    ) {
      Button(String(localized: "切回默认策略"), role: .destructive) {
        _ = backupScheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(false)
      }
      Button(String(localized: "继续保留全部快照"), role: .cancel) {}
    } message: {
      Text("确认后不会立即删除快照。下一次成功创建备份后，系统可能按最多 12 份、90 天和 4 GiB 的默认规则清理超额旧快照。确认前请确保已将需要保留的备份复制到其他位置。")
    }
    .accessibilityIdentifier("storage-management-settings")
  }

  @ViewBuilder
  private var storageSections: some View {
    switch scope {
    case .all:
      currentLocationSection
      knowledgeSection
      rssSection
      backupSection
      relocationSection
    case .storageAndCleanup:
      currentLocationSection
      knowledgeSection
      relocationSection
    case .backupAndRestore:
      backupSection
    }
  }

  private var currentLocationSection: some View {
    Section(String(localized: "当前存储位置")) {
      if let rootURL {
        LabeledContent(String(localized: "文件夹")) {
          Text(rootURL.path)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        if let usageSnapshot {
          LabeledContent(
            String(localized: "总占用"),
            value: formattedByteCount(usageSnapshot.totalByteCount)
          )
          LabeledContent(
            String(localized: "本地文件"),
            value: usageSnapshot.regularFileCount.formatted()
          )
          storageBreakdown(snapshot: usageSnapshot)
        } else if isLoadingUsage {
          ProgressView(String(localized: "正在计算存储空间…"))
            .controlSize(.small)
        }

        HStack {
          Button(String(localized: "在 Finder 中显示"), systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([rootURL])
          }
          Button(String(localized: "重新计算"), systemImage: "arrow.clockwise") {
            Task { await refreshUsage() }
          }
          .disabled(isLoadingUsage || isRelocating)
        }
      } else {
        Text("当前数据文件夹尚未准备完成。")
          .foregroundStyle(.secondary)
      }

      if let usageError {
        AccessibleStatusMessage(message: usageError, severity: .error)
          .textSelection(.enabled)
      }
      if let operationMessage {
        AccessibleStatusMessage(
          message: operationMessage,
          severity: .success,
          announcesNonUrgentStatus: true
        )
        .textSelection(.enabled)
      }
      if let operationError {
        AccessibleStatusMessage(message: operationError, severity: .error)
          .textSelection(.enabled)
      }
      if let dataRootMessage = coordinator.dataRootMessage {
        Text(dataRootMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  @ViewBuilder
  private func storageBreakdown(snapshot: WorkbenchStorageUsageSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      storageVisualCapacityBar(snapshot: snapshot)
      storageLegend(snapshot: snapshot)
    }
    .padding(.vertical, 4)

    LabeledContent(
      String(localized: "资料库"),
      value: formattedByteCount(snapshot.knowledgeLibraryByteCount)
    )
    LabeledContent(
      String(localized: "RSS"),
      value: formattedByteCount(snapshot.rssReaderByteCount)
    )
    LabeledContent(
      String(localized: "应用内附件"),
      value: formattedByteCount(snapshot.managedAttachmentsByteCount)
    )
    LabeledContent(
      String(localized: "自动备份"),
      value: formattedByteCount(snapshot.automaticBackupsByteCount)
    )
    LabeledContent(
      String(localized: "其他工作台数据"),
      value: formattedByteCount(snapshot.otherByteCount)
    )
  }

  private func storageVisualCapacityBar(snapshot: WorkbenchStorageUsageSnapshot) -> some View {
    let total = max(1, Double(snapshot.totalByteCount))
    let knowledgeFrac = Double(snapshot.knowledgeLibraryByteCount) / total
    let rssFrac = Double(snapshot.rssReaderByteCount) / total
    let attachFrac = Double(snapshot.managedAttachmentsByteCount) / total
    let backupFrac = Double(snapshot.automaticBackupsByteCount) / total
    let otherFrac = Double(snapshot.otherByteCount) / total

    return GeometryReader { geo in
      HStack(spacing: 2) {
        if knowledgeFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.blue)
            .frame(width: max(4, geo.size.width * CGFloat(knowledgeFrac)))
        }
        if rssFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.orange)
            .frame(width: max(4, geo.size.width * CGFloat(rssFrac)))
        }
        if attachFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.purple)
            .frame(width: max(4, geo.size.width * CGFloat(attachFrac)))
        }
        if backupFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.green)
            .frame(width: max(4, geo.size.width * CGFloat(backupFrac)))
        }
        if otherFrac > 0.005 {
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.5))
            .frame(width: max(4, geo.size.width * CGFloat(otherFrac)))
        }
      }
    }
    .frame(height: 10)
    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(String(localized: "存储空间占用比例图"))
  }

  private func storageLegend(snapshot: WorkbenchStorageUsageSnapshot) -> some View {
    HStack(spacing: 12) {
      legendItem(title: String(localized: "资料库"), color: .blue)
      legendItem(title: String(localized: "RSS"), color: .orange)
      legendItem(title: String(localized: "附件"), color: .purple)
      legendItem(title: String(localized: "备份"), color: .green)
      legendItem(title: String(localized: "其他"), color: .secondary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func legendItem(title: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)
      Text(title)
    }
  }

  private var knowledgeSection: some View {
    Section(String(localized: "资料库清理")) {
      LabeledContent(
        String(localized: "资料"),
        value: dataManagement.knowledgeDocumentCount.formatted()
      )
      LabeledContent(
        String(localized: "回收站"),
        value: dataManagement.knowledgeRecycledDocumentCount.formatted()
      )
      Text("只清空已经移入资料库回收站的内容；仍在资料库中的正文和原始外部文件不会被删除。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "清空资料库回收站"), systemImage: "trash", role: .destructive) {
        isKnowledgeCleanupConfirmationPresented = true
      }
      .disabled(
        dataManagement.knowledgeRecycledDocumentCount == 0
          || dataManagement.isKnowledgeBusy
          || isCleaningKnowledge
          || isRelocating
      )
    }
  }

  private var rssSection: some View {
    Section(String(localized: "RSS 清理")) {
      LabeledContent(
        String(localized: "订阅"),
        value: rssStore.feeds.count.formatted()
      )
      LabeledContent(
        String(localized: "文章"),
        value: rssStore.articleHeaders.count.formatted()
      )
      Picker(String(localized: "清理范围"), selection: $retentionDays) {
        ForEach([30, 60, 90, 180, 365, 730], id: \.self) { days in
          Text("\(days) 天前").tag(days)
        }
      }
      Text("只清理超过期限、已读、未加入稍后阅读且没有高亮的文章。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "清理 RSS 历史文章"), systemImage: "trash", role: .destructive) {
        isRSSCleanupConfirmationPresented = true
      }
      .disabled(rssStore.isRefreshing || isRelocating)
    }
  }

  private var backupSection: some View {
    Section(String(localized: "备份与导入")) {
      Text("完整备份包含工作台、资料库、RSS、附件和发布记录；导入前会先校验并显示内容预览，API Key 不会写入备份。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(String(localized: "创建完整备份…"), systemImage: "externaldrive.badge.plus") {
          createWorkspaceBackup()
        }
        Button(String(localized: "从备份导入…"), systemImage: "square.and.arrow.down") {
          chooseWorkspaceBackupForRestore()
        }
      }
      .disabled(isRelocating)

      Divider()

      Text("资料库备份")
        .font(.headline)
      Text("单独保存资料库正文、网页归档、版本、标注和检索索引；恢复前会先校验并显示预览。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button(String(localized: "创建资料库备份…"), systemImage: "books.vertical.fill") {
          createKnowledgeBackup()
        }
        Button(String(localized: "恢复资料库备份…"), systemImage: "arrow.counterclockwise") {
          chooseKnowledgeBackupForRestore()
        }
      }
      .disabled(dataManagement.isKnowledgeBusy || isRelocating)

      automaticBackupSection

      selectiveBackupSection
    }
  }

  private var selectiveBackupSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider()
      Text("按类别备份")
        .font(.headline)
      Text(
        "选择要保存的数据。工作台数据包含草稿、配置、发布历史和 AI 对话；API Key 和 AI 服务凭据不会写入备份。Mac 工作区备份不能在 iPhone/iPad 恢复；跨端文章使用工作区交换文件，笔记使用笔记导出包。"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      ForEach(WorkspaceBackupCategory.allCases, id: \.self) { category in
        Toggle(isOn: categoryBinding(category)) {
          VStack(alignment: .leading, spacing: 2) {
            Text(categoryTitle(category))
            Text(categoryDescription(category))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.checkbox)
        .disabled(isCreatingSelectiveBackup)
      }

      Picker("保存位置", selection: $backupDestination) {
        ForEach(SelectiveBackupDestination.allCases) { destination in
          Text(destination.title).tag(destination)
        }
      }
      .pickerStyle(.segmented)
      .disabled(isCreatingSelectiveBackup)

      HStack {
        Button("创建所选备份", systemImage: "externaldrive.badge.plus") {
          createSelectiveBackup()
        }
        .disabled(selectedBackupCategories.isEmpty || isCreatingSelectiveBackup || isRelocating)

        Button("选择备份并预览恢复…", systemImage: "eye") {
          previewSelectiveRestore()
        }
        .disabled(isCreatingSelectiveBackup || isRelocating)
      }

      HStack {
        Button("导出跨端交换文件…", systemImage: "square.and.arrow.up") {
          exportWorkspaceExchange()
        }
        Button("导入跨端交换文件…", systemImage: "square.and.arrow.down") {
          previewWorkspaceExchangeImport()
        }
        .disabled(isExchangingWorkspace || isRelocating)
      }
      Text("交换包仅包含站点配置摘要、文章草稿和附件，不包含笔记、发布历史或凭据。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if isExchangingWorkspace {
        ProgressView {
          Text("正在读取、验证或写入跨端交换文件…")
        }
        .controlSize(.small)
      }

      if backupDestination == .iCloud {
        cloudBackupInventory
      }

      if isCreatingSelectiveBackup {
        ProgressView("正在创建并校验所选备份…")
          .controlSize(.small)
      }
      if let operationMessage {
        AccessibleStatusMessage(message: operationMessage, severity: .success)
          .textSelection(.enabled)
      }
      if let operationError {
        AccessibleStatusMessage(message: operationError, severity: .error)
          .textSelection(.enabled)
      }
    }
    .sheet(isPresented: $isSelectiveRestorePreviewPresented) {
      if let selectiveRestorePreview {
        SelectiveWorkspaceBackupPreviewSheet(
          preview: selectiveRestorePreview,
          dataManagement: dataManagement
        ) { categories in
          try await prepareSelectiveRestore(categories: categories, from: selectiveRestorePreview.backupPreview.backupURL)
        }
      }
    }
    .onChange(of: isSelectiveRestorePreviewPresented) { _, presented in
      guard !presented, let stagingDirectory = selectiveRestoreStagingDirectory else { return }
      try? FileManager.default.removeItem(at: stagingDirectory)
      selectiveRestoreStagingDirectory = nil
    }
  }

  @ViewBuilder
  private var cloudBackupInventory: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("iCloud 工作区备份")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Button("刷新", systemImage: "arrow.clockwise") {
          refreshCloudBackups()
        }
        .labelStyle(.iconOnly)
      }
      if cloudBackupItems.isEmpty {
        Text("尚未发现 iCloud 备份；刚复制的备份会在系统完成上传后显示为云端可用。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if isLoadingCloudBackup {
        ProgressView("正在下载并校验备份…")
          .controlSize(.small)
      }
      ForEach(cloudBackupItems) { item in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text(item.url.deletingPathExtension().lastPathComponent)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(cloudAvailabilityText(item.availability))
              .font(.caption)
              .foregroundStyle(item.availability == .availableInCloud ? WorkbenchTheme.success : .secondary)
          }
          Spacer()
          Button("下载并预览") { previewCloudBackup(item) }
            .disabled(isLoadingCloudBackup || (item.availability != .availableInCloud && item.availability != .downloadRequired))
        }
      }
    }
    .padding(12)
    .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 10))
    .task { refreshCloudBackups() }
  }

  private func categoryBinding(_ category: WorkspaceBackupCategory) -> Binding<Bool> {
    Binding(
      get: { selectedBackupCategories.contains(category) },
      set: { enabled in
        if enabled { selectedBackupCategories.insert(category) }
        else { selectedBackupCategories.remove(category) }
      }
    )
  }

  private func categoryTitle(_ category: WorkspaceBackupCategory) -> String {
    switch category {
    case .workbench: return String(localized: "草稿与附件")
    case .knowledgeLibrary: return String(localized: "资料库")
    case .rssReader: return String(localized: "RSS 阅读器")
    case .operationHistory: return String(localized: "操作记录")
    }
  }

  private func categoryDescription(_ category: WorkspaceBackupCategory) -> String {
    switch category {
    case .workbench: return String(localized: "草稿、历史版本、站点和工作台配置、发布历史、AI 对话及引用附件")
    case .knowledgeLibrary: return String(localized: "资料、网页归档、标注和检索索引")
    case .rssReader: return String(localized: "阅读状态、文章数据库及已缓存媒体")
    case .operationHistory: return String(localized: "不含凭据的应用操作记录")
    }
  }

  private func createSelectiveBackup() {
    Task { @MainActor in
      let destination = backupDestination
      let categories = selectedBackupCategories
      let localURL: URL
      let stagingDirectory: URL?
      switch destination {
      case .local:
        guard let selected = await WorkspaceBackupSelectionPanel.chooseSelectiveBackupDestination()
        else { return }
        localURL = selected
        stagingDirectory = nil
      case .iCloud:
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("WorkspaceBackupUpload-\(UUID().uuidString)", isDirectory: true)
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyyMMdd-HHmmss"
        localURL = directory.appendingPathComponent(
          "所选工作区备份-\(timestamp.string(from: Date())).psworkspacebackup",
          isDirectory: true
        )
        stagingDirectory = directory
      }

      isCreatingSelectiveBackup = true
      operationMessage = nil
      operationError = nil
      Task {
        defer {
          if let stagingDirectory {
            DispatchQueue.global(qos: .utility).async {
              try? FileManager.default.removeItem(at: stagingDirectory)
            }
          }
          isCreatingSelectiveBackup = false
        }
        guard
          let created = await workbenchStore.createWorkspaceBackup(
            at: localURL,
            selectedCategories: categories
          )
        else {
          operationError = String(localized: "所选备份创建失败，请检查上方状态。")
          return
        }
        guard
          let verified = await dataManagement.workspaceBackupPreview(from: created.backupURL)
        else {
          operationError = String(localized: "备份已生成，但完整性复核失败；不能将其视为可用备份。")
          return
        }
        if destination == .iCloud {
          do {
            let cloudURL = try await iCloudWorkspaceBackupStore().copyInspectedBackup(
              from: verified.backupURL)
            operationMessage = String(localized: "备份已通过本地复核并加入 iCloud 上传队列：\(cloudURL.lastPathComponent)。系统确认上传前会显示为上传中。")
            refreshCloudBackups()
          } catch {
            operationError = error.localizedDescription
          }
        } else {
          let formattedByteCount = ByteCountFormatter.string(
            fromByteCount: verified.totalByteCount,
            countStyle: .file
          )
          operationMessage = String(
            localized: "所选 Mac 工作区备份已创建并通过完整性复核（\(formattedByteCount)）。"
          )
        }
      }
    }
  }

  private func refreshCloudBackups() {
    Task {
      do { cloudBackupItems = try await iCloudWorkspaceBackupStore().listItems() } catch {
        operationError = error.localizedDescription
      }
    }
  }

  private func previewSelectiveRestore() {
    Task { @MainActor in
      guard let url = await WorkspaceBackupSelectionPanel.chooseBackupForRestore() else { return }
      inspectSelectiveBackup(at: url)
    }
  }

  private func previewCloudBackup(_ item: iCloudWorkspaceBackupStore.Item) {
    operationMessage = nil
    operationError = nil
    isLoadingCloudBackup = true
    Task {
      defer { isLoadingCloudBackup = false }
      do {
        let stagedURL = try await iCloudWorkspaceBackupStore().downloadToLocalStaging(item.url)
        // The downloaded bytes are inspected only after they have been copied
        // into an isolated local staging folder.
        inspectSelectiveBackup(at: stagedURL, temporaryStagingDirectory: stagedURL.deletingLastPathComponent())
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  private func inspectSelectiveBackup(at url: URL, temporaryStagingDirectory: URL? = nil) {
    Task {
      do {
        let preview = try await dataManagement.workspaceBackupSelectiveRestorePreview(from: url)
        selectiveRestorePreview = preview
        selectiveRestoreStagingDirectory = temporaryStagingDirectory
        isSelectiveRestorePreviewPresented = true
      } catch {
        if let temporaryStagingDirectory {
          try? FileManager.default.removeItem(at: temporaryStagingDirectory)
        }
        operationError = String(localized: "备份校验失败：\(error.localizedDescription)")
      }
    }
  }

  private func prepareSelectiveRestore(
    categories: Set<WorkspaceBackupCategory>,
    from backupURL: URL
  ) async throws {
    _ = try await dataManagement.prepareSelectiveWorkspaceBackupRestore(
      from: backupURL,
      categories: categories
    )
    operationMessage = String(localized: "所选恢复已安全暂存，应用将重新启动并应用所选类别。")
    if let stagingDirectory = selectiveRestoreStagingDirectory {
      try? FileManager.default.removeItem(at: stagingDirectory)
      selectiveRestoreStagingDirectory = nil
    }
  }

  private func cloudAvailabilityText(_ availability: iCloudWorkspaceBackupStore.Availability) -> String {
    switch availability {
    case .unavailable(let message), .failed(let message): return message
    case .localOnly: return String(localized: "仅本机可用，尚未确认上传")
    case .pendingUpload: return String(localized: "等待 iCloud 上传确认")
    case .uploading: return String(localized: "正在上传到 iCloud…")
    case .availableInCloud: return String(localized: "已上传到 iCloud")
    case .downloading: return String(localized: "正在从 iCloud 下载…")
    case .downloadRequired: return String(localized: "云端文件可用，下载后可预览")
    }
  }

  private var automaticBackupRetentionDescription: String {
    guard backupScheduler.canPreserveAutomaticBackupHistoryOnSelectedDisk else {
      return String(localized: "默认目录、iCloud 或云文件夹不支持保留全部自动快照。此时每份自动备份最多 4 GiB，历史按最多 12 份、90 天和 4 GiB 清理；应用不会检查云端配额。请先选择本机或外置磁盘上的目录。")
    }
    if backupScheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk {
      return String(localized: "此模式会在当前保存目录保留所有自动快照，不按 12 份、90 天或 4 GiB 清理。快照仍受单包安全上限约束；磁盘空间有限，目录所在磁盘断开时备份也会失败。")
    }
    return String(localized: "当前使用默认保留策略：最多 12 份、90 天、合计 4 GiB。下一次成功备份后可能清理超额旧快照；可随时重新开启保留全部。")
  }

  private var automaticBackupSizeLimitDescription: String {
    if backupScheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk {
      return String(localized: "保留全部模式下，单份自动备份最多 20 GiB，单个文件最多 2 GiB。可用空间会变化，不能保证下一份备份一定能完成；超限或空间不足时会显示失败原因并移除未完成的临时包。请只选需要的类别，或选择空间更大的磁盘。超过单文件上限的内容目前不受工作区备份支持。")
    }
    return String(localized: "默认模式下，单份自动备份最多 4 GiB，单个文件最多 2 GiB。可用空间会变化，不能保证下一份备份一定能完成；超限或空间不足时会显示失败原因并移除未完成的临时包。请只选需要的类别，或选择空间更大的磁盘。超过单文件上限的内容目前不受工作区备份支持。")
  }

  private var automaticBackupSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Divider()

      Text("自动工作区备份")
        .font(.headline)
      Text("默认关闭。开启后按所选数据的备份指纹比较；指纹相同时跳过。资料库内部维护有时也会触发新快照。每个计划周期最多创建一份。iCloud 上传确认与本机校验分开显示。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Toggle(
        "在所选磁盘保留全部自动快照",
        isOn: Binding(
          get: { backupScheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk },
          set: { enabled in
            if enabled {
              _ = backupScheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(true)
            } else {
              isHistoryRetentionDowngradeConfirmationPresented = true
            }
          }
        )
      )
      .accessibilityIdentifier("preserve-automatic-backup-history")
      .disabled(
        backupScheduler.isRunning
          || !backupScheduler.canPreserveAutomaticBackupHistoryOnSelectedDisk)
      Text(automaticBackupRetentionDescription)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Text("自动备份类别")
        .font(.subheadline.weight(.semibold))
      ForEach(WorkspaceBackupCategory.allCases, id: \.self) { category in
        Toggle(isOn: schedulerCategoryBinding(category)) {
          Text(categoryTitle(category))
        }
        .toggleStyle(.checkbox)
        .disabled(backupScheduler.isRunning)
      }

      Picker(
        String(localized: "备份频率"),
        selection: Binding(
          get: { backupScheduler.settings.frequency },
          set: { backupScheduler.setFrequency($0) }
        )
      ) {
        ForEach(WorkspaceBackupFrequency.allCases, id: \.self) { frequency in
          Text(frequency.localizedDisplayNameKey).tag(frequency)
        }
      }
      .disabled(backupScheduler.isRunning)

      LabeledContent(String(localized: "保存目录")) {
        Text(backupScheduler.destinationFolderLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      LabeledContent("所选目录所在磁盘的可用空间") {
        HStack(spacing: 6) {
          Text(automaticBackupAvailableCapacity.map(formattedByteCount) ?? String(localized: "暂不可用"))
          Button("刷新", systemImage: "arrow.clockwise") {
            refreshAutomaticBackupCapacity()
          }
          .labelStyle(.iconOnly)
          .help("重新读取所选目录所在磁盘的可用空间")
        }
        .font(.caption)
      }
      if let latestBackup = backupScheduler.recentBackups.first {
        LabeledContent("最近自动快照大小", value: formattedByteCount(latestBackup.totalByteCount))
      }
      Text(automaticBackupSizeLimitDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if backupScheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk {
        Text(
          String(
            format: String(
              localized: "后台自动校验修改时间最近的 %@ 份；页面显示其中最近 %@ 份。更早快照仍保留在磁盘，可用“从备份导入”手动选择恢复。"
            ),
            "12",
            "5"
          )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button(String(localized: "选择目录…"), systemImage: "folder") {
          chooseAutomaticBackupDirectory()
        }
        Button(String(localized: "使用 iCloud 目录"), systemImage: "icloud") {
          useICloudForAutomaticBackup()
        }
        Button(String(localized: "恢复默认目录")) {
          backupScheduler.resetDestinationFolder()
          refreshAutomaticBackupCapacity()
        }
        .disabled(backupScheduler.settings.destinationPath == nil)
      }
      .disabled(backupScheduler.isRunning || isResolvingAutomaticICloudDestination)

      HStack {
        Button(String(localized: "立即备份并校验"), systemImage: "checkmark.shield") {
          Task { await backupScheduler.runBackupNow() }
        }
        Button(String(localized: "校验最近备份"), systemImage: "arrow.triangle.2.circlepath") {
          Task { await backupScheduler.refreshRecentBackups() }
        }
      }
      .disabled(backupScheduler.isRunning || isResolvingAutomaticICloudDestination)

      LabeledContent(String(localized: "备份副本状态")) {
        Text(cloudUploadStatusText(backupScheduler.cloudUploadStatus))
          .font(.caption)
          .foregroundStyle(cloudUploadStatusColor(backupScheduler.cloudUploadStatus))
          .fixedSize(horizontal: false, vertical: true)
      }
      Button(String(localized: "刷新备份状态"), systemImage: "arrow.clockwise") {
        backupScheduler.refreshCloudUploadStatus()
      }

      if backupScheduler.isRunning {
        ProgressView(String(localized: "正在创建并校验自动备份…"))
          .controlSize(.small)
      }
      if let statusMessage = backupScheduler.statusMessage, !statusMessage.isEmpty {
        AccessibleStatusMessage(
          message: automaticBackupStatusMessage(statusMessage),
          severity: backupSchedulerStatusSeverity,
          announcesNonUrgentStatus: backupScheduler.statusLevel == .info
            || backupScheduler.statusLevel == .success
        )
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      }
      if backupScheduler.invalidRecentBackupCount > 0 {
        AccessibleStatusMessage(
          message: String(
            format: String(
              localized: "%@ 个自动备份校验失败，已从一键恢复列表中隐藏；请检查备份目录或重新创建备份。"
            ),
            backupScheduler.invalidRecentBackupCount.formatted()
          ),
          severity: .warning
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      if let lastBackupAt = backupScheduler.settings.lastBackupAt {
        LabeledContent(
          String(localized: "最近成功备份"),
          value: lastBackupAt.formatted(date: .abbreviated, time: .shortened)
        )
      }
      if let lastValidationAt = backupScheduler.settings.lastValidationAt {
        LabeledContent(
          String(localized: "最近校验"),
          value: lastValidationAt.formatted(date: .abbreviated, time: .shortened)
        )
      }
      if backupScheduler.statusLevel != .error,
        let lastError = backupScheduler.settings.lastError,
        !lastError.isEmpty
      {
        AccessibleStatusMessage(message: lastError, severity: .error)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !backupScheduler.recentBackups.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("最近自动备份")
            .font(.subheadline.weight(.semibold))
          ForEach(backupScheduler.recentBackups.prefix(5)) { preview in
            HStack(alignment: .top, spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.callout.weight(.medium))
                Text(preview.backupURL.lastPathComponent)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
                Text(backupCompatibilitySummary(for: preview))
                  .font(.workbenchMetadata)
                  .foregroundStyle(
                    preview.compatibility.requiresConfirmation
                      ? WorkbenchTheme.warning
                      : WorkbenchTheme.neutral
                  )
              }
              Spacer(minLength: 8)
              Button(String(localized: "一键恢复")) {
                restoreAutomaticBackup(preview)
              }
              .accessibilityLabel(
                String(
                  format: String(localized: "恢复 %@ 创建的自动备份"),
                  preview.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
              )
            }
            .padding(9)
            .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
    .padding(.top, 2)
  }

  private func schedulerCategoryBinding(_ category: WorkspaceBackupCategory) -> Binding<Bool> {
    Binding(
      get: { backupScheduler.selectedCategories.contains(category) },
      set: { enabled in
        var categories = backupScheduler.selectedCategories
        if enabled { categories.insert(category) }
        else { categories.remove(category) }
        backupScheduler.setSelectedCategories(categories)
      }
    )
  }

  private func automaticBackupStatusMessage(_ message: String) -> String {
    guard backupScheduler.settings.preserveAutomaticBackupHistoryOnSelectedDisk,
      backupScheduler.statusLevel == .success || backupScheduler.statusLevel == .warning
    else { return message }
    return String(
      format: String(localized: "自动备份校验只覆盖最近 %@ 份：%@"),
      "12",
      message
    )
  }

  private func useICloudForAutomaticBackup() {
    guard !isResolvingAutomaticICloudDestination else { return }
    isResolvingAutomaticICloudDestination = true
    Task {
      defer { isResolvingAutomaticICloudDestination = false }
      do {
        let folderURL = try await iCloudWorkspaceBackupStore().directoryURL()
        guard !backupScheduler.isRunning else { return }
        backupScheduler.setPreserveAutomaticBackupHistoryOnSelectedDisk(false)
        backupScheduler.setICloudDestinationFolder(folderURL)
        refreshAutomaticBackupCapacity()
        operationMessage = String(localized: "自动备份将保存到 iCloud 云盘；副本仍需等待系统确认上传。")
      } catch {
        operationError = error.localizedDescription
      }
    }
  }


  private func refreshAutomaticBackupCapacity() {
    let values = try? backupScheduler.destinationFolderURL.resourceValues(
      forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    )
    if let importantCapacity = values?.volumeAvailableCapacityForImportantUsage {
      automaticBackupAvailableCapacity = importantCapacity
    } else if let capacity = values?.volumeAvailableCapacity {
      automaticBackupAvailableCapacity = Int64(capacity)
    } else {
      automaticBackupAvailableCapacity = nil
    }
  }

  private func cloudUploadStatusText(_ status: WorkspaceBackupCloudUploadStatus) -> String {
    switch status {
    case .noBackup: return String(localized: "尚无已完成的备份")
    case .backupUnavailable: return String(localized: "备份暂不可访问；无法确认副本状态")
    case .localCopyComplete: return String(localized: "本地副本已完成")
    case .iCloudFileUnrecognized: return String(localized: "本机副本已完成；尚未识别为 iCloud 云端文件")
    case .waitingForUpload: return String(localized: "本机副本已完成；等待 iCloud 上传确认")
    case .uploadConfirmed: return String(localized: "本机副本已完成；iCloud 已确认上传")
    case .uploadFailed(let message): return String(localized: "本机副本已完成；iCloud 上传失败：\(message)")
    case .manifestCorrupt: return String(localized: "备份清单损坏；请重新创建备份")
    }
  }

  private func cloudUploadStatusColor(_ status: WorkspaceBackupCloudUploadStatus) -> Color {
    switch status {
    case .noBackup: return .secondary
    case .backupUnavailable: return WorkbenchTheme.warning
    case .localCopyComplete, .uploadConfirmed: return WorkbenchTheme.success
    case .uploadFailed, .manifestCorrupt: return WorkbenchTheme.risk
    case .iCloudFileUnrecognized, .waitingForUpload: return WorkbenchTheme.warning
    }
  }

  private var relocationSection: some View {
    Section(String(localized: "更改存储位置")) {
      Text("选择本机或外置硬盘中的目标位置。RepoPress Studio 会新建数据文件夹，复制并校验全部资料库、RSS 和附件后再切换；原文件夹会保留。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(String(localized: "复制到新位置并切换…"), systemImage: "externaldrive.badge.timemachine") {
        chooseRelocationDestination()
      }
      .disabled(isRelocating || rootURL == nil)
      if isRelocating {
        ProgressView(String(localized: "正在复制并校验，请勿断开硬盘…"))
          .controlSize(.small)
      } else {
        Text("切换成功后应用会退出。重新打开即可使用新位置；确认无误前请不要删除原文件夹。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var rootURL: URL? {
    coordinator.dataRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  private var relocationConfirmationMessage: String {
    guard let parentURL = pendingRelocationParentURL else {
      return String(localized: "请选择新的存储位置。")
    }
    return String(
      format: String(localized: "RepoPress Studio 将在 %@ 中创建新的数据文件夹。复制并校验成功后应用会退出，原文件夹不会删除。"),
      parentURL.path
    )
  }

  private func formattedByteCount(_ byteCount: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
  }

  private func refreshUsage() async {
    guard let rootURL else { return }
    isLoadingUsage = true
    usageError = nil
    do {
      usageSnapshot = try await Task.detached(priority: .utility) {
        try WorkbenchStorageUsageService().snapshot(
          for: WorkbenchDataRootLayout(rootURL: rootURL)
        )
      }.value
    } catch {
      usageError = error.localizedDescription
    }
    isLoadingUsage = false
  }

  private func cleanKnowledgeRecycleBin() {
    isCleaningKnowledge = true
    operationMessage = nil
    operationError = nil
    Task {
      let summary = await dataManagement.knowledge.emptyRecycleBin()
      if summary.failedDocumentCount > 0 || summary.failedStoredFileCount > 0 {
        operationError = String(
          format: String(localized: "资料库仅完成部分清理：删除 %@ 条资料，%@ 条资料和 %@ 个本地文件未能移除。"),
          summary.removedDocumentCount.formatted(),
          summary.failedDocumentCount.formatted(),
          summary.failedStoredFileCount.formatted()
        )
      } else {
        operationMessage = String(
          format: String(localized: "资料库清理完成：永久删除 %@ 条资料。"),
          summary.removedDocumentCount.formatted()
        )
      }
      isCleaningKnowledge = false
      await refreshUsage()
    }
  }

  private func cleanRSSHistory() {
    operationMessage = nil
    operationError = nil
    let summary = rssStore.pruneReadArticles(olderThanDays: retentionDays)
    if let lastError = rssStore.lastError, !lastError.isEmpty {
      operationError = lastError
    } else {
      operationMessage =
        summary.removedArticleCount == 0
        ? String(localized: "没有符合条件的 RSS 历史文章。")
        : String(
          format: String(localized: "RSS 清理完成：删除 %@ 篇文章。"),
          summary.removedArticleCount.formatted()
        )
    }
    Task { await refreshUsage() }
  }

  private func createWorkspaceBackup() {
    Task { @MainActor in
      guard let destinationURL = await WorkspaceBackupSelectionPanel.chooseBackupDestination()
      else {
        return
      }
      operationMessage = nil
      operationError = nil
      let preview = await dataManagement.createWorkspaceBackup(at: destinationURL)
      if let preview {
        operationMessage = String(
          format: String(localized: "完整备份已创建：%@（%@）。"),
          preview.backupURL.lastPathComponent,
          formattedByteCount(preview.totalByteCount)
        )
      } else {
        operationError = dataManagement.lastSaveStatus
      }
      await refreshUsage()
    }
  }

  private func chooseWorkspaceBackupForRestore() {
    Task { @MainActor in
      guard let backupURL = await WorkspaceBackupSelectionPanel.chooseBackupForRestore() else {
        return
      }
      operationMessage = nil
      operationError = nil
      workspaceBackupPreview = await dataManagement.workspaceBackupPreview(from: backupURL)
      if workspaceBackupPreview == nil {
        operationError = dataManagement.lastSaveStatus
      }
    }
  }

  private func exportWorkspaceExchange() {
    Task { @MainActor in
      guard let destinationURL = await WorkspaceExchangeFilePanel.chooseExportDestination() else {
        return
      }
      operationMessage = nil
      operationError = nil
      isExchangingWorkspace = true
      defer { isExchangingWorkspace = false }
      do {
        let data = try await workbenchStore.makeWorkspaceExchangeData()
        try await Task.detached(priority: .utility) {
          try WorkspaceExchangeFilePanel.writePackageData(data, to: destinationURL)
        }.value
        operationMessage = String(
          localized: "跨端交换文件已写入所选位置：\(destinationURL.lastPathComponent)。"
        )
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  private func previewWorkspaceExchangeImport() {
    Task { @MainActor in
      guard let sourceURL = await WorkspaceExchangeFilePanel.chooseImportSource() else { return }
      operationMessage = nil
      operationError = nil
      isExchangingWorkspace = true
      defer { isExchangingWorkspace = false }
      do {
        let data = try await Task.detached(priority: .utility) {
          try WorkspaceExchangeFilePanel.readPackageData(from: sourceURL)
        }.value
        workspaceExchangePreview = try await workbenchStore.previewWorkspaceExchange(data: data)
      } catch {
        operationError = error.localizedDescription
      }
    }
  }

  private func createKnowledgeBackup() {
    Task { @MainActor in
      guard
        let destinationURL = await KnowledgeLibraryBackupSelectionPanel.chooseBackupDestination()
      else {
        return
      }
      _ = await dataManagement.knowledge.createBackup(at: destinationURL)
      await refreshUsage()
    }
  }

  private func chooseKnowledgeBackupForRestore() {
    Task { @MainActor in
      guard let backupURL = await KnowledgeLibraryBackupSelectionPanel.chooseBackupForRestore()
      else {
        return
      }
      operationMessage = nil
      operationError = nil
      knowledgeBackupPreview = await dataManagement.knowledge.backupPreview(from: backupURL)
      if knowledgeBackupPreview == nil {
        operationError = dataManagement.lastSaveStatus
      }
    }
  }

  private func chooseAutomaticBackupDirectory() {
    Task { @MainActor in
      guard let folderURL = await WorkspaceBackupSelectionPanel.chooseBackupDirectory() else {
        return
      }
      do {
        try backupScheduler.setDestinationFolder(folderURL)
        refreshAutomaticBackupCapacity()
        operationMessage = String(localized: "自动备份目录已更新。")
        operationError = nil
      } catch {
        operationError = String(
          format: String(localized: "自动备份目录不可用：%@"),
          error.localizedDescription
        )
      }
    }
  }

  private func restoreAutomaticBackup(_ preview: WorkspaceBackupPreview) {
    Task {
      workspaceBackupPreview = await dataManagement.workspaceBackupPreview(from: preview.backupURL)
    }
  }

  private func backupCompatibilitySummary(for preview: WorkspaceBackupPreview) -> String {
    switch preview.compatibility {
    case .compatible:
      return String(localized: "版本兼容，已校验")
    case .createdByOlderApplication:
      return String(localized: "来自较旧应用版本，恢复前会提示迁移")
    case .createdByNewerApplication:
      return String(localized: "来自较新应用版本，恢复前需确认")
    case .unknownApplicationVersion:
      return String(localized: "无法比较应用版本，恢复前需确认")
    }
  }

  private var backupSchedulerStatusSeverity: AccessibleStatusSeverity {
    switch backupScheduler.statusLevel {
    case .success:
      return .success
    case .warning:
      return .warning
    case .error:
      return .error
    case .info, .none:
      return .info
    }
  }

  private func chooseRelocationDestination() {
    Task {
      guard
        let parentURL = await WorkbenchDataRootSelectionPanel.chooseDestinationParent(
          forMigration: true
        )
      else { return }
      pendingRelocationParentURL = parentURL
      isRelocationConfirmationPresented = true
    }
  }

  private func relocateDataRoot() {
    guard let parentURL = pendingRelocationParentURL else { return }
    pendingRelocationParentURL = nil
    isRelocating = true
    operationMessage = nil
    Task {
      let result = await coordinator.relocateCurrentDataRoot(in: parentURL)
      guard let result else {
        isRelocating = false
        return
      }
      operationMessage = String(
        format: String(localized: "数据已复制到 %@，即将退出应用。"),
        result.destinationRootURL.path
      )
      NSApp.terminate(nil)
    }
  }
}
