const extensionAPI = globalThis.browser ?? globalThis.chrome;
const uiLocale = extensionAPI.i18n?.getUILanguage?.() || "zh-CN";
let popupLocaleMessages = null;

function localizedText(key, fallback, variables = {}) {
  const localized = popupLocaleMessages?.[key]?.message
    || extensionAPI.i18n?.getMessage?.(key)
    || fallback;
  return String(localized).replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(variables, name) ? String(variables[name]) : match
  );
}

async function loadPopupLocaleMessages() {
  const getURL = extensionAPI.runtime?.getURL;
  if (typeof getURL !== "function") return;
  const localeDirectory = uiLocale.toLocaleLowerCase("en-US").startsWith("zh")
    ? "zh_CN"
    : "en";
  try {
    const response = await fetch(getURL(`_locales/${localeDirectory}/messages.json`), {
      cache: "no-store"
    });
    if (!response.ok) return;
    const messages = await response.json();
    if (!messages || typeof messages !== "object" || Array.isArray(messages)) return;
    popupLocaleMessages = messages;
    localizePopupDocument();
  } catch {
    // Browser-managed i18n remains the safe fallback if the bundled catalog cannot be read.
  }
}

function localizePopupDocument() {
  document.documentElement.lang = uiLocale.toLocaleLowerCase("en-US").startsWith("zh")
    ? "zh-CN"
    : "en";
  for (const element of document.querySelectorAll("[data-i18n]")) {
    const key = element.getAttribute("data-i18n");
    element.textContent = localizedText(key, element.textContent);
  }
  for (const element of document.querySelectorAll("[data-i18n-placeholder]")) {
    const key = element.getAttribute("data-i18n-placeholder");
    element.setAttribute("placeholder", localizedText(key, element.getAttribute("placeholder") || ""));
  }
  for (const element of document.querySelectorAll("[data-i18n-aria-label]")) {
    const key = element.getAttribute("data-i18n-aria-label");
    element.setAttribute("aria-label", localizedText(key, element.getAttribute("aria-label") || ""));
  }
}

localizePopupDocument();

const tokenInput = document.querySelector("#token");
const connectButton = document.querySelector("#connect");
const connectionPanel = document.querySelector("#connection-panel");
const connectionForm = document.querySelector("#connection-form");
const sessionPanel = document.querySelector("#session-panel");
const sessionTitle = document.querySelector("#session-title");
const tokenExpiry = document.querySelector("#token-expiry");
const disconnectButton = document.querySelector("#disconnect");
const rePairButton = document.querySelector("#re-pair");
const savePanel = document.querySelector("#save-panel");
const organizationPanel = document.querySelector("#organization-panel");
const folderSelect = document.querySelector("#folder");
const folderSearchInput = document.querySelector("#folder-search");
const folderSearchResult = document.querySelector("#folder-search-result");
const folderEmptyState = document.querySelector("#folder-empty-state");
const folderShortcuts = document.querySelector("#folder-shortcuts");
const favoriteFolderButton = document.querySelector("#favorite-folder");
const newFolderInput = document.querySelector("#new-folder");
const rememberDomainInput = document.querySelector("#remember-domain");
const rememberDomainLabel = document.querySelector("#remember-domain-label");
const saveOptionsSummary = document.querySelector("#save-options-summary");
const captureModeInputs = Array.from(document.querySelectorAll("input[name='capture-mode']"));
const captureModeDescription = document.querySelector("#capture-mode-description");
const directSaveButton = document.querySelector("#save-now");
const batchSaveButton = document.querySelector("#batch-save");
const batchHint = document.querySelector("#batch-hint");
const batchReviewPanel = document.querySelector("#batch-review-panel");
const batchSettingsSummary = document.querySelector("#batch-settings-summary");
const batchItemsList = document.querySelector("#batch-items");
const batchRetryFailedButton = document.querySelector("#batch-retry-failed");
const captureLocalIndexInput = document.querySelector("#capture-local-index");
const captureRemoteAIInput = document.querySelector("#capture-remote-ai");
const statusLabel = document.querySelector("#status");
const alertLabel = document.querySelector("#alert");
const pageTitle = document.querySelector("#page-title");
const main = document.querySelector("main");
const queuePanel = document.querySelector("#queue-panel");
const queueCount = document.querySelector("#queue-count");
const queueStateLabel = document.querySelector("#queue-state");
const queueSummaryLabel = document.querySelector("#queue-summary");
const queueRetentionSelect = document.querySelector("#queue-retention");
const queuePrivacyModeSelect = document.querySelector("#queue-privacy-mode");
const queueAllowPrivateSitesInput = document.querySelector("#queue-allow-private-sites");
const queueItemsContainer = document.querySelector("#queue-items");
const retryQueueButton = document.querySelector("#retry-queue");
const exportQueueButton = document.querySelector("#export-queue");
const discardQueueButton = document.querySelector("#discard-queue");
const receiptPanel = document.querySelector("#receipt-panel");
const receiptTitle = document.querySelector("#receipt-title");
const receiptSource = document.querySelector("#receipt-source");
const receiptSavedAt = document.querySelector("#receipt-saved-at");
const receiptFolder = document.querySelector("#receipt-folder");
const receiptSize = document.querySelector("#receipt-size");
const receiptArchive = document.querySelector("#receipt-archive");
const receiptIndex = document.querySelector("#receipt-index");
const receiptLocalIndex = document.querySelector("#receipt-local-index");
const receiptRemoteAI = document.querySelector("#receipt-remote-ai");
const openDocumentButton = document.querySelector("#open-document");
const saveToast = document.querySelector("#save-toast");
const saveToastMessage = document.querySelector("#save-toast-message");
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
let connectionState = "disconnected";
let allKnowledgeFolders = [];
let favoriteFolderIDs = new Set();
let recentFolderIDs = [];
let domainFolderMap = {};
let defaultAllowsLocalSemanticIndex = true;
let defaultAllowsRemoteAIUse = false;
let highlightedTabs = [];
let pendingBatchPermissionPlan = null;
let batchTabsPermissionWasGranted = false;
let batchReviewItemsState = [];
let batchReviewConfiguration = null;
let batchReviewPhase = "hidden";
let activeBatchOperationID = null;
let lastQueueStatus = { queueState: "unknown" };
const CAPTURE_FLOW_STATES = new Set(["capture", "duplicate", "completed"]);
const RECEIPT_RESTORE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1_000;
const SAVE_TOAST_DURATION_MS = 2_000;
let captureFlowState = "capture";
let saveToastTimer = null;

document.addEventListener("DOMContentLoaded", async () => {
  await loadPopupLocaleMessages();
  setConnectionState("disconnected");
  updateQueuePanel({ queueState: "unknown" });
  try {
    [activeTab] = await extensionAPI.tabs.query({ active: true, currentWindow: true });
    await refreshQueueStatus();
    batchTabsPermissionWasGranted = await extensionAPI.permissions.contains({
      permissions: ["tabs"]
    }).catch(() => false);
    await refreshHighlightedTabs();
    await refreshBatchPermissionPlanIfInspectable();
    pageTitle.textContent = activeTab?.title || localizedText("currentPage", "当前页面");
    const stored = await extensionAPI.storage.local.get([
      "bridgeToken",
      "bridgeTokenExpiresAtV1",
      "cachedKnowledgeFolders",
      "selectedKnowledgeFolderID",
      "preferredKnowledgeCaptureModeV1",
      "favoriteKnowledgeFolderIDsV1",
      "recentKnowledgeFolderIDsV1",
      "knowledgeDomainFoldersV1",
      "defaultKnowledgeAllowsLocalSemanticIndexV1",
      "defaultKnowledgeAllowsRemoteAIUseV1",
      "defaultKnowledgeAllowsAIUseV1",
      "lastKnowledgeSaveReceiptV1"
    ]);
    const preferredMode = stored.preferredKnowledgeCaptureModeV1 || "cleaned-article";
    const preferredInput = captureModeInputs.find((input) => input.value === preferredMode);
    if (preferredInput) preferredInput.checked = true;
    updateCaptureModeDescription();
    favoriteFolderIDs = new Set(stored.favoriteKnowledgeFolderIDsV1 || []);
    recentFolderIDs = Array.isArray(stored.recentKnowledgeFolderIDsV1)
      ? stored.recentKnowledgeFolderIDsV1
      : [];
    domainFolderMap = stored.knowledgeDomainFoldersV1 || {};
    const hasLocalSemanticIndexPreference = Object.prototype.hasOwnProperty.call(
      stored,
      "defaultKnowledgeAllowsLocalSemanticIndexV1"
    );
    defaultAllowsLocalSemanticIndex = hasLocalSemanticIndexPreference
      ? stored.defaultKnowledgeAllowsLocalSemanticIndexV1 !== false
      : stored.defaultKnowledgeAllowsAIUseV1 !== false;
    defaultAllowsRemoteAIUse = stored.defaultKnowledgeAllowsRemoteAIUseV1 === true;
    captureLocalIndexInput.checked = defaultAllowsLocalSemanticIndex;
    captureRemoteAIInput.checked = defaultAllowsRemoteAIUse;
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
    updateSaveOptionsSummary();
    updateBatchReviewConfiguration();
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

connectionForm.addEventListener("submit", (event) => {
  event.preventDefault();
  connect();
});
disconnectButton.addEventListener("click", () => disconnectFromBridge(false));
rePairButton.addEventListener("click", () => disconnectFromBridge(true));
directSaveButton.addEventListener("click", saveCurrentPage);
batchSaveButton.addEventListener("click", batchSaveSelectedTabs);
batchRetryFailedButton.addEventListener("click", retryFailedBatchItems);
retryQueueButton.addEventListener("click", retryCaptureQueue);
exportQueueButton.addEventListener("click", exportCaptureQueue);
discardQueueButton.addEventListener("click", discardCaptureQueue);
queueRetentionSelect.addEventListener("change", updateCaptureQueueRetention);
queuePrivacyModeSelect.addEventListener("change", updateCaptureQueuePrivacy);
queueAllowPrivateSitesInput.addEventListener("change", updateCaptureQueuePrivacy);
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
  updateSaveOptionsSummary();
  updateBatchReviewConfiguration();
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
  updateSaveOptionsSummary();
  updateBatchReviewConfiguration();
});
for (const input of captureModeInputs) {
  input.addEventListener("change", () => {
    if (!input.checked) return;
    extensionAPI.storage.local.set({ preferredKnowledgeCaptureModeV1: input.value }).catch(() => {});
    updateCaptureModeDescription();
    updateSaveOptionsSummary();
    updateBatchReviewConfiguration();
  });
}
for (const input of [captureLocalIndexInput, captureRemoteAIInput]) {
  input.addEventListener("change", () => {
    updateSaveOptionsSummary();
    updateBatchReviewConfiguration();
  });
}
document.addEventListener("keydown", handlePopupKeyboardShortcut);
extensionAPI.tabs.onHighlighted?.addListener(() => {
  pendingBatchPermissionPlan = null;
  refreshHighlightedTabs()
    .then(refreshBatchPermissionPlanIfInspectable)
    .catch(() => {});
});
extensionAPI.runtime.onMessage?.addListener((message) => {
  if (message?.type === "capture-tabs-batch-progress") {
    handleBatchProgressMessage(message);
  }
  return false;
});

async function connect() {
  const token = tokenInput.value.trim();
  if (!token) {
    setConnectionState("disconnected");
    showStatus(localizedText("errorPasteToken", "请先粘贴应用连接令牌。"), "error");
    tokenInput.focus();
    return;
  }
  setConnectionState("connecting");
  setBusy(connectButton, true, localizedText("connectingButton", "连接中…"));
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
        ? localizedText("connectedImportedStatus", "已连接，并将 {count} 项待保存内容写入资料库。", {
          count: retry.importedCount
        })
        : localizedText("connectedStatus", "已连接到本机资料库。"),
      retry.importedCount > 0 ? "success" : ""
    );
  } catch (error) {
    if (["token-expired", "invalid-token"].includes(error?.code)) {
      await clearStoredBridgeToken();
      setConnectionState("disconnected");
      showStatus(
        error.code === "token-expired"
          ? localizedText("tokenExpiredError", "连接令牌已过期。请从应用复制新令牌重新配对。")
          : localizedText("invalidTokenError", "连接令牌无效。请从应用重新复制令牌进行配对。"),
        "error"
      );
      tokenInput.focus();
    } else if (token && isNetworkFailure(error)) {
      setConnectionState("offline");
      showStatus(localizedText(
        "applicationOfflineStatus",
        "应用当前未连接；仍可先保存，恢复连接后会自动写入资料库。"
      ), "warning");
    } else {
      setConnectionState("disconnected");
      showStatus(readableError(error), "error");
    }
  } finally {
    setBusy(connectButton, false, localizedText("connectButton", "连接"));
  }
}

async function disconnectFromBridge(isRePair) {
  await clearStoredBridgeToken();
  tokenInput.value = "";
  tokenExpiry.textContent = localizedText("notPaired", "未配对");
  resetCaptureFlow();
  setConnectionState("disconnected");
  showStatus(
    isRePair
      ? localizedText("repairStatus", "旧令牌已从插件中清除，请粘贴应用当前显示的新令牌。")
      : localizedText("disconnectedStatus", "已断开并清除连接令牌；待保存队列和分类偏好未被删除。"),
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
    tokenExpiry.textContent = localizedText("missingTokenExpiry", "应用未提供令牌有效期，请重新配对。");
    return;
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    tokenExpiry.textContent = localizedText("invalidTokenExpiry", "令牌有效期无法读取，请重新配对。");
    return;
  }
  tokenExpiry.textContent = localizedText("tokenExpiresAt", "令牌有效至 {date}", { date: date.toLocaleString(uiLocale, {
    dateStyle: "medium",
    timeStyle: "short"
  }) });
}

function populateFolderOptions(folders, selectedFolderID, query = "") {
  folderSelect.replaceChildren(new Option(localizedText("uncategorized", "未分类"), ""));
  const normalizedQuery = String(query || "").trim().toLocaleLowerCase(uiLocale);
  const matchingFolders = [];
  for (const folder of folders) {
    const matchesQuery = !normalizedQuery
      || folder?.name?.toLocaleLowerCase(uiLocale).includes(normalizedQuery);
    if (folder?.id && folder?.name && matchesQuery) matchingFolders.push(folder);
    if (folder?.id && folder?.name && (matchesQuery || folder.id === selectedFolderID)) {
      folderSelect.add(new Option(folder.name, folder.id));
    }
  }
  const hasSelection = Array.from(folderSelect.options || [])
    .some((option) => option.value === selectedFolderID);
  folderSelect.value = hasSelection ? selectedFolderID : "";
  folderSearchResult.textContent = localizedText(
    "folderSearchResultCount",
    "共 {count} 个分类",
    { count: matchingFolders.length }
  );
  folderEmptyState.hidden = matchingFolders.length > 0;
  folderEmptyState.textContent = localizedText(
    normalizedQuery ? "folderSearchEmpty" : "folderListEmpty",
    normalizedQuery ? "没有匹配的分类。" : "尚无可用分类，可以在下方新建。"
  );
}

function currentPageDomain() {
  try {
    const host = new URL(activeTab?.url || "").hostname
      .toLocaleLowerCase("en-US");
    return host.startsWith("www.") ? host.slice(4) : host;
  } catch {
    return "";
  }
}

function updateDomainMemoryLabel() {
  const domain = currentPageDomain();
  rememberDomainLabel.textContent = domain
    ? localizedText("rememberDomain", "记住 {domain} 的分类选择", { domain })
    : localizedText("rememberDomainDefault", "记住此网站的分类选择");
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
  updateSaveOptionsSummary();
  updateBatchReviewConfiguration();
  if (announce) {
    const folder = allKnowledgeFolders.find((item) => item.id === folderID);
    showStatus(localizedText("folderSelectedStatus", "已选择分类“{folder}”，保存前仍可更改。", {
      folder: folder?.name || localizedText("uncategorized", "未分类")
    }));
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
  appendGroup(localizedText("favoritesShortcut", "收藏"), Array.from(favoriteFolderIDs));
  appendGroup(localizedText("recentShortcut", "最近"), recentFolderIDs.filter((id) => !favoriteFolderIDs.has(id)).slice(0, 4));
  folderShortcuts.hidden = !folderShortcuts.children.length;
}

function updateFavoriteFolderButton() {
  const folderID = folderSelect.value;
  const isFavorite = Boolean(folderID) && favoriteFolderIDs.has(folderID);
  favoriteFolderButton.disabled = !folderID || newFolderInput.value.trim().length > 0;
  favoriteFolderButton.setAttribute("aria-pressed", String(isFavorite));
  favoriteFolderButton.textContent = isFavorite
    ? localizedText("favoritedFolderButton", "★ 已收藏")
    : localizedText("favoriteFolderButton", "☆ 收藏");
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

function updateSaveOptionsSummary() {
  const selectedFolder = Array.from(folderSelect.options || [])
    .find((option) => option.value === folderSelect.value);
  const folderName = newFolderInput.value.trim()
    || selectedFolder?.text
    || selectedFolder?.label
    || localizedText("uncategorized", "未分类");
  saveOptionsSummary.textContent = localizedText(
    "saveOptionsSummary",
    "{mode} · {folder} · 本地索引：{localPermission} · 远程 AI：{remotePermission}",
    {
      mode: captureModeShortLabel(selectedCaptureMode()),
      folder: folderName,
      localPermission: captureLocalIndexInput.checked
        ? localizedText("localIndexAllowedShort", "已建立")
        : localizedText("localIndexDeniedShort", "未建立"),
      remotePermission: captureRemoteAIInput.checked
        ? localizedText("remoteAIAllowedShort", "允许发送")
        : localizedText("remoteAIDeniedShort", "禁止发送")
    }
  );
}

function selectedBatchFolderName() {
  const newFolderName = newFolderInput.value.trim();
  if (newFolderName) return newFolderName;
  return allKnowledgeFolders.find((folder) => folder?.id === folderSelect.value)?.name
    || localizedText("uncategorized", "未分类");
}

function currentBatchConfiguration(captureMode = selectedCaptureMode()) {
  const newFolderName = newFolderInput.value.trim();
  return {
    captureMode,
    folderID: newFolderName ? null : (folderSelect.value || null),
    newFolderName: newFolderName || null,
    folderName: selectedBatchFolderName(),
    allowsLocalSemanticIndex: defaultAllowsLocalSemanticIndex,
    allowsRemoteAIUse: defaultAllowsRemoteAIUse
  };
}

function batchItemDomain(tabURL) {
  try {
    const hostname = new URL(tabURL).hostname.toLocaleLowerCase("en-US");
    return hostname.startsWith("www.") ? hostname.slice(4) : hostname;
  } catch {
    return localizedText("unknownWebsite", "未知网站");
  }
}

function batchItemStatusLabel(status) {
  switch (status) {
  case "saving": return localizedText("batchStatusSaving", "正在保存");
  case "saved": return localizedText("batchStatusSaved", "已保存");
  case "failed": return localizedText("batchStatusFailed", "保存失败");
  case "conflict": return localizedText("batchStatusConflict", "待确认重复项");
  case "queued": return localizedText("batchStatusQueued", "已进入队列");
  default: return localizedText("batchStatusPending", "等待保存");
  }
}

function batchItemsForPlan(plan) {
  return plan.tabs.map((tab) => {
    const permissionOrigin = batchHostPermissionOrigin(tab.url);
    return {
      tabId: tab.id,
      url: tab.url,
      title: String(tab.title || "").trim() || batchItemDomain(tab.url),
      status: "pending",
      error: null,
      receipt: null,
      permissionOrigin,
      requiresTemporaryPermission: plan.requestOrigins.includes(permissionOrigin)
    };
  });
}

function showBatchConfirmation(plan) {
  batchReviewItemsState = batchItemsForPlan(plan);
  batchReviewConfiguration = currentBatchConfiguration();
  batchReviewPhase = "confirmation";
  renderBatchReview();
}

function updateBatchReviewConfiguration() {
  if (batchReviewPhase !== "confirmation") return;
  batchReviewConfiguration = currentBatchConfiguration();
  renderBatchReview();
}

function renderBatchReview() {
  const visible = batchReviewPhase !== "hidden" && batchReviewItemsState.length > 0;
  batchReviewPanel.hidden = !visible
    || connectionState === "disconnected"
    || captureFlowState !== "capture";
  if (!visible) return;
  const configuration = batchReviewConfiguration || currentBatchConfiguration();
  batchSettingsSummary.textContent = [
    localizedText("batchFolderSummary", "分类：{folder}", { folder: configuration.folderName }),
    localizedText("batchModeSummary", "模式：{mode}", {
      mode: captureModeShortLabel(configuration.captureMode)
    }),
    localizedText("batchPermissionSummary", "本地索引：{localPermission} · 远程 AI：{remotePermission}", {
      localPermission: configuration.allowsLocalSemanticIndex
        ? localizedText("localIndexAllowedShort", "已建立")
        : localizedText("localIndexDeniedShort", "未建立"),
      remotePermission: configuration.allowsRemoteAIUse
        ? localizedText("remoteAIAllowedShort", "允许发送")
        : localizedText("remoteAIDeniedShort", "禁止发送")
    })
  ].join(localizedText("metadataSeparator", " · "));
  batchItemsList.replaceChildren(...batchReviewItemsState.map((item) => {
    const row = document.createElement("li");
    row.className = "batch-item";
    row.setAttribute("data-status", item.status);
    row.setAttribute(
      "aria-label",
      `${item.title}，${batchItemDomain(item.url)}，${batchItemStatusLabel(item.status)}${item.error ? `，${item.error}` : ""}`
    );

    const title = document.createElement("span");
    title.className = "batch-item-title";
    title.textContent = item.title;
    title.setAttribute("title", item.title);
    const domain = document.createElement("span");
    domain.className = "batch-item-domain";
    domain.textContent = batchItemDomain(item.url);
    const status = document.createElement("span");
    status.className = "batch-item-status";
    status.textContent = batchItemStatusLabel(item.status);
    row.append(title, domain, status);
    if (item.error) {
      const error = document.createElement("span");
      error.className = "batch-item-error";
      error.textContent = item.error;
      row.append(error);
    }
    return row;
  }));
  const failedCount = batchReviewItemsState.filter((item) => item.status === "failed").length;
  batchRetryFailedButton.hidden = batchReviewPhase !== "result" || failedCount === 0;
  batchRetryFailedButton.disabled = Boolean(activeBatchOperationID);
  batchRetryFailedButton.textContent = failedCount > 0
    ? localizedText("retryFailedCountButton", "仅重试失败项（{count}）", { count: failedCount })
    : localizedText("retryFailedButton", "仅重试失败项");
}

function handleBatchProgressMessage(message) {
  if (!activeBatchOperationID || message.batchOperationID !== activeBatchOperationID) return;
  const item = batchReviewItemsState.find((candidate) => candidate.tabId === message.tabId);
  if (!item) return;
  item.status = ["saving", "saved", "failed", "conflict", "queued"].includes(message.status)
    ? message.status
    : item.status;
  item.error = message.error ? String(message.error) : null;
  if (message.receipt) item.receipt = message.receipt;
  renderBatchReview();
}

function mergeBatchResultItems(result, plannedTabIDs) {
  const returnedItems = Array.isArray(result.items) ? result.items : [];
  if (returnedItems.length) {
    for (const returnedItem of returnedItems) {
      const existing = batchReviewItemsState.find((item) => item.tabId === returnedItem.tabId);
      if (!existing) continue;
      existing.status = returnedItem.status || "failed";
      existing.error = returnedItem.error || null;
      existing.receipt = returnedItem.receipt || null;
      if (returnedItem.title) existing.title = returnedItem.title;
    }
    return;
  }
  const errorsByTabID = new Map((result.errors || []).map((error) => [error.tabId, error.message]));
  for (const item of batchReviewItemsState) {
    if (!plannedTabIDs.has(item.tabId)) continue;
    item.status = errorsByTabID.has(item.tabId) ? "failed" : "saved";
    item.error = errorsByTabID.get(item.tabId) || null;
  }
}

function markBatchItemsFailed(plannedTabIDs, error) {
  const message = readableError(error);
  for (const item of batchReviewItemsState) {
    if (!plannedTabIDs.has(item.tabId)) continue;
    item.status = "failed";
    item.error = message;
  }
}

function newBatchOperationID() {
  const nativeID = globalThis.crypto?.randomUUID?.();
  if (nativeID) return nativeID.toLocaleLowerCase("en-US");
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (character) => {
    const value = Math.floor(Math.random() * 16);
    return (character === "x" ? value : ((value & 0x3) | 0x8)).toString(16);
  });
}

function batchHostPermissionOrigin(tabURL) {
  try {
    const url = new URL(tabURL);
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname) return null;
    return `${url.protocol}//${url.hostname}/*`;
  } catch {
    return null;
  }
}

function batchPageIdentityURL(tabURL) {
  try {
    const url = new URL(tabURL);
    if (!["http:", "https:"].includes(url.protocol)
        || !url.hostname
        || url.username
        || url.password) return null;
    return url.href;
  } catch {
    return null;
  }
}

function batchTabSignature(tabs) {
  return tabs
    .map((tab) => `${tab.id}:${encodeURIComponent(batchPageIdentityURL(tab.url) || "")}`)
    .join(",");
}

async function createBatchPermissionPlan(tabs, minimumCount = 2) {
  const selectedTabs = tabs.filter((tab) => Number.isInteger(tab.id)).slice(0, 10);
  if (selectedTabs.length < minimumCount) {
    throw new Error(minimumCount > 1
      ? localizedText("selectAtLeastTwoTabsError", "请先选择至少两个可保存的网页标签页。")
      : localizedText("noRetryablePagesError", "没有可重试的网页。"));
  }
  const invalidTabs = selectedTabs.filter((tab) => !batchHostPermissionOrigin(tab.url));
  if (invalidTabs.length) {
    throw new Error(localizedText(
      "invalidBatchTabsError",
      "所选标签页中有 {count} 个不是可采集的 HTTP/HTTPS 网页。",
      { count: invalidTabs.length }
    ));
  }
  const identifiedTabs = selectedTabs.map((tab) => ({
    ...tab,
    url: batchPageIdentityURL(tab.url)
  }));
  const origins = Array.from(new Set(identifiedTabs.map((tab) => batchHostPermissionOrigin(tab.url))));
  const requestOrigins = [];
  for (const origin of origins) {
    const alreadyGranted = await extensionAPI.permissions.contains({ origins: [origin] });
    if (!alreadyGranted) requestOrigins.push(origin);
  }
  return {
    tabs: identifiedTabs,
    tabIdentities: identifiedTabs.map((tab) => ({
      tabId: tab.id,
      url: tab.url,
      title: String(tab.title || "").trim().slice(0, 300)
    })),
    signature: batchTabSignature(identifiedTabs),
    origins,
    requestOrigins
  };
}

function updateBatchActionPresentation() {
  const count = Math.min(highlightedTabs.length, 10);
  const planMatchesSelection = pendingBatchPermissionPlan
    && pendingBatchPermissionPlan.signature === batchTabSignature(highlightedTabs.slice(0, 10));
  if (planMatchesSelection) {
    batchSaveButton.textContent = pendingBatchPermissionPlan.requestOrigins.length
      ? localizedText("confirmAuthorizeBatchButton", "确认、授权并保存 {count} 项", { count })
      : localizedText("confirmBatchButton", "确认并保存 {count} 项", { count });
    batchHint.textContent = batchReviewPhase === "confirmation"
      ? localizedText("batchConfirmHint", "请核对下方标题、网站和保存设置；再次点击即开始。")
      : localizedText("batchPlanReadyHint", "已识别所选网站，点击后将先显示确认清单。");
    return;
  }
  batchSaveButton.textContent = count > 1
    ? localizedText("batchSaveCountButton", "批量保存 {count} 个已选择标签页", { count })
    : localizedText("batchSaveButton", "批量保存已选择标签页");
  batchHint.textContent = highlightedTabs.length > 10
    ? localizedText("batchLimitedHint", "已选择 {count} 个标签页；为控制空间，本次只处理前 10 个。", {
      count: highlightedTabs.length
    })
    : highlightedTabs.length > 1
      ? localizedText("batchTemporaryPermissionHint", "首次使用会临时读取所选标签页地址；之后仅授权这些网站并在完成后撤销。")
      : localizedText("batchSelectionHint", "在浏览器标签栏按住 Command/Ctrl 选择多个标签页。");
}

async function refreshHighlightedTabs() {
  const previousSignature = batchTabSignature(highlightedTabs.slice(0, 10));
  highlightedTabs = (await extensionAPI.tabs.query({ highlighted: true, currentWindow: true }))
    .filter((tab) => Number.isInteger(tab.id));
  const currentSignature = batchTabSignature(highlightedTabs.slice(0, 10));
  if (previousSignature && previousSignature !== currentSignature) {
    pendingBatchPermissionPlan = null;
    if (batchReviewPhase === "confirmation") {
      batchReviewPhase = "hidden";
      batchReviewItemsState = [];
      renderBatchReview();
    }
  }
  const count = highlightedTabs.length;
  batchSaveButton.disabled = count < 2;
  updateBatchActionPresentation();
}

async function refreshBatchPermissionPlanIfInspectable() {
  if (highlightedTabs.length < 2) {
    pendingBatchPermissionPlan = null;
    updateBatchActionPresentation();
    return;
  }
  const selectedTabs = highlightedTabs.slice(0, 10);
  if (!selectedTabs.every((tab) => batchHostPermissionOrigin(tab.url))) return;
  pendingBatchPermissionPlan = await createBatchPermissionPlan(selectedTabs);
  showBatchConfirmation(pendingBatchPermissionPlan);
  updateBatchActionPresentation();
}

async function releaseNamedOptionalPermission(permission) {
  try {
    await extensionAPI.permissions.remove({ permissions: [permission] });
  } catch {
    // Verify below. The permission may already have been removed by the browser.
  }
  try {
    return !(await extensionAPI.permissions.contains({ permissions: [permission] }));
  } catch {
    return false;
  }
}

async function remainingGrantedOrigins(origins) {
  const remaining = [];
  for (const origin of origins) {
    try {
      if (await extensionAPI.permissions.contains({ origins: [origin] })) remaining.push(origin);
    } catch {
      remaining.push(origin);
    }
  }
  return remaining;
}

async function releaseTemporaryHostPermissions(origins) {
  if (!origins.length) return [];
  try {
    await extensionAPI.permissions.remove({ origins });
  } catch {
    // A background cleanup may already have removed them; verify exact origins below.
  }
  return remainingGrantedOrigins(origins);
}

async function discoverBatchPermissionPlan(permissionRequest, tabsPermissionWasGranted) {
  setBusy(batchSaveButton, true, localizedText("identifyingSelectedSites", "正在识别所选网站…"));
  let temporarilyGrantedTabs = false;
  let discoveredPlan = null;
  let discoveryError = null;
  try {
    const granted = await permissionRequest;
    if (!granted) {
      showStatus(localizedText("tabsPermissionDeniedError", "未获得读取所选标签页地址的临时权限，批量保存已取消。"), "error");
      return;
    }
    temporarilyGrantedTabs = !tabsPermissionWasGranted;
    const selectedTabs = (await extensionAPI.tabs.query({ highlighted: true, currentWindow: true }))
      .filter((tab) => Number.isInteger(tab.id));
    discoveredPlan = await createBatchPermissionPlan(selectedTabs);
  } catch (error) {
    discoveryError = error;
  } finally {
    let tabsReleased = true;
    if (temporarilyGrantedTabs) {
      tabsReleased = await releaseNamedOptionalPermission("tabs");
    }
    batchSaveButton.setAttribute("aria-busy", "false");
    batchSaveButton.disabled = highlightedTabs.length < 2;
    if (!tabsReleased) {
      pendingBatchPermissionPlan = null;
      showStatus(localizedText("tabsPermissionCleanupError", "无法撤销读取标签页列表的临时权限，请在扩展权限设置中移除“标签页”。"), "error");
    } else if (discoveryError) {
      pendingBatchPermissionPlan = null;
      showStatus(readableError(discoveryError), "error");
    } else if (discoveredPlan) {
      highlightedTabs = discoveredPlan.tabs;
      pendingBatchPermissionPlan = discoveredPlan;
      showBatchConfirmation(discoveredPlan);
      showStatus(localizedText("batchPlanCreatedStatus", "已生成批量保存清单；请核对后再次点击确认保存。"), "success");
    } else {
      pendingBatchPermissionPlan = null;
    }
    updateBatchActionPresentation();
  }
}

function batchSaveSelectedTabs() {
  if (highlightedTabs.length < 2) {
    showStatus(localizedText("selectTwoPagesError", "请先在标签栏选择至少两个网页。"), "error");
    return;
  }
  const captureMode = selectedCaptureMode();
  if (captureMode === "selection") {
    showStatus(localizedText("batchSelectionModeError", "批量保存不能使用“选中文字”模式。"), "error");
    return;
  }
  const selectedTabs = highlightedTabs.slice(0, 10);
  const signature = batchTabSignature(selectedTabs);
  const plan = pendingBatchPermissionPlan?.signature === signature
    ? pendingBatchPermissionPlan
    : null;
  if (!plan) {
    const tabsPermissionRequest = extensionAPI.permissions.request({ permissions: ["tabs"] });
    return discoverBatchPermissionPlan(tabsPermissionRequest, batchTabsPermissionWasGranted);
  }
  if (batchReviewPhase !== "confirmation") {
    showBatchConfirmation(plan);
    updateBatchActionPresentation();
    showStatus(localizedText("batchPlanRefreshedStatus", "已生成新的批量保存清单；请核对后再次点击。"), "success");
    return;
  }
  const configuration = currentBatchConfiguration(captureMode);
  const originPermissionRequest = plan.requestOrigins.length
    ? extensionAPI.permissions.request({ origins: plan.requestOrigins })
    : Promise.resolve(true);
  return runBatchSaveWithPermissionPlan(plan, originPermissionRequest, configuration, false);
}

function retryFailedBatchItems() {
  if (activeBatchOperationID) return;
  const failedItems = batchReviewItemsState.filter((item) => item.status === "failed");
  if (!failedItems.length) {
    showStatus(localizedText("noFailedItemsStatus", "没有需要重试的失败项。"), "success");
    return;
  }
  const plan = {
    tabs: failedItems.map((item) => ({ id: item.tabId, url: item.url, title: item.title })),
    tabIdentities: failedItems.map((item) => ({
      tabId: item.tabId,
      url: item.url,
      title: item.title
    })),
    origins: Array.from(new Set(failedItems.map((item) => item.permissionOrigin).filter(Boolean))),
    requestOrigins: Array.from(new Set(failedItems
      .filter((item) => item.requiresTemporaryPermission)
      .map((item) => item.permissionOrigin)
      .filter(Boolean)))
  };
  const originPermissionRequest = plan.requestOrigins.length
    ? extensionAPI.permissions.request({ origins: plan.requestOrigins })
    : Promise.resolve(true);
  return runBatchSaveWithPermissionPlan(
    plan,
    originPermissionRequest,
    batchReviewConfiguration || currentBatchConfiguration(),
    true
  );
}

async function runBatchSaveWithPermissionPlan(plan, permissionRequest, configuration, isRetry) {
  let temporaryOrigins = [];
  const actionButton = isRetry ? batchRetryFailedButton : batchSaveButton;
  setBusy(actionButton, true, isRetry
    ? localizedText("retryingFailedItems", "正在重试失败项…")
    : localizedText("batchSaving", "正在批量保存…"));
  try {
    const granted = await permissionRequest;
    if (!granted) {
      showStatus(localizedText("originPermissionDeniedError", "未获得所选网站的访问权限，批量保存已取消。"), "error");
      setBusy(actionButton, false, isRetry
        ? localizedText("retryFailedButton", "仅重试失败项")
        : localizedText("batchSaveButton", "批量保存已选择标签页"));
      updateBatchActionPresentation();
      renderBatchReview();
      return;
    }
    temporaryOrigins = plan.requestOrigins;
  } catch (error) {
    showStatus(readableError(error), "error");
    setBusy(actionButton, false, isRetry
      ? localizedText("retryFailedButton", "仅重试失败项")
      : localizedText("batchSaveButton", "批量保存已选择标签页"));
    updateBatchActionPresentation();
    renderBatchReview();
    return;
  }
  const plannedTabIDs = new Set(plan.tabIdentities.map((item) => item.tabId));
  if (!isRetry) batchReviewItemsState = batchItemsForPlan(plan);
  for (const item of batchReviewItemsState) {
    if (!plannedTabIDs.has(item.tabId)) continue;
    item.status = "pending";
    item.error = null;
    item.receipt = null;
  }
  batchReviewConfiguration = configuration;
  batchReviewPhase = "saving";
  activeBatchOperationID = newBatchOperationID();
  renderBatchReview();
  try {
    const result = await sendRuntimeMessage({
      type: "capture-tabs-batch",
      batchOperationID: activeBatchOperationID,
      tabIdentities: plan.tabIdentities,
      temporaryPermissionOrigins: temporaryOrigins,
      token: tokenInput.value.trim(),
      captureMode: configuration.captureMode,
      folderID: configuration.folderID,
      newFolderName: configuration.newFolderName,
      allowsLocalSemanticIndex: configuration.allowsLocalSemanticIndex,
      allowsRemoteAIUse: configuration.allowsRemoteAIUse
    });
    mergeBatchResultItems(result, plannedTabIDs);
    batchReviewPhase = "result";
    renderBatchReview();
    const latestReceipt = result.receipts?.[result.receipts.length - 1];
    if (latestReceipt) {
      await rememberOrganizationChoice(latestReceipt);
      await rememberReceipt(latestReceipt);
    }
    await refreshQueueStatus();
    const counts = Object.fromEntries(["saved", "conflict", "queued", "failed"]
      .map((status) => [status, batchReviewItemsState.filter((item) => item.status === status).length]));
    const details = [
      localizedText("batchSavedCount", "{count} 项已保存", { count: counts.saved }),
      counts.conflict ? localizedText("batchConflictCount", "{count} 项待确认重复处理", { count: counts.conflict }) : "",
      counts.queued ? localizedText("batchQueuedCount", "{count} 项进入离线队列", { count: counts.queued }) : "",
      counts.failed ? localizedText("batchFailedCount", "{count} 项失败", { count: counts.failed }) : ""
    ].filter(Boolean).join("，");
    showStatus(
      localizedText("batchCompleteStatus", "批量处理完成：{details}。", { details }),
      counts.failed ? "error" : counts.conflict || counts.queued ? "warning" : "success"
    );
  } catch (error) {
    markBatchItemsFailed(plannedTabIDs, error);
    batchReviewPhase = "result";
    renderBatchReview();
    showStatus(readableError(error), "error");
  } finally {
    activeBatchOperationID = null;
    const remainingOrigins = await releaseTemporaryHostPermissions(temporaryOrigins);
    setBusy(actionButton, false, isRetry
      ? localizedText("retryFailedButton", "仅重试失败项")
      : localizedText("batchSaveButton", "批量保存已选择标签页"));
    renderBatchReview();
    if (!isRetry) await refreshHighlightedTabs();
    if (remainingOrigins.length) {
      showStatus(
        localizedText("originPermissionCleanupError", "批量任务已结束，但 {count} 个临时网站权限未能撤销；请在扩展权限设置中手动移除。", {
          count: remainingOrigins.length
        }),
        "error"
      );
    }
  }
}

function handlePopupKeyboardShortcut(event) {
  const accelerator = event.metaKey || event.ctrlKey;
  if (accelerator && event.key === "Enter" && !savePanel.hidden && !directSaveButton.disabled) {
    event.preventDefault();
    directSaveButton.click();
    return;
  }
  if (accelerator && event.shiftKey && event.key.toLocaleLowerCase("en-US") === "b"
      && !batchSaveButton.disabled) {
    event.preventDefault();
    batchSaveButton.click();
    return;
  }
}

function transitionCaptureFlow(nextState) {
  if (!CAPTURE_FLOW_STATES.has(nextState)) {
    throw new Error(localizedText("invalidCaptureStateError", "采集流程状态无效。"));
  }
  captureFlowState = nextState;
  renderCaptureFlowState();
}

function renderCaptureFlowState() {
  const available = connectionState === "connected" || connectionState === "offline";
  savePanel.hidden = !available || captureFlowState !== "capture";
  duplicatePanel.hidden = !available || captureFlowState !== "duplicate";
  receiptPanel.hidden = !available || captureFlowState !== "completed";
  batchReviewPanel.hidden = !available
    || captureFlowState !== "capture"
    || batchReviewPhase === "hidden";
  organizationPanel.hidden = !available || captureFlowState !== "capture";
}

function resetCaptureFlow() {
  transitionCaptureFlow("capture");
}

async function saveCurrentPage() {
  if (!activeTab?.id || !/^https?:/i.test(activeTab.url || "")) {
    showStatus(localizedText("httpPagesOnlyError", "只能保存 HTTP 或 HTTPS 网页。"), "error");
    return;
  }
  const captureMode = selectedCaptureMode();
  const receiptSourceURL = activeTab.url;
  setBusy(directSaveButton, true, localizedText("savingButton", "正在保存…"));
  showStatus(captureMode === "full-page"
    ? localizedText("savingFullPageStatus", "正在生成离线网页归档并保存…")
    : localizedText("capturingAndSavingStatus", "正在读取页面、保存并建立索引…"));
  try {
    const token = tokenInput.value.trim();
    defaultAllowsLocalSemanticIndex = captureLocalIndexInput.checked;
    defaultAllowsRemoteAIUse = captureRemoteAIInput.checked;
    await extensionAPI.storage.local.set({
      defaultKnowledgeAllowsLocalSemanticIndexV1: defaultAllowsLocalSemanticIndex,
      defaultKnowledgeAllowsRemoteAIUseV1: defaultAllowsRemoteAIUse
    }).catch(() => {});
    const result = await sendRuntimeMessage({
      type: "capture-and-save",
      tabId: activeTab.id,
      token,
      captureMode,
      allowsLocalSemanticIndex: captureLocalIndexInput.checked,
      allowsRemoteAIUse: captureRemoteAIInput.checked,
      folderID: newFolderInput.value.trim() ? null : (folderSelect.value || null),
      newFolderName: newFolderInput.value.trim() || null
    });
    await rememberOrganizationChoice(result);
    if (result.requiresDuplicateResolution) {
      await refreshQueueStatus(result.conflictQueueID || null);
      showStatus(localizedText("duplicateResolutionRequiredStatus", "该网址已在资料库中，请选择如何处理。"), "warning");
      return;
    }
    if (result.queued) {
      setConnectionState("offline");
      await refreshQueueStatus();
      resetCaptureFlow();
      showStatus(
        localizedText("queuedOfflineStatus", "应用尚未连接，网页已安全加入待保存队列（共 {count} 项）。", {
          count: result.queuedCount
        }),
        "warning"
      );
      return;
    }
    const action = result.insertedCount > 0
      ? localizedText("saveActionInserted", "新增")
      : result.updatedCount > 0
        ? localizedText("saveActionUpdated", "更新")
        : localizedText("saveActionExisting", "已存在");
    const didRememberReceipt = await rememberReceipt(result, receiptSourceURL);
    const indexFeedback = didRememberReceipt ? showSaveToast(result) : "";
    const report = result.archiveReport;
    if (report?.format === "html" && report.missingResourceCount > 0) {
      const truncated = report.wasTruncated
        ? localizedText("archiveTruncatedSuffix", "，并已按 24 MB 上限精简")
        : "";
      showStatus(
        [localizedText(
          "savedWithMissingResourcesStatus",
          "已保存到长期参考（{action}），已内联 {embedded} 项；{missing} 项外部资源未能离线保存{truncated}。",
          {
            action,
            embedded: report.embeddedResourceCount,
            missing: report.missingResourceCount,
            truncated
          }
        ), indexFeedback].filter(Boolean).join(" "),
        "warning"
      );
    } else if (report?.format === "html") {
      showStatus(
        [localizedText(
          "savedOfflineArchiveStatus",
          "已保存到长期参考（{action}），自包含归档已内联 {count} 项资源，可离线打开。",
          { action, count: report.embeddedResourceCount }
        ), indexFeedback].filter(Boolean).join(" "),
        "success"
      );
    } else {
      showStatus([
        localizedText("savedStatus", "已保存到长期参考（{action}）。", { action }),
        indexFeedback
      ].filter(Boolean).join(" "), "success");
    }
  } catch (error) {
    if (error?.code === "page-identity-changed") {
      resetCaptureFlow();
      [activeTab] = await extensionAPI.tabs.query({ active: true, currentWindow: true }).catch(
        () => [activeTab]
      );
      pageTitle.textContent = activeTab?.title || localizedText("currentPage", "当前页面");
      updateDomainMemoryLabel();
      directSaveButton.focus();
    }
    showStatus(readableError(error), "error");
  } finally {
    setBusy(directSaveButton, false, localizedText("directSaveButton", "直接保存当前页面"));
    directSaveButton.disabled = !(connectionState === "connected" || connectionState === "offline");
  }
}

function captureModeShortLabel(value) {
  switch (value) {
  case "full-page": return localizedText("fullPageTitle", "完整网页");
  case "selection": return localizedText("selectionTitle", "选中文字");
  case "link-only": return localizedText("linkOnlyTitle", "仅链接");
  default: return localizedText("cleanedArticleTitle", "净化正文");
  }
}

function updateCaptureModeDescription() {
  if (!captureModeDescription) return;
  switch (selectedCaptureMode()) {
  case "full-page":
    captureModeDescription.textContent = localizedText(
      "fullPageDescription",
      "正文与离线页面归档一起保存"
    );
    break;
  case "selection":
    captureModeDescription.textContent = localizedText(
      "selectionDescription",
      "只保存当前页面中的选择内容"
    );
    break;
  case "link-only":
    captureModeDescription.textContent = localizedText(
      "linkOnlyDescription",
      "保存标题、来源和可检索链接"
    );
    break;
  default:
    captureModeDescription.textContent = localizedText(
      "cleanedArticleDescription",
      "去掉导航、广告和交互噪声"
    );
  }
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
    showStatus(localizedText("tokenRequiredError", "请先填写应用连接令牌。"), "error");
    tokenInput.focus();
    return;
  }
  setBusy(retryQueueButton, true, localizedText("retryingButton", "重试中…"));
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
      showStatus(localizedText("retryCompleteStatus", "重试完成，已导入 {count} 项内容。", {
        count: result.importedCount
      }), "success");
    } else {
      showStatus(
        localizedText("retryPartialStatus", "已导入 {imported} 项，仍有 {queued} 项待处理。", {
          imported: result.importedCount,
          queued: result.queuedCount
        }),
        result.blockedCount > 0 ? "error" : "warning"
      );
    }
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(retryQueueButton, false, localizedText("retryQueueButton", "立即重试"));
  }
}

async function resolveDuplicateCapture(resolution) {
  const token = tokenInput.value.trim();
  if (!activeDuplicateConflict?.queueID || !token) {
    showStatus(localizedText("reconnectRequiredError", "请先重新连接应用。"), "error");
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
    activeDuplicateConflict = null;
    const didRememberReceipt = await rememberReceipt(result.receipt);
    const indexFeedback = didRememberReceipt && resolution !== "move-only"
      ? showSaveToast(result.receipt)
      : "";
    await refreshQueueStatus();
    const message = resolution === "save-new-version"
      ? localizedText("savedNewVersionStatus", "已将本次采集保存为新版本。")
      : resolution === "move-only"
        ? localizedText("movedFolderStatus", "已移动原资料的分类，未创建新版本。")
        : localizedText("keptCopyStatus", "已保留一份独立副本。");
    showStatus([message, indexFeedback].filter(Boolean).join(" "), "success");
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
    transitionCaptureFlow("capture");
    await refreshQueueStatus();
    showStatus(localizedText("duplicateCancelledStatus", "已取消，本次网页没有写入资料库。"));
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
    showStatus(localizedText("reconnectRequiredError", "请先重新连接应用。"), "error");
    return;
  }
  const [currentTab] = await extensionAPI.tabs.query({ active: true, currentWindow: true })
    .catch(() => [activeTab]);
  if (currentTab) activeTab = currentTab;
  if (!receiptMatchesActivePage(lastReceipt)) {
    showReceipt(null);
    showStatus(localizedText("receiptMismatchError", "当前网页与保存回执不匹配，已隐藏旧回执。"), "error");
    return;
  }
  setBusy(openDocumentButton, true, localizedText("openingButton", "正在打开…"));
  try {
    await sendRuntimeMessage({
      type: "open-knowledge-document",
      documentID: lastReceipt.documentID,
      token
    });
    showStatus(localizedText("openedDocumentStatus", "已在资料库中打开。"), "success");
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(openDocumentButton, false, localizedText("openDocumentButton", "在 RepoPress 中查看"));
  }
}

function normalizedPageBindingURL(value) {
  try {
    const url = new URL(String(value || ""));
    if (!["http:", "https:"].includes(url.protocol)
        || !url.hostname
        || url.username
        || url.password) return null;
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}

function receiptSavedAtTimestamp(value) {
  const timestamp = typeof value === "number" ? value : Date.parse(String(value || ""));
  return Number.isFinite(timestamp) ? timestamp : null;
}

function receiptMatchesActivePage(receipt, now = Date.now()) {
  const receiptURL = normalizedPageBindingURL(receipt?.sourceURL);
  const activeURL = normalizedPageBindingURL(activeTab?.url);
  const savedAt = receiptSavedAtTimestamp(receipt?.savedAt);
  return Boolean(receipt?.documentID)
    && Boolean(receiptURL)
    && receiptURL === activeURL
    && savedAt !== null
    && savedAt <= now + 5 * 60 * 1_000
    && now - savedAt <= RECEIPT_RESTORE_MAX_AGE_MS;
}

function receiptWithPageBinding(receipt, fallbackSourceURL = null) {
  if (!receipt?.documentID) return null;
  const sourceURL = normalizedPageBindingURL(receipt.sourceURL || fallbackSourceURL);
  if (!sourceURL) return null;
  const savedAt = receiptSavedAtTimestamp(receipt.savedAt);
  return {
    ...receipt,
    sourceURL,
    savedAt: new Date(savedAt ?? Date.now()).toISOString()
  };
}

async function rememberReceipt(receipt, fallbackSourceURL = null) {
  const boundReceipt = receiptWithPageBinding(receipt, fallbackSourceURL);
  if (!boundReceipt) {
    showReceipt(null);
    return false;
  }
  showReceipt(boundReceipt);
  await extensionAPI.storage.local.set({ lastKnowledgeSaveReceiptV1: boundReceipt }).catch(() => {});
  return true;
}

function saveToastText(receipt) {
  const action = String(receipt?.action || "").toLocaleLowerCase("en-US");
  const wasUpdated = Number(receipt?.updatedCount || 0) > 0 || action === "updated";
  const wasExisting = action === "existing"
    || (!action
      && Number(receipt?.insertedCount || 0) === 0
      && Number(receipt?.updatedCount || 0) === 0);
  if (receipt?.indexStatus !== "ready") {
    if (wasUpdated) return localizedText("updatedIndexingToast", "已更新，正在建立索引");
    if (wasExisting) return localizedText("existingIndexingToast", "资料已在库中，等待建立索引");
    return localizedText("indexingToast", "已保存，正在建立索引");
  }
  if (wasUpdated) return localizedText("updatedIndexedToast", "已更新并完成索引");
  if (wasExisting) return localizedText("existingIndexedToast", "资料已在库中，索引已就绪");
  return localizedText("indexedToast", "已索引入库");
}

function showSaveToast(receipt) {
  const message = saveToastText(receipt);
  if (!saveToast || !saveToastMessage) return message;
  saveToastMessage.textContent = message;
  if (saveToastTimer !== null) globalThis.clearTimeout?.(saveToastTimer);
  saveToast.hidden = true;
  void saveToast.offsetWidth;
  saveToast.hidden = false;
  saveToastTimer = globalThis.setTimeout?.(() => {
    saveToast.hidden = true;
    saveToastTimer = null;
  }, SAVE_TOAST_DURATION_MS) ?? null;
  return message;
}

function showReceipt(receipt) {
  if (activeDuplicateConflict || !receiptMatchesActivePage(receipt)) {
    lastReceipt = null;
    if (captureFlowState === "completed") transitionCaptureFlow("capture");
    else receiptPanel.hidden = true;
    return false;
  }
  lastReceipt = receipt;
  transitionCaptureFlow("completed");
  receiptTitle.textContent = receipt.title || localizedText("untitledDocument", "未命名资料");
  const sourceURL = new URL(receipt.sourceURL);
  receiptSource.textContent = sourceURL.hostname;
  receiptSource.setAttribute("title", sourceURL.href);
  receiptSavedAt.textContent = new Date(receipt.savedAt).toLocaleString(uiLocale, {
    dateStyle: "short",
    timeStyle: "short"
  });
  receiptFolder.textContent = receipt.folder?.name || localizedText("uncategorized", "未分类");
  receiptSize.textContent = formatBytes(Number(receipt.fileSizeBytes || 0));
  receiptArchive.textContent = archiveTypeLabel(receipt.archiveType);
  receiptIndex.textContent = receipt.indexStatus === "ready"
    ? localizedText("indexReady", "全文与语义索引已就绪")
    : localizedText("indexPending", "等待建立索引");
  receiptLocalIndex.textContent = receipt.allowsLocalSemanticIndex === false
    ? localizedText("localIndexDeniedReceipt", "未建立")
    : localizedText("localIndexAllowedReceipt", "已建立");
  receiptRemoteAI.textContent = receipt.allowsRemoteAIUse === true
    ? localizedText("remoteAIAllowedReceipt", "允许发送")
    : localizedText("remoteAIDeniedReceipt", "已禁止发送");
  return true;
}

function archiveTypeLabel(value) {
  switch (String(value || "none").toLowerCase()) {
  case "mhtml": return localizedText("archiveMHTML", "MHTML 完整网页");
  case "html": return localizedText("archiveHTML", "离线 HTML");
  default: return localizedText("archiveTextOnly", "仅正文");
  }
}

async function discardCaptureQueue() {
  if (!globalThis.confirm(
    localizedText(
      "clearQueueConfirmation",
      "确定清空所有尚未写入资料库的网页和隔离项目？此操作无法撤销；建议先导出备份。"
    )
  )) {
    return;
  }
  setBusy(discardQueueButton, true, localizedText("clearingButton", "清理中…"));
  try {
    await sendRuntimeMessage({ type: "discard-capture-queue" });
    await refreshQueueStatus();
    showStatus(localizedText("queueClearedStatus", "待保存队列已清空。"));
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(discardQueueButton, false, localizedText("clearQueueButton", "清空队列"));
  }
}

async function deleteCaptureQueueItem(queueID, quarantined, title) {
  const description = quarantined
    ? localizedText("quarantinedItem", "隔离项目")
    : localizedText("queuedPage", "待保存网页");
  if (!globalThis.confirm(localizedText(
    "deleteQueueItemConfirmation",
    "确定删除{description}“{title}”？此操作无法撤销。",
    { description, title: title || localizedText("untitledItem", "未命名项目") }
  ))) {
    return;
  }
  try {
    const result = await sendRuntimeMessage({
      type: "delete-capture-queue-item",
      queueID,
      quarantined
    });
    updateQueuePanel(result);
    showStatus(localizedText("queueItemDeletedStatus", "已删除{description}。", { description }), "success");
  } catch (error) {
    showStatus(readableError(error), "error");
  }
}

async function exportCaptureQueue() {
  setBusy(exportQueueButton, true, localizedText("exportingButton", "正在导出…"));
  try {
    const result = await sendRuntimeMessage({ type: "export-capture-queue" });
    const blob = new Blob([JSON.stringify(result.export, null, 2)], {
      type: "application/json;charset=utf-8"
    });
    const objectURL = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = objectURL;
    anchor.download = result.fileName || "knowledge-capture-queue.json";
    anchor.click();
    URL.revokeObjectURL(objectURL);
    showStatus(result.export?.containsPrivateReadingContent
      ? localizedText(
        "queueExportedStatus",
        "离线队列备份已导出；文件包含私密正文，请妥善保存。"
      )
      : localizedText(
        "queueMetadataExportedStatus",
        "离线队列备份已导出；其中只有标题、链接和队列元数据。"
      ), "success");
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(exportQueueButton, false, localizedText("exportQueueButton", "导出备份"));
  }
}

async function updateCaptureQueueRetention() {
  queueRetentionSelect.disabled = true;
  try {
    const result = await sendRuntimeMessage({
      type: "set-capture-queue-retention",
      retentionDays: Number(queueRetentionSelect.value)
    });
    updateQueuePanel(result);
    showStatus(result.purgedCount > 0
      ? localizedText("retentionUpdatedAndPurgedStatus", "保留期限已更新，并清理 {count} 项过期资料。", {
        count: result.purgedCount
      })
      : localizedText("retentionUpdatedStatus", "离线队列保留期限已更新。"), "success");
  } catch (error) {
    queueRetentionSelect.value = String(lastQueueStatus.retentionDays || 30);
    showStatus(readableError(error), "error");
  } finally {
    queueRetentionSelect.disabled = ["unknown", "failed"].includes(
      lastQueueStatus.queueState
    );
  }
}

async function updateCaptureQueuePrivacy() {
  const previousMode = lastQueueStatus.privacyMode || "links-only";
  const previousAllowPrivateSites = lastQueueStatus.allowPrivateSites === true;
  const privacyMode = queuePrivacyModeSelect.value;
  const allowPrivateSites = queueAllowPrivateSitesInput.checked;
  const totalItems = Number(lastQueueStatus.queuedCount || 0)
    + Number(lastQueueStatus.quarantinedCount || 0);
  const fullContentCount = Number(lastQueueStatus.fullContentCount || 0);

  if (privacyMode === "disabled" && totalItems > 0 && !globalThis.confirm(localizedText(
    "disableQueueConfirmation",
    "禁用离线队列会删除当前所有待保存内容和隔离项目。是否继续？"
  ))) {
    queuePrivacyModeSelect.value = previousMode;
    return;
  }
  if (privacyMode === "links-only" && fullContentCount > 0 && !globalThis.confirm(localizedText(
    "minimizeQueueConfirmation",
    "改为“仅标题和链接”会立即移除已排队的正文和网页归档，且无法恢复。是否继续？"
  ))) {
    queuePrivacyModeSelect.value = previousMode;
    return;
  }

  queuePrivacyModeSelect.disabled = true;
  queueAllowPrivateSitesInput.disabled = true;
  try {
    const result = await sendRuntimeMessage({
      type: "set-capture-queue-privacy",
      privacyMode,
      allowPrivateSites
    });
    updateQueuePanel(result);
    const changedCount = Number(result.purgedCount || 0)
      + Number(result.minimizedCount || 0);
    showStatus(changedCount > 0
      ? localizedText(
        "queuePrivacyUpdatedAndCleanedStatus",
        "离线队列隐私设置已更新，并处理 {count} 项已存储数据。",
        { count: changedCount }
      )
      : localizedText(
        "queuePrivacyUpdatedStatus",
        "离线队列隐私设置已更新。"
      ), "success");
  } catch (error) {
    queuePrivacyModeSelect.value = previousMode;
    queueAllowPrivateSitesInput.checked = previousAllowPrivateSites;
    showStatus(readableError(error), "error");
  } finally {
    const unavailable = ["unknown", "failed"].includes(lastQueueStatus.queueState);
    queuePrivacyModeSelect.disabled = unavailable;
    queueAllowPrivateSitesInput.disabled = unavailable;
  }
}

async function refreshQueueStatus(preferredDuplicateQueueID = null) {
  try {
    const result = await sendRuntimeMessage({ type: "capture-queue-status" });
    updateQueuePanel(result);
    const conflicts = result.duplicateConflicts || [];
    const currentURL = normalizedPageBindingURL(activeTab?.url);
    const matchingConflicts = conflicts.filter((item) =>
      normalizedPageBindingURL(item.sourceURL) === currentURL
    );
    const preferred = preferredDuplicateQueueID
      ? matchingConflicts.find((item) => item.queueID === preferredDuplicateQueueID)
      : null;
    showDuplicateConflict(preferred || matchingConflicts[0] || null);
    return result;
  } catch (error) {
    updateQueuePanel({
      queueState: "failed",
      queueError: readableError(error),
      queueErrorCode: error?.code || "queue-read-failed",
      queuedCount: 0,
      quarantinedCount: 0,
      blockedCount: 0,
      totalBytes: 0,
      queueItems: [],
      quarantinedItems: []
    });
    showDuplicateConflict(null);
    return null;
  }
}

function showDuplicateConflict(item) {
  const matchesCurrentPage = normalizedPageBindingURL(item?.sourceURL)
    === normalizedPageBindingURL(activeTab?.url);
  if (!item?.queueID || !item.conflict || !matchesCurrentPage) {
    activeDuplicateConflict = null;
    if (captureFlowState === "duplicate") transitionCaptureFlow("capture");
    else duplicatePanel.hidden = true;
    return;
  }
  activeDuplicateConflict = item;
  const conflict = item.conflict;
  transitionCaptureFlow("duplicate");
  duplicateMessage.textContent = conflict.incomingHasChanges
    ? localizedText("duplicateChangedMessage", "本次采集的正文与现有资料不同。")
    : localizedText("duplicateSameMessage", "本次采集的内容与现有资料相同。");
  duplicateDocument.textContent = conflict.title || localizedText("untitledDocument", "未命名资料");
  duplicateFolder.textContent = conflict.folder?.name || localizedText("uncategorized", "未分类");
  duplicateSize.textContent = formatBytes(Number(conflict.fileSizeBytes || 0));
  duplicateUpdated.textContent = conflict.updatedAt
    ? new Date(conflict.updatedAt).toLocaleString(uiLocale, { dateStyle: "short", timeStyle: "short" })
    : localizedText("unknown", "未知");
  const targetOption = Array.from(folderSelect.options || [])
    .find((option) => option.value === item.targetFolderID);
  duplicateTarget.textContent = item.targetNewFolderName
    || targetOption?.text
    || localizedText("uncategorized", "未分类");
}

function updateQueuePanel(result) {
  const state = ["unknown", "failed", "empty", "content"].includes(result?.queueState)
    ? result.queueState
    : Number(result?.queuedCount || 0) > 0
      ? "content"
      : "empty";
  lastQueueStatus = { ...result, queueState: state };
  const count = Number(result?.queuedCount || 0);
  const quarantined = Number(result?.quarantinedCount || 0);
  const blocked = Number(result?.blockedCount || 0);
  const totalItems = count + quarantined;
  const previousState = queuePanel.getAttribute("data-state");
  queuePanel.hidden = false;
  queuePanel.setAttribute("data-state", state);
  if (["content", "failed"].includes(state)) queuePanel.open = true;
  else if (previousState !== state) queuePanel.open = false;
  queuePanel.setAttribute("aria-busy", String(state === "unknown"));
  queueStateLabel.textContent = {
    unknown: localizedText("queueUnknown", "状态未知"),
    failed: localizedText("queueFailed", "读取失败"),
    empty: localizedText("queueEmpty", "队列为空"),
    content: localizedText("queueHasContent", "有待处理内容")
  }[state];
  queueCount.textContent = state === "unknown" ? "—" : String(totalItems);
  queueRetentionSelect.value = String(result?.retentionDays || 30);
  queueRetentionSelect.disabled = ["unknown", "failed"].includes(state);
  queuePrivacyModeSelect.value = result?.privacyMode || "links-only";
  queuePrivacyModeSelect.disabled = ["unknown", "failed"].includes(state);
  queueAllowPrivateSitesInput.checked = result?.allowPrivateSites === true;
  queueAllowPrivateSitesInput.disabled = ["unknown", "failed"].includes(state);
  retryQueueButton.disabled = state !== "content" || count === 0;
  discardQueueButton.disabled = ["unknown", "empty"].includes(state);
  exportQueueButton.disabled = ["unknown", "empty"].includes(state);
  const size = formatBytes(Number(result?.totalBytes || 0));
  if (state === "unknown") {
    queueSummaryLabel.textContent = localizedText("readingQueueStatus", "正在读取本地离线队列…");
  } else if (state === "failed") {
    const schema = result?.queueSchemaVersion == null
      ? ""
      : localizedText("queueSchemaSuffix", "（schema {version}）", {
        version: result.queueSchemaVersion
      });
    queueSummaryLabel.textContent = localizedText(
      "queueReadFailedSummary",
      "{error}{schema} 数据未被修改，可尝试导出备份。",
      {
        error: result?.queueError || localizedText("queueReadFailedError", "浏览器无法读取离线队列。"),
        schema
      }
    );
  } else if (state === "empty") {
    queueSummaryLabel.textContent = localizedText(
      "queueEmptySummary",
      "没有待保存内容；新内容最多在本机保留 {days} 天。",
      { days: result?.retentionDays || 30 }
    );
  } else {
    const blockedText = blocked > 0
      ? localizedText("queueBlockedSuffix", "；{count} 项等待手动处理", { count: blocked })
      : "";
    const quarantineText = quarantined > 0
      ? localizedText("queueQuarantinedSuffix", "；{count} 项损坏数据已隔离", { count: quarantined })
      : "";
    queueSummaryLabel.textContent = localizedText(
      "queueContentSummary",
      "{count} 项待保存 · {size}{blocked}{quarantined}。",
      { count, size, blocked: blockedText, quarantined: quarantineText }
    );
  }
  renderCaptureQueueItems(result?.queueItems || [], result?.quarantinedItems || []);
}

function renderCaptureQueueItems(items, quarantinedItems) {
  queueItemsContainer.replaceChildren();
  for (const item of items) {
    queueItemsContainer.append(captureQueueItemElement(item, false));
  }
  for (const item of quarantinedItems) {
    queueItemsContainer.append(captureQueueItemElement(item, true));
  }
}

function captureQueueItemElement(item, quarantined) {
  const details = document.createElement("details");
  details.className = "queue-item";
  const summary = document.createElement("summary");
  const status = quarantined ? localizedText("queueItemQuarantined", "已隔离") : queueItemStatusLabel(item.status);
  summary.textContent = localizedText("queueItemSummary", "{title} · {status}", {
    title: item.title || localizedText("untitledItem", "未命名项目"),
    status
  });
  details.append(summary);

  const metadata = document.createElement("p");
  metadata.className = "queue-item-meta";
  const source = queueItemSourceLabel(item.sourceURL);
  const timestamp = item.createdAt || item.quarantinedAt;
  metadata.textContent = [
    source,
    timestamp ? new Date(timestamp).toLocaleString(uiLocale, {
      dateStyle: "short",
      timeStyle: "short"
    }) : null,
    formatBytes(Number(item.byteSize || 0)),
    item.expiresAt ? localizedText("queueExpiresAt", "保留至 {date}", {
      date: new Date(item.expiresAt).toLocaleDateString(uiLocale)
    }) : null,
    quarantined && item.originalSchemaVersion != null
      ? `schema ${item.originalSchemaVersion}`
      : null,
    !quarantined
      ? item.storedContentMode === "links-only"
        ? localizedText("queueItemLinksOnly", "仅标题和链接")
        : localizedText("queueItemFullContent", "已保留完整内容")
      : null
  ].filter(Boolean).join(" · ");
  details.append(metadata);

  const explanatoryText = quarantined ? item.reason : item.lastError;
  if (explanatoryText) {
    const error = document.createElement("p");
    error.className = "queue-item-error";
    error.textContent = explanatoryText;
    details.append(error);
  }
  if (!quarantined && item.previewText) {
    const preview = document.createElement("p");
    preview.className = "queue-item-preview";
    preview.textContent = item.previewText;
    details.append(preview);
  }

  const actions = document.createElement("div");
  actions.className = "queue-item-actions";
  const deleteButton = document.createElement("button");
  deleteButton.type = "button";
  deleteButton.className = "quiet-danger";
  deleteButton.textContent = localizedText("deleteItemButton", "删除此项");
  deleteButton.setAttribute("aria-label", localizedText(
    "deleteItemAriaLabel",
    "删除{kind}{title}",
    {
      kind: quarantined
        ? localizedText("quarantinedItem", "隔离项目")
        : localizedText("queuedItem", "待保存项目"),
      title: item.title || localizedText("untitledItem", "未命名项目")
    }
  ));
  deleteButton.addEventListener("click", () =>
    deleteCaptureQueueItem(item.id, quarantined, item.title)
  );
  actions.append(deleteButton);
  details.append(actions);
  return details;
}

function queueItemStatusLabel(status) {
  switch (status) {
  case "duplicate": return localizedText("queueItemDuplicate", "等待重复处理");
  case "failed": return localizedText("queueItemRetryFailed", "重试失败");
  case "retrying": return localizedText("queueItemRetrying", "等待自动重试");
  default: return localizedText("queueItemPending", "等待保存");
  }
}

function queueItemSourceLabel(value) {
  try {
    return new URL(value).hostname;
  } catch {
    return localizedText("unknownSource", "来源未知");
  }
}

function formatBytes(bytes) {
  if (bytes < 1_024) return `${bytes} B`;
  if (bytes < 1_024 * 1_024) return `${(bytes / 1_024).toFixed(1)} KB`;
  return `${(bytes / (1_024 * 1_024)).toFixed(1)} MB`;
}

async function sendRuntimeMessage(message) {
  const response = await extensionAPI.runtime.sendMessage(message);
  if (!response?.ok) {
    const error = new Error(response?.error || localizedText("backgroundError", "插件后台处理失败。"));
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
  sessionTitle.textContent = offline
    ? localizedText("offlineSessionTitle", "已保存配对令牌，应用离线")
    : localizedText("connectedSessionTitle", "已连接本机资料库");
  const available = connected || offline;
  batchReviewPanel.hidden = !available || batchReviewPhase === "hidden";
  renderCaptureFlowState();
  directSaveButton.disabled = !(connected || offline);
  batchSaveButton.disabled = !available || highlightedTabs.length < 2;
  main.setAttribute("aria-busy", String(connecting));
  extensionAPI.runtime.sendMessage({
    type: "toolbar-state",
    state,
    message: state === "offline"
      ? localizedText("offlineToolbarMessage", "应用未运行，保存内容会进入队列")
      : ""
  }).catch(() => {});
}

function showStatus(message, kind = "") {
  const isError = kind === "error";
  statusLabel.textContent = isError ? "" : message;
  statusLabel.className = isError ? "" : kind;
  alertLabel.textContent = isError ? message : "";
}

function readableError(error) {
  const message = String(error?.message || error);
  if (/failed to fetch|networkerror|network request failed|load failed|connection refused/i.test(message)) {
    return localizedText(
      "cannotConnectError",
      "无法连接应用。请先打开“RepoPress Studio”，再检查令牌。"
    );
  }
  return error?.message || String(error);
}

function isNetworkFailure(error) {
  return error?.code === "native-host-error"
    || /failed to fetch|networkerror|network request failed|load failed|connection refused/i
    .test(String(error?.message || error));
}
