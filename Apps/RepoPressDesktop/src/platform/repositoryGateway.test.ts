import { describe, expect, it, vi } from "vitest";
import { createRepositoryGateway } from "./repositoryGateway";

describe("site profile gateway", () => {
  it("binds registrations to sessions and revisions, and opens saved sites only by ID", async () => {
    const call = vi.fn().mockResolvedValue({});
    const gateway = createRepositoryGateway(call);
    await gateway.getSiteProfiles();
    await gateway.registerSiteProfile({ sessionId: "s", name: "博客", expectedRevision: 3 });
    await gateway.renameSiteProfile({ profileId: "p", name: "资料站", expectedRevision: 4 });
    await gateway.removeSiteProfile({ profileId: "p", expectedRevision: 5 });
    await gateway.openSiteProfile("p");
    expect(call.mock.calls).toEqual([
      ["get_site_profiles"],
      ["register_site_profile", { sessionId: "s", name: "博客", expectedRevision: 3 }],
      ["rename_site_profile", { profileId: "p", name: "资料站", expectedRevision: 4 }],
      ["remove_site_profile", { profileId: "p", expectedRevision: 5 }],
      ["open_site_profile", { profileId: "p" }],
    ]);
  });
  it("does not manufacture sites or write local settings in the browser demo", async () => {
    const gateway = createRepositoryGateway();
    expect((await gateway.getCapabilities()).siteProfiles).toBe(false);
    await expect(gateway.getSiteProfiles()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.registerSiteProfile({ sessionId: "s", name: "博客", expectedRevision: 0 })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.renameSiteProfile({ profileId: "p", name: "博客", expectedRevision: 1 })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.removeSiteProfile({ profileId: "p", expectedRevision: 1 })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.openSiteProfile("p")).rejects.toMatchObject({ code: "read_only_demo" });
  });
});
describe("BrowserDemoRepositoryGateway", () => {
  it("reads operation logs and clears only the reviewed sequence boundary", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.getOperationLog(); await gateway.getOperationLog("s-1");
    await gateway.clearOperationLog(42, "s-1");
    expect(call).toHaveBeenCalledWith("get_operation_log", { sessionId: null });
    expect(call).toHaveBeenCalledWith("get_operation_log", { sessionId: "s-1" });
    expect(call).toHaveBeenCalledWith("clear_operation_log", { throughSequence: 42, sessionId: "s-1" });
  });
  it("does not fabricate native operation logs in the browser demo", async () => {
    const gateway = createRepositoryGateway();
    expect((await gateway.getCapabilities()).operationLog).toBe(false);
    await expect(gateway.getOperationLog()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.clearOperationLog(0)).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("binds image scanning and preview to a native session and expected file digest", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.inspectRepositoryImages("session-1");
    await gateway.readRepositoryImage("session-1", "static/images/a.png", "a".repeat(64));
    expect(call).toHaveBeenCalledWith("inspect_repository_images", { sessionId: "session-1" });
    expect(call).toHaveBeenCalledWith("read_repository_image", { sessionId: "session-1", relativePath: "static/images/a.png", expectedSha256: "a".repeat(64) });
  });
  it("keeps local image capabilities unavailable in browser demo", async () => {
    const gateway = createRepositoryGateway();
    expect((await gateway.getCapabilities()).imageWorkbench).toBe(false);
    await expect(gateway.inspectRepositoryImages("demo")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.readRepositoryImage("demo", "image.png", "a".repeat(64))).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("uses the general-draft library and transfer-plan command contracts", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const save = { draftId: "draft-1", text: "# Draft\n", expectedRevision: 2, expectedSha256: "sha-2" };
    const plan = { sessionId: "session-1", operation: "copyGeneralToRepository" as const, targetItems: [{ draftId: "draft-1", relativePath: "content/draft.md" }] };
    await gateway.listGeneralDrafts(); await gateway.getGeneralDraft("draft-1"); await gateway.saveGeneralDraft(save);
    await gateway.planGeneralDraftTransfer(plan); await gateway.executeGeneralDraftTransfer({ sessionId: "session-1", planId: "plan-1" });
    await gateway.undoGeneralDraftTransfer({ sessionId: "session-1", undoId: "undo-1" });
    expect(call).toHaveBeenCalledWith("list_general_drafts");
    expect(call).toHaveBeenCalledWith("get_general_draft", { draftId: "draft-1" });
    expect(call).toHaveBeenCalledWith("save_general_draft", save);
    expect(call).toHaveBeenCalledWith("plan_general_draft_transfer", plan);
    expect(call).toHaveBeenCalledWith("execute_general_draft_transfer", { sessionId: "session-1", planId: "plan-1" });
    expect(call).toHaveBeenCalledWith("undo_general_draft_transfer", { sessionId: "session-1", undoId: "undo-1" });
  });
  it("keeps general-draft writes and transfer actions read-only in browser demo", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.listGeneralDrafts()).resolves.toEqual({ entries: [], total: 0, truncated: false });
    await expect(gateway.getGeneralDraft("draft-1")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.saveGeneralDraft({ draftId: "draft-1", text: "x", expectedRevision: 0, expectedSha256: "" })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planGeneralDraftTransfer({ sessionId: "demo", operation: "moveCurrentToGeneral" })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeGeneralDraftTransfer({ sessionId: "demo", planId: "plan-1" })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.undoGeneralDraftTransfer({ sessionId: "demo", undoId: "undo-1" })).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("uses draft history and recycle-bin command contracts", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.listDraftVersions("s", "d"); await gateway.getDraftVersion("s", "d", "v"); await gateway.restoreDraftVersion("s", "d", "v", "sha");
    await gateway.listRecycledDrafts("s"); await gateway.getRecycledDraft("s", "r"); await gateway.restoreRecycledDraft("s", "r", "content/restored.md"); await gateway.deleteRecycledDraft("s", "r");
    expect(call).toHaveBeenCalledWith("list_draft_versions", { sessionId: "s", documentId: "d" });
    expect(call).toHaveBeenCalledWith("get_draft_version", { sessionId: "s", documentId: "d", versionId: "v" });
    expect(call).toHaveBeenCalledWith("restore_draft_version", { sessionId: "s", documentId: "d", versionId: "v", expectedSha256: "sha" });
    expect(call).toHaveBeenCalledWith("list_recycled_drafts", { sessionId: "s" });
    expect(call).toHaveBeenCalledWith("get_recycled_draft", { sessionId: "s", recycleId: "r" });
    expect(call).toHaveBeenCalledWith("restore_recycled_draft", { sessionId: "s", recycleId: "r", relativePath: "content/restored.md" });
    expect(call).toHaveBeenCalledWith("delete_recycled_draft", { sessionId: "s", recycleId: "r" });
  });
  it("keeps recycle-bin mutations read-only in browser demo", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.listRecycledDrafts("demo")).resolves.toEqual({ entries: [], total: 0, truncated: false });
    await expect(gateway.getDraftVersion("demo", "d", "v")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.restoreRecycledDraft("demo", "r", "x.md")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.deleteRecycledDraft("demo", "r")).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("uses knowledge library command names and bounded arguments", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.knowledgeLibraryStatus(); await gateway.listKnowledgeItems(7); await gateway.getKnowledgeItem("item-1");
    await gateway.importKnowledgeText({ sourceKind: "text", title: "T", sourceName: "S", sourceUrl: null, text: "body", allowsLocalSemanticIndex: true, allowsRemoteAiUse: false });
    await gateway.setKnowledgeRemoteAiPermission({ itemId: "item-1", allowsRemoteAiUse: true });
    await gateway.searchKnowledgeItems("q", 4); await gateway.updateKnowledgeProgress({ itemId: "item-1", progressPercent: 40 }); await gateway.deleteKnowledgeItem("item-1");
    await gateway.planKnowledgeExport({ sessionId: "s", itemId: "item-1", relativePath: "knowledge/t.md" }); await gateway.executeKnowledgeExport("s", "plan-1"); await gateway.planKnowledgeArchiveExport({ sessionId: "s", itemId: "item-1", relativePath: "knowledge/t.mhtml" }); await gateway.executeKnowledgeArchiveExport({ sessionId: "s", planId: "archive-plan-1" }); await gateway.browserCaptureStatus(); await gateway.rotateBrowserCaptureToken();
    expect(call).toHaveBeenCalledWith("knowledge_library_status"); expect(call).toHaveBeenCalledWith("list_knowledge_items", { limit: 7 }); expect(call).toHaveBeenCalledWith("get_knowledge_item", { itemId: "item-1" });
    expect(call).toHaveBeenCalledWith("import_knowledge_text", { request: { sourceKind: "text", title: "T", sourceName: "S", sourceUrl: null, text: "body", allowsLocalSemanticIndex: true, allowsRemoteAiUse: false } });
    expect(call).toHaveBeenCalledWith("set_knowledge_remote_ai_permission", { itemId: "item-1", allowsRemoteAiUse: true });
    expect(call).toHaveBeenCalledWith("search_knowledge_items", { query: "q", limit: 4 }); expect(call).toHaveBeenCalledWith("update_knowledge_progress", { itemId: "item-1", progressPercent: 40 }); expect(call).toHaveBeenCalledWith("delete_knowledge_item", { itemId: "item-1" });
    expect(call).toHaveBeenCalledWith("plan_knowledge_export", { request: { sessionId: "s", itemId: "item-1", relativePath: "knowledge/t.md" } }); expect(call).toHaveBeenCalledWith("execute_knowledge_export", { request: { sessionId: "s", planId: "plan-1" } }); expect(call).toHaveBeenCalledWith("plan_knowledge_archive_export", { request: { sessionId: "s", itemId: "item-1", relativePath: "knowledge/t.mhtml" } }); expect(call).toHaveBeenCalledWith("execute_knowledge_archive_export", { request: { sessionId: "s", planId: "archive-plan-1" } });
    expect(call).toHaveBeenCalledWith("browser_capture_status"); expect(call).toHaveBeenCalledWith("rotate_browser_capture_token");
  });
  it("maps AI chat commands with an explicit conversation, content and selected materials", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const request = { conversationId: "conversation-1", provider: "ollama_local" as const, endpoint: "http://127.0.0.1:11434/v1", model: "local", message: "总结", knowledgeItemIds: ["item-1"], streaming: true };
    await gateway.listAiConversations(); await gateway.createAiConversation({ title: "新对话" }); await gateway.deleteAiConversation("conversation-1");
    await gateway.planAiChat(request); await gateway.executeAiChat({ ...request, planId: "plan-1" });
    expect(call).toHaveBeenCalledWith("list_ai_conversations");
    expect(call).toHaveBeenCalledWith("create_ai_conversation", { title: "新对话" });
    expect(call).toHaveBeenCalledWith("delete_ai_conversation", { conversationId: "conversation-1" });
    expect(call).toHaveBeenCalledWith("plan_ai_chat", request);
    expect(call).toHaveBeenCalledWith("execute_ai_chat", { ...request, planId: "plan-1" });
    await gateway.startAiChatStream({ ...request, planId: "plan-1" }); await gateway.pollAiChatStream("operation-1", 7); await gateway.cancelAiChatStream("operation-1");
    await gateway.getAiChatVaultStatus(); await gateway.initializeAiChatVault("long-enough-passphrase"); await gateway.unlockAiChatVault("long-enough-passphrase"); await gateway.lockAiChatVault(); await gateway.deleteAiChatVault();
    await gateway.listAiProviderProfiles(); await gateway.saveAiProviderProfile({ profileId: null, name: "本机", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "local", streaming: true }); await gateway.deleteAiProviderProfile("profile-1");
    expect(call).toHaveBeenCalledWith("start_ai_chat_stream", { ...request, planId: "plan-1" }); expect(call).toHaveBeenCalledWith("poll_ai_chat_stream", { operationId: "operation-1", afterCursor: 7 }); expect(call).toHaveBeenCalledWith("cancel_ai_chat_stream", { operationId: "operation-1" });
    expect(call).toHaveBeenCalledWith("get_ai_chat_vault_status"); expect(call).toHaveBeenCalledWith("initialize_ai_chat_vault", { passphrase: "long-enough-passphrase" }); expect(call).toHaveBeenCalledWith("unlock_ai_chat_vault", { passphrase: "long-enough-passphrase" }); expect(call).toHaveBeenCalledWith("lock_ai_chat_vault"); expect(call).toHaveBeenCalledWith("delete_ai_chat_vault");
    expect(call).toHaveBeenCalledWith("list_ai_provider_profiles"); expect(call).toHaveBeenCalledWith("save_ai_provider_profile", { profileId: null, name: "本机", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "local", streaming: true }); expect(call).toHaveBeenCalledWith("delete_ai_provider_profile", { profileId: "profile-1" });
  });
  it("keeps browser-demo chat and remote-permission mutations fail-closed", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.listAiConversations()).resolves.toEqual([]);
    await expect(gateway.createAiConversation()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.setKnowledgeRemoteAiPermission({ itemId: "item-1", allowsRemoteAiUse: true })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planAiChat({ conversationId: "c", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "local", message: "hi", knowledgeItemIds: [], streaming: true })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.startAiChatStream({ conversationId: "c", planId: "p", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "local", message: "hi", knowledgeItemIds: [], streaming: true })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.initializeAiChatVault("long-enough-passphrase")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.saveAiProviderProfile({ name: "p", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "local", streaming: true })).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("never performs a demo save", async () => { const gateway = createRepositoryGateway(); await expect(gateway.saveDocument({ sessionId: "demo", documentId: "a", text: "x", expectedSha256: "hash" })).rejects.toMatchObject({ code: "read_only_demo" }); });
  it("keeps archive export fail-closed in browser demo", async () => { const gateway = createRepositoryGateway(); await expect(gateway.planKnowledgeArchiveExport({ sessionId: "demo", itemId: "item-1", relativePath: "knowledge/item.html" })).rejects.toMatchObject({ code: "read_only_demo" }); await expect(gateway.executeKnowledgeArchiveExport({ sessionId: "demo", planId: "plan-1" })).rejects.toMatchObject({ code: "read_only_demo" }); });
  it("keeps the browser demo read-only and native capabilities unavailable", async () => { const gateway = createRepositoryGateway(); const snapshot = await gateway.getCapabilities(); expect(snapshot).toMatchObject({ localEdit: false, gitStatus: false, gitCommit: false, gitPush: false, gitFetch: false, remoteAuth: false, aiEditing: false, semanticSearch: false, pdfTextExtraction: false, ocrReadiness: false, contentHealth: false }); });
  it("uses fixed typed native command arguments", async () => { const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call); await gateway.openDocument("session-1", "content/a.md"); await gateway.inspectContentHealthSources("session-1"); expect(call).toHaveBeenCalledWith("open_document", { sessionId: "session-1", relativePath: "content/a.md" }); expect(call).toHaveBeenCalledWith("inspect_content_health_sources", { sessionId: "session-1" }); });
  it("keeps browser content-health scanning fail-closed", async () => { const gateway = createRepositoryGateway(); await expect(gateway.inspectContentHealthSources("demo")).rejects.toMatchObject({ code: "read_only_demo" }); });
  it("inspects Markdown link metadata without opening the document", async () => { const call = vi.fn().mockResolvedValue({ relativePath: "content/a.md", title: "A", slug: "a", permalink: "/a/" }); const gateway = createRepositoryGateway(call); await expect(gateway.inspectMarkdownLinkMetadata("session-1", "content/a.md")).resolves.toMatchObject({ title: "A" }); expect(call).toHaveBeenCalledWith("inspect_markdown_link_metadata", { sessionId: "session-1", relativePath: "content/a.md" }); });
  it("uses the P4 workspace command names and camelCase arguments", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const preferences = { theme: "dark" as const, editorFontSize: 18, editorLineSpacing: 4, editorBodyWidth: 820, spellCheckEnabled: false, typewriterModeEnabled: false, currentParagraphHighlightEnabled: true, warmPaperBackgroundEnabled: false, automaticPairingEnabled: true, paragraphSpotlightEnabled: false, writingToolDensity: "basic" as const, writingToolbarItemIds: ["bold", "italic"] as ("bold" | "italic")[], restoreLastWorkspace: false, recoveryEnabled: true };
    await gateway.getWorkspaceState();
    await gateway.updateWorkspacePreferences(preferences);
    await gateway.saveRecoveryDraft({ sessionId: "session-1", documentId: "document-1", text: "draft", expectedSha256: "baseline" });
    await gateway.clearRecoveryDraft("recovery-1");
    expect(call).toHaveBeenCalledWith("get_workspace_state");
    expect(call).toHaveBeenCalledWith("update_workspace_preferences", { preferences });
    expect(call).toHaveBeenCalledWith("save_recovery_draft", { sessionId: "session-1", documentId: "document-1", text: "draft", expectedSha256: "baseline" });
    expect(call).toHaveBeenCalledWith("clear_recovery_draft", { recoveryId: "recovery-1" });
  });
  it("keeps browser recovery mutation fail-closed while settings remain in memory", async () => {
    const gateway = createRepositoryGateway();
    const before = await gateway.getWorkspaceState();
    expect(before.preferences.editorFontSize).toBe(15);
    expect(before.preferences).toMatchObject({ editorLineSpacing: 4, editorBodyWidth: 820, spellCheckEnabled: false, typewriterModeEnabled: false, currentParagraphHighlightEnabled: true, warmPaperBackgroundEnabled: false, automaticPairingEnabled: true, paragraphSpotlightEnabled: false, writingToolDensity: "basic", writingToolbarItemIds: ["bold", "italic", "strike", "code", "link", "heading", "quote", "unorderedList", "orderedList", "taskList", "codeBlock", "horizontalRule"] });
    await expect(gateway.saveRecoveryDraft({ sessionId: "demo", documentId: "demo-document", text: "draft", expectedSha256: "baseline" })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.clearRecoveryDraft("recovery-1")).rejects.toMatchObject({ code: "read_only_demo" });
    await gateway.updateWorkspacePreferences({ ...before.preferences, theme: "dark" });
    await expect(gateway.getWorkspaceState()).resolves.toMatchObject({ preferences: { theme: "dark" }, recoveryDraft: null });
  });
  it("sends only session-bound CAS fields when saving", async () => {
    const call = vi.fn().mockResolvedValue({});
    const gateway = createRepositoryGateway(call);
    await gateway.saveDocument({ sessionId: "session-1", documentId: "document-1", text: "# 新内容\n", expectedSha256: "baseline" });
    expect(call).toHaveBeenCalledWith("save_document", { sessionId: "session-1", documentId: "document-1", text: "# 新内容\n", expectedSha256: "baseline" });
  });
  it("uses the Markdown draft lifecycle commands with camelCase session-bound arguments", async () => {
    const call = vi.fn().mockResolvedValue({});
    const gateway = createRepositoryGateway(call);
    await gateway.createMarkdownDocument("session-1", "content/drafts/new.md", "# New\n");
    await gateway.renameMarkdownDocument("session-1", "document-1", "content/published/new.md", "baseline");
    await gateway.deleteMarkdownDocument("session-1", "document-1", "baseline");
    expect(call).toHaveBeenCalledWith("create_markdown_document", { sessionId: "session-1", relativePath: "content/drafts/new.md", initialText: "# New\n" });
    expect(call).toHaveBeenCalledWith("rename_markdown_document", { sessionId: "session-1", documentId: "document-1", newRelativePath: "content/published/new.md", expectedSha256: "baseline" });
    expect(call).toHaveBeenCalledWith("delete_markdown_document", { sessionId: "session-1", documentId: "document-1", expectedSha256: "baseline" });
  });
  it("keeps draft lifecycle mutations read-only in the browser demo", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.createMarkdownDocument("demo", "content/new.md", "# New\n")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.renameMarkdownDocument("demo", "demo-document", "content/renamed.md", "baseline")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.deleteMarkdownDocument("demo", "demo-document", "baseline")).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("uses a session-bound native image import contract and keeps it disabled in the browser demo", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.importWritingImage("session-1", "/tmp/cover.png", "document-1");
    expect(call).toHaveBeenCalledWith("import_writing_image", { sessionId: "session-1", sourcePath: "/tmp/cover.png", documentId: "document-1" });
    const demo = createRepositoryGateway();
    await expect(demo.importWritingImage("demo", "/tmp/cover.png", "demo-document")).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("uses session-bound commands for search, diff and trusted site preview", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.searchMarkdownFiles("session-1", "guide", 50);
    await gateway.gitFileDiff("session-1", "content/guide.md");
    await gateway.inspectSitePreview("session-1");
    await gateway.planSitePreview("session-1", { document: null, articlePath: null });
    await gateway.startSitePreview("session-1", "plan-1", true);
    await gateway.checkSitePreviewPage("session-1", "plan-1", "article");
    await gateway.stopSitePreview("session-1", "plan-1");
    expect(call).toHaveBeenCalledWith("search_markdown_files", { sessionId: "session-1", query: "guide", limit: 50 });
    expect(call).toHaveBeenCalledWith("git_file_diff", { sessionId: "session-1", relativePath: "content/guide.md" });
    expect(call).toHaveBeenCalledWith("inspect_site_preview", { sessionId: "session-1" });
    expect(call).toHaveBeenCalledWith("plan_site_preview", { sessionId: "session-1", request: { document: null, articlePath: null } });
    expect(call).toHaveBeenCalledWith("check_site_preview_page", { sessionId: "session-1", previewId: "plan-1", target: "article" });
    expect(call).toHaveBeenCalledWith("start_site_preview", { sessionId: "session-1", planId: "plan-1", confirmedTrustedRepository: true });
    expect(call).toHaveBeenCalledWith("stop_site_preview", { sessionId: "session-1", previewId: "plan-1" });
  });
  it("provides browser-only read-only fixtures for P1 commands", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.planSitePreview("demo", { document: null, articlePath: null })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.checkSitePreviewPage("demo", "plan", "home")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.startSitePreview("demo", "plan", true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.gitFileDiff("demo", "content/欢迎.md")).resolves.toMatchObject({ warnings: ["浏览器演示不读取 Git diff。"] });
    await expect(gateway.inspectSitePreview("demo")).resolves.toMatchObject({ supported: false, runtimeAvailable: false });
  });
  it("uses typed, session-bound P2 command arguments", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.credentialStatus("session-1");
    await gateway.storeRepositoryCredential({ sessionId: "session-1", provider: "github", host: "github.com", account: "octo", username: "octo", token: "never-log-this" });
    await gateway.deleteRepositoryCredential({ sessionId: "session-1", credentialId: "credential-1" });
    await gateway.planGitOperation({ sessionId: "session-1", operation: "commit", commitMessage: "docs: update" });
    await gateway.executeGitOperation({ sessionId: "session-1", planId: "plan-1" });
    await gateway.planGitIndexUpdate({ sessionId: "session-1", action: "stage", paths: ["content/a.md"] });
    await gateway.executeGitIndexUpdate({ sessionId: "session-1", planId: "index-plan-1" });
    await gateway.planRemoteReview({ sessionId: "session-1", provider: "gitlab", host: "gitlab.com", title: "Docs", body: null, baseBranch: "main", headBranch: "docs" });
    await gateway.executeRemoteReview({ sessionId: "session-1", planId: "review-1" });
    await gateway.checkDeployment("session-1"); await gateway.browserProtocolStatus("session-1"); await gateway.updateReadiness();
    await gateway.checkAppUpdate(); await gateway.installAppUpdate("update-plan-1");
    expect(call).toHaveBeenCalledWith("credential_status", { sessionId: "session-1" });
    expect(call).toHaveBeenCalledWith("store_repository_credential", { sessionId: "session-1", provider: "github", host: "github.com", account: "octo", username: "octo", token: "never-log-this" });
    expect(call).toHaveBeenCalledWith("delete_repository_credential", { sessionId: "session-1", credentialId: "credential-1" });
    expect(call).toHaveBeenCalledWith("plan_git_operation", { sessionId: "session-1", operation: "commit", commitMessage: "docs: update" });
    expect(call).toHaveBeenCalledWith("execute_git_operation", { sessionId: "session-1", planId: "plan-1" });
    expect(call).toHaveBeenCalledWith("plan_git_index_update", { sessionId: "session-1", action: "stage", paths: ["content/a.md"] });
    expect(call).toHaveBeenCalledWith("execute_git_index_update", { sessionId: "session-1", planId: "index-plan-1" });
    expect(call).toHaveBeenCalledWith("plan_remote_review", { sessionId: "session-1", provider: "gitlab", host: "gitlab.com", title: "Docs", body: null, baseBranch: "main", headBranch: "docs" });
    expect(call).toHaveBeenCalledWith("execute_remote_review", { sessionId: "session-1", planId: "review-1" });
    expect(call).toHaveBeenCalledWith("check_deployment", { sessionId: "session-1" });
    expect(call).toHaveBeenCalledWith("browser_protocol_status", { sessionId: "session-1" });
    expect(call).toHaveBeenCalledWith("update_readiness");
    expect(call).toHaveBeenCalledWith("check_app_update");
    expect(call).toHaveBeenCalledWith("install_app_update", { planId: "update-plan-1" });
  });
  it("never makes P2 browser demo actions executable", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.planGitOperation({ sessionId: "demo", operation: "push", commitMessage: null })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planGitIndexUpdate({ sessionId: "demo", action: "stage", paths: ["content/a.md"] })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.storeRepositoryCredential({ sessionId: "demo", provider: "github", host: "github.com", account: null, username: null, token: "token" })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.checkDeployment("demo")).resolves.toMatchObject({ configured: false });
    await expect(gateway.checkAppUpdate()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.installAppUpdate("plan-1")).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("uses bounded P3 native command contracts", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const config = { provider: "ollama_local" as const, endpoint: "http://127.0.0.1:11434/v1", model: "local" };
    await gateway.aiCredentialStatus(config);
    const selection = { documentId: "document-1", documentRevision: 1, selectionStart: 4, selectionEnd: 8 };
    await gateway.planAiEdit({ sessionId: "session-1", ...selection, ...config, sourceText: "选区😀", instruction: "润色" });
    await gateway.executeAiEdit({ sessionId: "session-1", planId: "plan-1", ...selection, ...config, sourceText: "选区😀", instruction: "润色" });
    await gateway.applyAiEdits({ sessionId: "session-1", documentId: "document-1", documentRevision: 1, selectionStart: 4, selectionEnd: 5, sourceText: "旧", proposals: [{ id: 0, range: { start: 0, end: 1 }, originalText: "旧", replacementText: "新" }], acceptedIds: [0] });
    await gateway.semanticIndexStatus("session-1"); await gateway.rebuildSemanticIndex("session-1"); await gateway.semanticSearch("session-1", "发布", 12);
    await gateway.documentCapabilities(); await gateway.selectPdf("/tmp/report.pdf"); await gateway.extractPdfText("pdf-token"); await gateway.extractPdfOcr("ocr-token", "eng+chi_sim");
    expect(call).toHaveBeenCalledWith("ai_credential_status", config);
    expect(call).toHaveBeenCalledWith("plan_ai_edit", { sessionId: "session-1", ...selection, ...config, sourceText: "选区😀", instruction: "润色" });
    expect(call).toHaveBeenCalledWith("execute_ai_edit", { sessionId: "session-1", planId: "plan-1", ...selection, ...config, sourceText: "选区😀", instruction: "润色" });
    expect(call).toHaveBeenCalledWith("semantic_search", { sessionId: "session-1", query: "发布", limit: 12 });
    expect(call).toHaveBeenCalledWith("select_pdf", { path: "/tmp/report.pdf" });
    expect(call).toHaveBeenCalledWith("extract_pdf_text", { token: "pdf-token" });
    expect(call).toHaveBeenCalledWith("extract_pdf_ocr", { token: "ocr-token", language: "eng+chi_sim" });
  });
  it("keeps every P3 browser demo mutation disabled", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.planAiEdit({ sessionId: "demo", documentId: "demo-document", documentRevision: 1, selectionStart: 0, selectionEnd: 1, provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "local", sourceText: "x", instruction: "rewrite" })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.rebuildSemanticIndex("demo")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.selectPdf("/tmp/report.pdf")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.extractPdfOcr("ocr-token", "eng")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.documentCapabilities()).resolves.toMatchObject({ pdfTextReady: false, ocr: { enabled: false } });
  });
  it("uses exact text translation command mappings and keeps browser demo fail-closed", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const request = { provider: "ollama_local" as const, endpoint: "http://127.0.0.1:11434", model: "qwen3", sourceLanguage: "en", targetLanguage: "zh-CN", text: "Hello" };
    const structuredRequest = { provider: request.provider, endpoint: request.endpoint, model: request.model, sourceLanguage: request.sourceLanguage, targetLanguage: request.targetLanguage, segments: [{ id: "title", text: "Hello" }, { id: "body.0", text: "World" }] };
    await gateway.planTextTranslation(request);
    await gateway.executeTextTranslation({ ...request, planId: "translation-plan-1" });
    await gateway.planStructuredTextTranslation(structuredRequest);
    await gateway.executeStructuredTextTranslation({ ...structuredRequest, planId: "structured-plan-1" });
    expect(call).toHaveBeenCalledWith("plan_text_translation", request);
    expect(call).toHaveBeenCalledWith("execute_text_translation", { ...request, planId: "translation-plan-1" });
    expect(call).toHaveBeenCalledWith("plan_structured_text_translation", structuredRequest);
    expect(call).toHaveBeenCalledWith("execute_structured_text_translation", { ...structuredRequest, planId: "structured-plan-1" });
    const demo = createRepositoryGateway();
    await expect(demo.planTextTranslation(request)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(demo.executeTextTranslation({ ...request, planId: "translation-plan-1" })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(demo.planStructuredTextTranslation(structuredRequest)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(demo.executeStructuredTextTranslation({ ...structuredRequest, planId: "structured-plan-1" })).rejects.toMatchObject({ code: "read_only_demo" });
  });
});
