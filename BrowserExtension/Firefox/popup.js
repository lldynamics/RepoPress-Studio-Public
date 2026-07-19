const extensionAPI = globalThis.browser ?? globalThis.chrome;

const tokenInput = document.querySelector("#token");
const connectButton = document.querySelector("#connect");
const connectionPanel = document.querySelector("#connection-panel");
const sessionPanel = document.querySelector("#session-panel");
const sessionTitle = document.querySelector("#session-title");
const tokenExpiry = document.querySelector("#token-expiry");
const disconnectButton = document.querySelector("#disconnect");
const rePairButton = document.querySelector("#re-pair");
const savePanel = document.querySelector("#save-panel");
const organizationPanel = document.querySelector("#organization-panel");
const folderSelect = document.querySelector("#folder");
const folderSearchInput = document.querySelector("#folder-search");
const folderShortcuts = document.querySelector("#folder-shortcuts");
const favoriteFolderButton = document.querySelector("#favorite-folder");
const newFolderInput = document.querySelector("#new-folder");
const rememberDomainInput = document.querySelector("#remember-domain");
const rememberDomainLabel = document.querySelector("#remember-domain-label");
const organizationSuggestions = document.querySelector("#organization-suggestions");
const folderSuggestions = document.querySelector("#folder-suggestions");
const tagSuggestions = document.querySelector("#tag-suggestions");
const captureModeInputs = Array.from(document.querySelectorAll("input[name='capture-mode']"));
const preparePreviewButton = document.querySelector("#prepare-preview");
const batchSaveButton = document.querySelector("#batch-save");
const batchHint = document.querySelector("#batch-hint");
const previewPanel = document.querySelector("#preview-panel");
const previewMode = document.querySelector("#preview-mode");
const previewSize = document.querySelector("#preview-size");
const previewArchive = document.querySelector("#preview-archive");
const captureTitleInput = document.querySelector("#capture-title");
const captureAuthorsInput = document.querySelector("#capture-authors");
const captureTagsInput = document.querySelector("#capture-tags");
const captureAIInput = document.querySelector("#capture-ai");
const capturePreviewText = document.querySelector("#capture-preview");
const editCaptureButton = document.querySelector("#edit-capture");
const saveButton = document.querySelector("#save");
const statusLabel = document.querySelector("#status");
const pageTitle = document.querySelector("#page-title");
const main = document.querySelector("main");
const queuePanel = document.querySelector("#queue-panel");
const queueCount = document.querySelector("#queue-count");
const queueSummaryLabel = document.querySelector("#queue-summary");
const retryQueueButton = document.querySelector("#retry-queue");
const discardQueueButton = document.querySelector("#discard-queue");
const receiptPanel = document.querySelector("#receipt-panel");
const receiptTitle = document.querySelector("#receipt-title");
const receiptFolder = document.querySelector("#receipt-folder");
const receiptSize = document.querySelector("#receipt-size");
const receiptArchive = document.querySelector("#receipt-archive");
const receiptIndex = document.querySelector("#receipt-index");
const receiptAI = document.querySelector("#receipt-ai");
const openDocumentButton = document.querySelector("#open-document");
const duplicatePanel = document.querySelector("#duplicate-panel");
const duplicateMessage = document.querySelector("#duplicate-message");
const duplicateDocument = document.querySelector("#duplicate-document");
const duplicateFolder = document.querySelector("#duplicate-folder");
const duplicateSize = document.querySelector("#duplicate-size");
const duplicateUpdated = document.querySelector("#duplicate-updated");
const duplicateTarget = document.querySelector("#duplicate-target");
const duplicateNewVersionButton = document.querySelector("#duplicate-new-version");
const duplicateMoveButton = document.querySelector("#duplicate-move");
const duplicateCopyButton = document.querySelector("#duplicate-copy");
const duplicateCancelButton = document.querySelector("#duplicate-cancel");

let activeTab = null;
let lastReceipt = null;
let activeDuplicateConflict = null;
let preparedCapture = null;
let connectionState = "disconnected";
let allKnowledgeFolders = [];
let favoriteFolderIDs = new Set();
let recentFolderIDs = [];
let domainFolderMap = {};
let defaultAllowsAIUse = true;
let highlightedTabs = [];

document.addEventListener("DOMContentLoaded", async () => {
  setConnectionState("disconnected");
  try {
    await refreshQueueStatus();
    [activeTab] = await extensionAPI.tabs.query({ active: true, currentWindow: true });
    await refreshHighlightedTabs();
    pageTitle.textContent = activeTab?.title || "当前页面";
    const stored = await extensionAPI.storage.local.get([
      "bridgeToken",
      "bridgeTokenExpiresAtV1",
      "cachedKnowledgeFolders",
      "selectedKnowledgeFolderID",
      "preferredKnowledgeCaptureModeV1",
      "favoriteKnowledgeFolderIDsV1",
      "recentKnowledgeFolderIDsV1",
      "knowledgeDomainFoldersV1",
      "defaultKnowledgeAllowsAIUseV1",
      "lastKnowledgeSaveReceiptV1"
    ]);
    const preferredMode = stored.preferredKnowledgeCaptureModeV1 || "cleaned-article";
    const preferredInput = captureModeInputs.find((input) => input.value === preferredMode);
    if (preferredInput) preferredInput.checked = true;
    favoriteFolderIDs = new Set(stored.favoriteKnowledgeFolderIDsV1 || []);
    recentFolderIDs = Array.isArray(stored.recentKnowledgeFolderIDsV1)
      ? stored.recentKnowledgeFolderIDsV1
      : [];
    domainFolderMap = stored.knowledgeDomainFoldersV1 || {};
    defaultAllowsAIUse = stored.defaultKnowledgeAllowsAIUseV1 !== false;
    allKnowledgeFolders = stored.cachedKnowledgeFolders || [];
    const rememberedFolderID = domainFolderMap[currentPageDomain()] || "";
    populateFolderOptions(
      allKnowledgeFolders,
      rememberedFolderID || stored.selectedKnowledgeFolderID || ""
    );
    rememberDomainInput.checked = Boolean(rememberedFolderID);
    updateDomainMemoryLabel();
    renderFolderShortcuts();
    updateFavoriteFolderButton();
    showReceipt(stored.lastKnowledgeSaveReceiptV1 || null);
    if (stored.bridgeToken) {
      tokenInput.value = stored.bridgeToken;
      updateTokenExpiry(stored.bridgeTokenExpiresAtV1);
      await connect();
    }
  } catch (error) {
    setConnectionState("disconnected");
    showStatus(readableError(error), "error");
  }
});

connectButton.addEventListener("click", connect);
disconnectButton.addEventListener("click", () => disconnectFromBridge(false));
rePairButton.addEventListener("click", () => disconnectFromBridge(true));
preparePreviewButton.addEventListener("click", prepareCapturePreview);
batchSaveButton.addEventListener("click", batchSaveSelectedTabs);
saveButton.addEventListener("click", saveCurrentPage);
editCaptureButton.addEventListener("click", invalidateCapturePreview);
retryQueueButton.addEventListener("click", retryCaptureQueue);
discardQueueButton.addEventListener("click", discardCaptureQueue);
openDocumentButton.addEventListener("click", openSavedDocument);
duplicateNewVersionButton.addEventListener("click", () => resolveDuplicateCapture("save-new-version"));
duplicateMoveButton.addEventListener("click", () => resolveDuplicateCapture("move-only"));
duplicateCopyButton.addEventListener("click", () => resolveDuplicateCapture("keep-copy"));
duplicateCancelButton.addEventListener("click", cancelDuplicateCapture);
folderSelect.addEventListener("change", () => {
  const selectedFolderID = folderSelect.value;
  folderSearchInput.value = "";
  populateFolderOptions(allKnowledgeFolders, selectedFolderID);
  extensionAPI.storage.local.set({ selectedKnowledgeFolderID: folderSelect.value }).catch(() => {});
  updateFavoriteFolderButton();
  updateRememberedDomainChoice();
});
folderSearchInput.addEventListener("input", () => {
  populateFolderOptions(allKnowledgeFolders, folderSelect.value, folderSearchInput.value);
});
favoriteFolderButton.addEventListener("click", toggleFavoriteFolder);
rememberDomainInput.addEventListener("change", updateRememberedDomainChoice);
newFolderInput.addEventListener("input", () => {
  const usesNewFolder = newFolderInput.value.trim().length > 0;
  folderSelect.disabled = usesNewFolder;
  folderSearchInput.disabled = usesNewFolder;
  favoriteFolderButton.disabled = usesNewFolder || !folderSelect.value;
});
for (const input of captureModeInputs) {
  input.addEventListener("change", () => {
    if (!input.checked) return;
    invalidateCapturePreview();
    extensionAPI.storage.local.set({ preferredKnowledgeCaptureModeV1: input.value }).catch(() => {});
  });
}
document.addEventListener("keydown", handlePopupKeyboardShortcut);

async function connect() {
  const token = tokenInput.value.trim();
  if (!token) {
    setConnectionState("disconnected");
    showStatus("请先粘贴应用连接令牌。", "error");
    tokenInput.focus();
    return;
  }
  setConnectionState("connecting");
  setBusy(connectButton, true, "连接中…");
  try {
    const response = await bridgeFetch("/v1/folders", token);
    allKnowledgeFolders = response.folders || [];
    const rememberedFolderID = domainFolderMap[currentPageDomain()] || "";
    populateFolderOptions(
      allKnowledgeFolders,
      rememberedFolderID || folderSelect.value
    );
    renderFolderShortcuts();
    updateFavoriteFolderButton();
    await extensionAPI.storage.local.set({
      bridgeToken: token,
      bridgeTokenExpiresAtV1: response.tokenExpiresAt || null,
      cachedKnowledgeFolders: allKnowledgeFolders,
      selectedKnowledgeFolderID: folderSelect.value
    });
    updateTokenExpiry(response.tokenExpiresAt);
    setConnectionState("connected");
    const retry = await sendRuntimeMessage({
      type: "retry-capture-queue",
      token,
      force: true
    });
    await refreshQueueStatus();
    const latestReceipt = retry.receipts?.[retry.receipts.length - 1];
    if (latestReceipt) {
      await rememberOrganizationChoice(latestReceipt);
      await rememberReceipt(latestReceipt);
    }
    showStatus(
      retry.importedCount > 0
        ? `已连接，并将 ${retry.importedCount} 项待保存内容写入资料库。`
        : "已连接到本机资料库。",
      retry.importedCount > 0 ? "success" : ""
    );
  } catch (error) {
    if (["token-expired", "invalid-token"].includes(error?.code)) {
      await clearStoredBridgeToken();
      setConnectionState("disconnected");
      showStatus(
        error.code === "token-expired"
          ? "连接令牌已过期。请从应用复制新令牌重新配对。"
          : "连接令牌无效。请从应用重新复制令牌进行配对。",
        "error"
      );
      tokenInput.focus();
    } else if (token && isNetworkFailure(error)) {
      setConnectionState("offline");
      showStatus("应用当前未连接；仍可先保存，恢复连接后会自动写入资料库。", "warning");
    } else {
      setConnectionState("disconnected");
      showStatus(readableError(error), "error");
    }
  } finally {
    setBusy(connectButton, false, "连接");
  }
}

async function disconnectFromBridge(isRePair) {
  await clearStoredBridgeToken();
  tokenInput.value = "";
  tokenExpiry.textContent = "未配对";
  invalidateCapturePreview();
  setConnectionState("disconnected");
  showStatus(
    isRePair
      ? "旧令牌已从插件中清除，请粘贴应用当前显示的新令牌。"
      : "已断开并清除连接令牌；待保存队列和分类偏好未被删除。",
    isRePair ? "warning" : ""
  );
  if (isRePair) tokenInput.focus();
}

async function clearStoredBridgeToken() {
  await extensionAPI.storage.local.remove([
    "bridgeToken",
    "bridgeTokenExpiresAtV1"
  ]).catch(() => {});
}

function updateTokenExpiry(value) {
  if (!value) {
    tokenExpiry.textContent = "应用未提供令牌有效期，请重新配对。";
    return;
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    tokenExpiry.textContent = "令牌有效期无法读取，请重新配对。";
    return;
  }
  tokenExpiry.textContent = `令牌有效至 ${date.toLocaleString("zh-CN", {
    dateStyle: "medium",
    timeStyle: "short"
  })}`;
}

function populateFolderOptions(folders, selectedFolderID, query = "") {
  folderSelect.replaceChildren(new Option("未分类", ""));
  const normalizedQuery = String(query || "").trim().toLocaleLowerCase("zh-CN");
  for (const folder of folders) {
    const matchesQuery = !normalizedQuery
      || folder?.name?.toLocaleLowerCase("zh-CN").includes(normalizedQuery);
    if (folder?.id && folder?.name && (matchesQuery || folder.id === selectedFolderID)) {
      folderSelect.add(new Option(folder.name, folder.id));
    }
  }
  const hasSelection = Array.from(folderSelect.options || [])
    .some((option) => option.value === selectedFolderID);
  folderSelect.value = hasSelection ? selectedFolderID : "";
}

function currentPageDomain() {
  try {
    const host = new URL(preparedCapture?.capture?.sourceURL || activeTab?.url || "").hostname
      .toLocaleLowerCase("en-US");
    return host.startsWith("www.") ? host.slice(4) : host;
  } catch {
    return "";
  }
}

function updateDomainMemoryLabel() {
  const domain = currentPageDomain();
  rememberDomainLabel.textContent = domain
    ? `记住 ${domain} 的分类选择`
    : "记住此网站的分类选择";
  rememberDomainInput.disabled = !domain;
}

function selectFolder(folderID, announce = false) {
  newFolderInput.value = "";
  folderSelect.disabled = false;
  folderSearchInput.disabled = false;
  folderSearchInput.value = "";
  populateFolderOptions(allKnowledgeFolders, folderID);
  extensionAPI.storage.local.set({ selectedKnowledgeFolderID: folderSelect.value }).catch(() => {});
  updateFavoriteFolderButton();
  updateRememberedDomainChoice();
  if (announce) {
    const folder = allKnowledgeFolders.find((item) => item.id === folderID);
    showStatus(`已选择分类“${folder?.name || "未分类"}”，保存前仍可更改。`);
  }
}

function renderFolderShortcuts() {
  folderShortcuts.replaceChildren();
  const appendGroup = (label, folderIDs) => {
    const available = folderIDs
      .map((folderID) => allKnowledgeFolders.find((folder) => folder.id === folderID))
      .filter(Boolean);
    if (!available.length) return;
    const labelNode = document.createElement("span");
    labelNode.className = "shortcut-label";
    labelNode.textContent = label;
    folderShortcuts.append(labelNode);
    for (const folder of available) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "folder-chip";
      button.textContent = folder.name;
      button.addEventListener("click", () => selectFolder(folder.id, true));
      folderShortcuts.append(button);
    }
  };
  appendGroup("收藏", Array.from(favoriteFolderIDs));
  appendGroup("最近", recentFolderIDs.filter((id) => !favoriteFolderIDs.has(id)).slice(0, 4));
  folderShortcuts.hidden = !folderShortcuts.children.length;
}

function updateFavoriteFolderButton() {
  const folderID = folderSelect.value;
  const isFavorite = Boolean(folderID) && favoriteFolderIDs.has(folderID);
  favoriteFolderButton.disabled = !folderID || newFolderInput.value.trim().length > 0;
  favoriteFolderButton.setAttribute("aria-pressed", String(isFavorite));
  favoriteFolderButton.textContent = isFavorite ? "★ 已收藏" : "☆ 收藏";
}

async function toggleFavoriteFolder() {
  const folderID = folderSelect.value;
  if (!folderID) return;
  if (favoriteFolderIDs.has(folderID)) favoriteFolderIDs.delete(folderID);
  else favoriteFolderIDs.add(folderID);
  updateFavoriteFolderButton();
  renderFolderShortcuts();
  await extensionAPI.storage.local.set({
    favoriteKnowledgeFolderIDsV1: Array.from(favoriteFolderIDs)
  }).catch(() => {});
}

async function updateRememberedDomainChoice() {
  const domain = currentPageDomain();
  if (!domain) return;
  if (rememberDomainInput.checked && folderSelect.value && !newFolderInput.value.trim()) {
    domainFolderMap[domain] = folderSelect.value;
  } else if (!rememberDomainInput.checked) {
    delete domainFolderMap[domain];
  }
  await extensionAPI.storage.local.set({ knowledgeDomainFoldersV1: domainFolderMap }).catch(() => {});
}

function selectedCaptureMode() {
  return captureModeInputs.find((input) => input.checked)?.value || "cleaned-article";
}

async function refreshHighlightedTabs() {
  highlightedTabs = (await extensionAPI.tabs.query({ highlighted: true, currentWindow: true }))
    .filter((tab) => Number.isInteger(tab.id));
  const count = highlightedTabs.length;
  batchSaveButton.disabled = count < 2;
  batchSaveButton.textContent = count > 1
    ? `批量保存 ${Math.min(count, 10)} 个已选择标签页`
    : "批量保存已选择标签页";
  batchHint.textContent = count > 10
    ? `已选择 ${count} 个标签页；为控制空间，本次只处理前 10 个。`
    : count > 1
      ? "批量保存会使用当前采集模式、分类和默认 AI 权限。"
      : "在浏览器标签栏按住 Command/Ctrl 选择多个标签页。";
}

async function batchSaveSelectedTabs() {
  await refreshHighlightedTabs();
  if (highlightedTabs.length < 2) {
    showStatus("请先在标签栏选择至少两个网页。", "error");
    return;
  }
  const captureMode = selectedCaptureMode();
  if (captureMode === "selection") {
    showStatus("批量保存不能使用“选中文字”模式。", "error");
    return;
  }
  const permissionMessage = "批量读取非当前标签页需要临时授予网页访问权限。是否继续？";
  if (!globalThis.confirm(permissionMessage)) return;
  const granted = await extensionAPI.permissions.request({
    origins: ["http://*/*", "https://*/*"]
  });
  if (!granted) {
    showStatus("未获得网页访问权限，批量保存已取消。", "error");
    return;
  }
  await refreshHighlightedTabs();
  const tabIDs = highlightedTabs.map((tab) => tab.id).slice(0, 10);
  setBusy(batchSaveButton, true, "正在批量保存…");
  try {
    const result = await sendRuntimeMessage({
      type: "capture-tabs-batch",
      tabIDs,
      token: tokenInput.value.trim(),
      captureMode,
      folderID: newFolderInput.value.trim() ? null : (folderSelect.value || null),
      newFolderName: newFolderInput.value.trim() || null,
      allowsAIUse: defaultAllowsAIUse
    });
    const latestReceipt = result.receipts?.[result.receipts.length - 1];
    if (latestReceipt) {
      await rememberOrganizationChoice(latestReceipt);
      await rememberReceipt(latestReceipt);
    }
    await refreshQueueStatus();
    const details = [
      `${result.savedCount || 0} 项已保存`,
      result.conflictCount ? `${result.conflictCount} 项待确认重复处理` : "",
      result.queuedDuringBatch ? `${result.queuedDuringBatch} 项进入离线队列` : "",
      result.failedCount ? `${result.failedCount} 项失败` : ""
    ].filter(Boolean).join("，");
    showStatus(
      `批量处理完成：${details}。`,
      result.failedCount ? "error" : result.conflictCount || result.queuedDuringBatch ? "warning" : "success"
    );
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    batchSaveButton.setAttribute("aria-busy", "false");
    await refreshHighlightedTabs();
  }
}

function handlePopupKeyboardShortcut(event) {
  const accelerator = event.metaKey || event.ctrlKey;
  if (accelerator && event.key === "Enter" && !previewPanel.hidden && !saveButton.disabled) {
    event.preventDefault();
    saveButton.click();
    return;
  }
  if (accelerator && event.shiftKey && event.key.toLocaleLowerCase("en-US") === "b"
      && !batchSaveButton.disabled) {
    event.preventDefault();
    batchSaveButton.click();
    return;
  }
  if (event.key === "Escape" && !previewPanel.hidden && !saveButton.disabled) {
    event.preventDefault();
    invalidateCapturePreview();
    preparePreviewButton.focus();
  }
}

function invalidateCapturePreview() {
  preparedCapture = null;
  previewPanel.hidden = true;
  organizationSuggestions.hidden = true;
  if (connectionState === "connected" || connectionState === "offline") {
    savePanel.hidden = false;
  }
}

async function prepareCapturePreview() {
  if (!activeTab?.id || !/^https?:/i.test(activeTab.url || "")) {
    showStatus("只能保存 HTTP 或 HTTPS 网页。", "error");
    return;
  }
  setBusy(preparePreviewButton, true, "正在生成预览…");
  showStatus("正在读取页面并生成本地预览…");
  try {
    const result = await sendRuntimeMessage({
      type: "prepare-capture-preview",
      tabId: activeTab.id,
      captureMode: selectedCaptureMode()
    });
    preparedCapture = result;
    updateDomainMemoryLabel();
    captureTitleInput.value = result.capture.title || "";
    captureAuthorsInput.value = (result.capture.authors || []).join("，");
    captureTagsInput.value = (result.capture.tags || []).join("，");
    captureAIInput.checked = defaultAllowsAIUse;
    capturePreviewText.value = result.previewText || result.capture.contentText || "";
    previewMode.textContent = captureModeLabel(result.captureMode);
    previewSize.textContent = `预计大小 ${formatBytes(Number(result.estimatedSizeBytes || 0))}`;
    previewArchive.textContent = archiveTypeLabel(result.archiveType);
    savePanel.hidden = true;
    previewPanel.hidden = false;
    captureTitleInput.focus();
    showStatus("预览已生成；确认元数据和 AI 权限后再保存。", "success");
    loadOrganizationSuggestions(result.capture).catch(() => {
      organizationSuggestions.hidden = true;
    });
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(preparePreviewButton, false, "生成保存预览");
  }
}

async function saveCurrentPage() {
  if (!preparedCapture?.capture || !activeTab?.id) {
    showStatus("请先生成保存预览。", "error");
    return;
  }
  const title = captureTitleInput.value.trim();
  if (!title) {
    showStatus("标题不能为空。", "error");
    captureTitleInput.focus();
    return;
  }
  setBusy(saveButton, true, "正在保存…");
  showStatus(preparedCapture.captureMode === "full-page"
    ? "正在生成离线网页归档并保存…"
    : "正在保存并建立索引…");
  try {
    const token = tokenInput.value.trim();
    defaultAllowsAIUse = captureAIInput.checked;
    await extensionAPI.storage.local.set({
      defaultKnowledgeAllowsAIUseV1: defaultAllowsAIUse
    }).catch(() => {});
    const result = await sendRuntimeMessage({
      type: "save-prepared-capture",
      tabId: activeTab.id,
      token,
      captureMode: preparedCapture.captureMode,
      capture: {
        ...preparedCapture.capture,
        title,
        authors: splitMetadata(captureAuthorsInput.value, 30),
        tags: splitMetadata(captureTagsInput.value, 50),
        allowsAIUse: captureAIInput.checked
      },
      folderID: newFolderInput.value.trim() ? null : (folderSelect.value || null),
      newFolderName: newFolderInput.value.trim() || null
    });
    await rememberOrganizationChoice(result);
    if (result.requiresDuplicateResolution) {
      await refreshQueueStatus();
      showStatus("该网址已在资料库中，请选择如何处理。", "warning");
      return;
    }
    if (result.queued) {
      setConnectionState("offline");
      await refreshQueueStatus();
      invalidateCapturePreview();
      showStatus(
        `应用尚未连接，网页已安全加入待保存队列（共 ${result.queuedCount} 项）。`,
        "warning"
      );
      return;
    }
    const action = result.insertedCount > 0
      ? "新增"
      : result.updatedCount > 0
        ? "更新"
        : "已存在";
    await rememberReceipt(result);
    invalidateCapturePreview();
    const report = result.archiveReport;
    if (report?.format === "html" && report.missingResourceCount > 0) {
      const truncated = report.wasTruncated ? "，并已按 24 MB 上限精简" : "";
      showStatus(
        `已保存到长期参考（${action}），已内联 ${report.embeddedResourceCount} 项；${report.missingResourceCount} 项外部资源未能离线保存${truncated}。`,
        "warning"
      );
    } else if (report?.format === "html") {
      showStatus(
        `已保存到长期参考（${action}），自包含归档已内联 ${report.embeddedResourceCount} 项资源，可离线打开。`,
        "success"
      );
    } else {
      showStatus(`已保存到长期参考（${action}）。`, "success");
    }
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(saveButton, false, "确认保存");
  }
}

function splitMetadata(value, maximumCount) {
  return String(value || "")
    .split(/[,，;；\n]/)
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, maximumCount);
}

function captureModeLabel(value) {
  switch (value) {
  case "full-page": return "完整网页：正文 + 离线页面归档";
  case "selection": return "选中文字：只保存当前选择内容";
  case "link-only": return "仅链接：标题 + 原始网址";
  default: return "净化正文：已去除常见页面噪声";
  }
}

async function loadOrganizationSuggestions(capture) {
  folderSuggestions.replaceChildren();
  tagSuggestions.replaceChildren();
  organizationSuggestions.hidden = true;
  const token = tokenInput.value.trim();
  if (!token || connectionState !== "connected") return;
  const result = await bridgePost("/v1/suggestions", token, {
    sourceURL: capture.sourceURL,
    authors: capture.authors || [],
    tags: capture.tags || []
  });
  for (const suggestion of result.folders || []) {
    if (!suggestion?.folder?.id || !suggestion.folder.name) continue;
    const button = document.createElement("button");
    button.type = "button";
    button.className = "suggestion-chip";
    button.textContent = `${suggestion.folder.name} · ${suggestionReasonLabel(suggestion.reasons)}`;
    button.addEventListener("click", () => selectFolder(suggestion.folder.id, true));
    folderSuggestions.append(button);
  }
  for (const tag of result.tags || []) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "suggestion-chip";
    button.textContent = `+ ${tag}`;
    button.addEventListener("click", () => applySuggestedTag(tag));
    tagSuggestions.append(button);
  }
  organizationSuggestions.hidden = !(folderSuggestions.children.length || tagSuggestions.children.length);
}

function suggestionReasonLabel(reasons) {
  const labels = [];
  if (reasons?.includes("source-domain")) labels.push("同来源");
  if (reasons?.includes("author")) labels.push("同作者");
  if (reasons?.includes("tag")) labels.push("同标签");
  return labels.join("、") || "相关资料";
}

function applySuggestedTag(tag) {
  const tags = splitMetadata(captureTagsInput.value, 50);
  if (!tags.some((item) => item.toLocaleLowerCase("zh-CN") === tag.toLocaleLowerCase("zh-CN"))) {
    tags.push(tag);
    captureTagsInput.value = tags.join("，");
  }
  showStatus(`已添加建议标签“${tag}”，确认保存后才会写入资料。`);
}

async function rememberOrganizationChoice(receipt) {
  const receiptFolder = receipt?.folder;
  if (receiptFolder?.id && receiptFolder.name
      && !allKnowledgeFolders.some((folder) => folder.id === receiptFolder.id)) {
    allKnowledgeFolders.push(receiptFolder);
  }
  const folderID = receiptFolder?.id
    || (newFolderInput.value.trim() ? "" : folderSelect.value);
  if (folderID) {
    recentFolderIDs = [folderID, ...recentFolderIDs.filter((id) => id !== folderID)].slice(0, 6);
  }
  const domain = currentPageDomain();
  if (domain && rememberDomainInput.checked && folderID) {
    domainFolderMap[domain] = folderID;
  }
  if (receiptFolder?.id) {
    selectFolder(receiptFolder.id);
  }
  renderFolderShortcuts();
  await extensionAPI.storage.local.set({
    cachedKnowledgeFolders: allKnowledgeFolders,
    recentKnowledgeFolderIDsV1: recentFolderIDs,
    knowledgeDomainFoldersV1: domainFolderMap,
    selectedKnowledgeFolderID: folderID || folderSelect.value
  }).catch(() => {});
}

async function retryCaptureQueue() {
  const token = tokenInput.value.trim();
  if (!token) {
    showStatus("请先填写应用连接令牌。", "error");
    tokenInput.focus();
    return;
  }
  setBusy(retryQueueButton, true, "重试中…");
  try {
    const result = await sendRuntimeMessage({
      type: "retry-capture-queue",
      token,
      force: true
    });
    await refreshQueueStatus();
    const latestReceipt = result.receipts?.[result.receipts.length - 1];
    if (latestReceipt) {
      await rememberOrganizationChoice(latestReceipt);
      await rememberReceipt(latestReceipt);
    }
    if (result.queuedCount === 0) {
      setConnectionState("connected");
      showStatus(`重试完成，已导入 ${result.importedCount} 项内容。`, "success");
    } else {
      showStatus(
        `已导入 ${result.importedCount} 项，仍有 ${result.queuedCount} 项待处理。`,
        result.blockedCount > 0 ? "error" : "warning"
      );
    }
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(retryQueueButton, false, "立即重试");
  }
}

async function resolveDuplicateCapture(resolution) {
  const token = tokenInput.value.trim();
  if (!activeDuplicateConflict?.queueID || !token) {
    showStatus("请先重新连接应用。", "error");
    return;
  }
  setDuplicateBusy(true);
  try {
    const result = await sendRuntimeMessage({
      type: "resolve-duplicate-capture",
      queueID: activeDuplicateConflict.queueID,
      resolution,
      token
    });
    await rememberOrganizationChoice(result.receipt);
    await rememberReceipt(result.receipt);
    activeDuplicateConflict = null;
    duplicatePanel.hidden = true;
    await refreshQueueStatus();
    const message = resolution === "save-new-version"
      ? "已将本次采集保存为新版本。"
      : resolution === "move-only"
        ? "已移动原资料的分类，未创建新版本。"
        : "已保留一份独立副本。";
    showStatus(message, "success");
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setDuplicateBusy(false);
  }
}

async function cancelDuplicateCapture() {
  if (!activeDuplicateConflict?.queueID) return;
  setDuplicateBusy(true);
  try {
    await sendRuntimeMessage({
      type: "cancel-duplicate-capture",
      queueID: activeDuplicateConflict.queueID
    });
    activeDuplicateConflict = null;
    duplicatePanel.hidden = true;
    await refreshQueueStatus();
    showStatus("已取消，本次网页没有写入资料库。");
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setDuplicateBusy(false);
  }
}

function setDuplicateBusy(busy) {
  duplicatePanel.setAttribute("aria-busy", String(busy));
  for (const button of [
    duplicateNewVersionButton,
    duplicateMoveButton,
    duplicateCopyButton,
    duplicateCancelButton
  ]) {
    button.disabled = busy;
  }
}

async function openSavedDocument() {
  const token = tokenInput.value.trim();
  if (!lastReceipt?.documentID || !token) {
    showStatus("请先重新连接应用。", "error");
    return;
  }
  setBusy(openDocumentButton, true, "正在打开…");
  try {
    await sendRuntimeMessage({
      type: "open-knowledge-document",
      documentID: lastReceipt.documentID,
      token
    });
    showStatus("已在资料库中打开。", "success");
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(openDocumentButton, false, "在资料库中打开");
  }
}

async function rememberReceipt(receipt) {
  showReceipt(receipt);
  await extensionAPI.storage.local.set({ lastKnowledgeSaveReceiptV1: receipt }).catch(() => {});
}

function showReceipt(receipt) {
  if (!receipt?.documentID) {
    lastReceipt = null;
    receiptPanel.hidden = true;
    return;
  }
  lastReceipt = receipt;
  receiptPanel.hidden = false;
  receiptTitle.textContent = receipt.title || "未命名资料";
  receiptFolder.textContent = receipt.folder?.name || "未分类";
  receiptSize.textContent = formatBytes(Number(receipt.fileSizeBytes || 0));
  receiptArchive.textContent = archiveTypeLabel(receipt.archiveType);
  receiptIndex.textContent = receipt.indexStatus === "ready"
    ? "全文与语义索引已就绪"
    : "等待建立索引";
  receiptAI.textContent = receipt.allowsAIUse === false ? "不允许 AI 使用" : "允许 AI 检索";
}

function archiveTypeLabel(value) {
  switch (String(value || "none").toLowerCase()) {
  case "mhtml": return "MHTML 完整网页";
  case "html": return "离线 HTML";
  default: return "仅正文";
  }
}

async function discardCaptureQueue() {
  if (!globalThis.confirm("确定清空所有尚未写入资料库的网页？此操作无法撤销。")) {
    return;
  }
  setBusy(discardQueueButton, true, "清理中…");
  try {
    await sendRuntimeMessage({ type: "discard-capture-queue" });
    await refreshQueueStatus();
    showStatus("待保存队列已清空。");
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(discardQueueButton, false, "清空队列");
  }
}

async function refreshQueueStatus() {
  try {
    const result = await sendRuntimeMessage({ type: "capture-queue-status" });
    updateQueuePanel(result);
    showDuplicateConflict(result.duplicateConflicts?.[0] || null);
    return result;
  } catch {
    updateQueuePanel({ queuedCount: 0, blockedCount: 0, totalBytes: 0 });
    showDuplicateConflict(null);
    return null;
  }
}

function showDuplicateConflict(item) {
  if (!item?.queueID || !item.conflict) {
    activeDuplicateConflict = null;
    duplicatePanel.hidden = true;
    return;
  }
  activeDuplicateConflict = item;
  const conflict = item.conflict;
  duplicatePanel.hidden = false;
  duplicateMessage.textContent = conflict.incomingHasChanges
    ? "本次采集的正文与现有资料不同。"
    : "本次采集的内容与现有资料相同。";
  duplicateDocument.textContent = conflict.title || "未命名资料";
  duplicateFolder.textContent = conflict.folder?.name || "未分类";
  duplicateSize.textContent = formatBytes(Number(conflict.fileSizeBytes || 0));
  duplicateUpdated.textContent = conflict.updatedAt
    ? new Date(conflict.updatedAt).toLocaleString("zh-CN", { dateStyle: "short", timeStyle: "short" })
    : "未知";
  const targetOption = Array.from(folderSelect.options || [])
    .find((option) => option.value === item.targetFolderID);
  duplicateTarget.textContent = item.targetNewFolderName
    || targetOption?.text
    || "未分类";
}

function updateQueuePanel(result) {
  const count = Number(result?.queuedCount || 0);
  const blocked = Number(result?.blockedCount || 0);
  queuePanel.hidden = count === 0;
  queueCount.textContent = String(count);
  const size = formatBytes(Number(result?.totalBytes || 0));
  queueSummaryLabel.textContent = blocked > 0
    ? `${count} 项 · ${size}；其中 ${blocked} 项需要手动重试或清理。`
    : `${count} 项 · ${size}；应用恢复后会自动重试。`;
}

function formatBytes(bytes) {
  if (bytes < 1_024) return `${bytes} B`;
  if (bytes < 1_024 * 1_024) return `${(bytes / 1_024).toFixed(1)} KB`;
  return `${(bytes / (1_024 * 1_024)).toFixed(1)} MB`;
}

async function sendRuntimeMessage(message) {
  const response = await extensionAPI.runtime.sendMessage(message);
  if (!response?.ok) {
    const error = new Error(response?.error || "插件后台处理失败。");
    error.code = response?.code || null;
    if (["token-expired", "invalid-token"].includes(error.code)) {
      await clearStoredBridgeToken();
      tokenInput.value = "";
      setConnectionState("disconnected");
      tokenInput.focus();
    }
    throw error;
  }
  return response.result;
}

async function bridgeFetch(path, token) {
  return sendRuntimeMessage({
    type: "bridge-request",
    path,
    method: "GET",
    token
  });
}

async function bridgePost(path, token, body) {
  return sendRuntimeMessage({
    type: "bridge-request",
    path,
    method: "POST",
    token,
    body
  });
}

function setBusy(button, busy, label) {
  button.disabled = busy;
  button.textContent = label;
  button.setAttribute("aria-busy", String(busy));
}

function setConnectionState(state) {
  connectionState = state;
  const connected = state === "connected";
  const connecting = state === "connecting";
  const offline = state === "offline";
  connectionPanel.hidden = connected || offline;
  sessionPanel.hidden = !(connected || offline);
  sessionTitle.textContent = offline ? "已保存配对令牌，应用离线" : "已连接本机资料库";
  const available = connected || offline;
  savePanel.hidden = !available || Boolean(preparedCapture);
  organizationPanel.hidden = !available;
  previewPanel.hidden = !available || !preparedCapture;
  saveButton.disabled = !(connected || offline);
  batchSaveButton.disabled = !available || highlightedTabs.length < 2;
  main.setAttribute("aria-busy", String(connecting));
  extensionAPI.runtime.sendMessage({
    type: "toolbar-state",
    state,
    message: state === "offline" ? "应用未运行，保存内容会进入队列" : ""
  }).catch(() => {});
}

function showStatus(message, kind = "") {
  statusLabel.textContent = message;
  statusLabel.className = kind;
  statusLabel.setAttribute("role", kind === "error" ? "alert" : "status");
  statusLabel.setAttribute("aria-live", kind === "error" ? "assertive" : "polite");
}

function readableError(error) {
  const message = String(error?.message || error);
  if (/failed to fetch|networkerror|network request failed|load failed|connection refused/i.test(message)) {
    return "无法连接应用。请先打开“个人网站发布控制台”，再检查令牌。";
  }
  return error?.message || String(error);
}

function isNetworkFailure(error) {
  return error?.code === "native-host-error"
    || /failed to fetch|networkerror|network request failed|load failed|connection refused/i
    .test(String(error?.message || error));
}
