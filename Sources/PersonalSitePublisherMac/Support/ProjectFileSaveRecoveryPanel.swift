import AppKit
import PublishingWorkbenchCore

@MainActor
enum ProjectFileSaveRecoveryPanel {
  static func present(for store: WorkbenchStore) {
    guard !store.isRetryingProjectFileWrites else { return }
    while true {
      let groups = store.siteDraftFileSaveFailureGroups
      let alert = NSAlert()
      alert.messageText = String(localized: "项目文件尚未写入")
      alert.informativeText = informativeText(for: store)
      alert.alertStyle = .warning
      alert.addButton(withTitle: String(localized: "继续编辑"))
      alert.addButton(withTitle: String(localized: "重新检查"))
      alert.addButton(withTitle: String(localized: "更改项目目录"))
      alert.addButton(withTitle: String(localized: "查看详情"))
      let hasExternalChangeConflicts = groups.contains { $0.reason == .externalChange }
      if hasExternalChangeConflicts {
        alert.addButton(withTitle: String(localized: "处理冲突…"))
      }
      alert.buttons[1].isEnabled = !store.persistenceStatus.isRecoveryWriteProtected
      alert.buttons[2].isEnabled =
        !groups.isEmpty && !store.persistenceStatus.isRecoveryWriteProtected
      alert.buttons[3].isEnabled = !groups.isEmpty
      let response = alert.runModal()
      switch response {
      case .alertSecondButtonReturn:
        retry(store: store)
        return
      case .alertThirdButtonReturn:
        guard let profileID = chooseProfile(from: groups),
          let profile = store.profiles.first(where: { $0.id == profileID }),
          let url = chooseDirectory(for: profile)
        else { continue }
        do {
          try store.changeRepositoryRootForSaveRecovery(profileID: profileID, to: url)
          retry(store: store, profileID: profileID)
          return
        } catch {
          showMessage(title: String(localized: "无法使用此项目目录"), message: error.localizedDescription)
        }
      case NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3):
        showDetails(groups)
      case NSApplication.ModalResponse(
        rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 4):
        guard let draftID = chooseExternalChangeDraft(from: groups) else { continue }
        ProjectFileConflictReviewPanel.present(for: store, draftID: draftID)
        return
      default:
        return
      }
    }
  }

  static func informativeText(for store: WorkbenchStore) -> String {
    var messages = [store.siteDraftFileSaveFailureSummary]
    if let error = store.draftRecoveryJournalErrorMessage {
      messages.append(error)
    }
    if let error = store.persistenceStatus.lastSaveError {
      messages.append(error)
    }
    if store.persistenceStatus.isRecoveryWriteProtected {
      messages.append(store.persistenceStatus.recoveryMessage)
    }
    let text = messages.compactMap { $0 }.joined(separator: "\n\n")
    return text.isEmpty
      ? String(localized: "请修复保存位置或权限后重新检查。应用将保持打开。") : text
  }

  private static func retry(store: WorkbenchStore, profileID: UUID? = nil) {
    Task { @MainActor in
      let succeeded = await store.retryPendingProjectFileWrites(profileID: profileID)
      if !store.siteDraftFileSaveFailureGroups.isEmpty {
        present(for: store)
      } else if succeeded {
        showMessage(
          title: String(localized: "重新保存完成"),
          message: String(localized: "项目文件和工作台修改已保存。应用将保持打开。"),
          style: .informational
        )
      } else {
        showMessage(
          title: String(localized: "未能保存工作台修改"),
          message: store.lastSaveError
            ?? String(localized: "请修复保存位置或权限后重新检查。应用将保持打开。")
        )
      }
    }
  }

  private static func chooseProfile(from groups: [SiteDraftFileSaveFailureGroup]) -> UUID? {
    var seen = Set<UUID>()
    let sites = groups.filter { seen.insert($0.profileID).inserted }
    guard let first = sites.first else { return nil }
    if sites.count == 1 { return first.profileID }
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
    // Include the failed path so sites with the same name can be distinguished.
    picker.addItems(withTitles: sites.map { "\($0.siteName) — \($0.rootPath ?? "")" })
    picker.setAccessibilityLabel(String(localized: "需要更改项目目录的站点"))
    let alert = NSAlert()
    alert.messageText = String(localized: "选择需要修复的站点")
    alert.informativeText = String(localized: "只更改所选站点的项目目录。")
    alert.accessoryView = picker
    alert.addButton(withTitle: String(localized: "选择目录…"))
    alert.addButton(withTitle: String(localized: "取消"))
    guard alert.runModal() == .alertFirstButtonReturn,
      sites.indices.contains(picker.indexOfSelectedItem)
    else { return nil }
    return sites[picker.indexOfSelectedItem].profileID
  }

  private static func chooseDirectory(for profile: SiteProfile) -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "更改项目目录") + " · " + profile.name
    panel.message = String(localized: "选择该站点的新项目根目录。随后会重试待写入草稿，外部修改不会被强制覆盖。")
    panel.prompt = String(localized: "选择并重试")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = profile.localRepositoryRootURL
    return panel.runModal() == .OK ? panel.url : nil
  }

  private static func chooseExternalChangeDraft(
    from groups: [SiteDraftFileSaveFailureGroup]
  ) -> UUID? {
    let failures = groups
      .filter { $0.reason == .externalChange }
      .flatMap(\.failures)
    guard let first = failures.first else { return nil }
    if failures.count == 1 { return first.draftID }

    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 500, height: 28))
    picker.addItems(withTitles: failures.map {
      "\($0.siteName) — \($0.repositoryPath)"
    })
    picker.setAccessibilityLabel(String(localized: "需要处理冲突的文章"))

    let alert = NSAlert()
    alert.messageText = String(localized: "选择需要处理的文章冲突")
    alert.informativeText = String(
      localized: "每次只审阅一篇文章。系统会重新读取软件草稿和项目文件，之后由你明确选择处理方式。"
    )
    alert.accessoryView = picker
    alert.addButton(withTitle: String(localized: "处理冲突"))
    alert.addButton(withTitle: String(localized: "取消"))
    guard alert.runModal() == .alertFirstButtonReturn,
      failures.indices.contains(picker.indexOfSelectedItem)
    else { return nil }
    return failures[picker.indexOfSelectedItem].draftID
  }

  private static func showDetails(_ groups: [SiteDraftFileSaveFailureGroup]) {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 280))
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    let textView = NSTextView(frame: scrollView.bounds)
    textView.isEditable = false
    textView.isSelectable = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.containerSize = NSSize(width: 540, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    textView.string = groups.map(\.details).joined(separator: "\n\n")
    textView.setAccessibilityLabel(String(localized: "等待写入的文件及失败原因"))
    scrollView.documentView = textView
    textView.sizeToFit()
    let alert = NSAlert()
    alert.messageText = String(localized: "项目文件写入详情")
    alert.accessoryView = scrollView
    alert.addButton(withTitle: String(localized: "返回"))
    alert.runModal()
  }

  private static func showMessage(title: String, message: String, style: NSAlert.Style = .warning) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    alert.addButton(withTitle: String(localized: "继续编辑"))
    alert.runModal()
  }
}
