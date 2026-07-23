if (!globalThis.KNOWLEDGE_NATIVE_MESSAGING_PROTOCOL
    && typeof globalThis.importScripts === "function") {
  globalThis.importScripts("protocol.generated.js");
}
const NATIVE_MESSAGING_PROTOCOL = globalThis.KNOWLEDGE_NATIVE_MESSAGING_PROTOCOL;
if (!NATIVE_MESSAGING_PROTOCOL) {
  throw new Error("浏览器本机桥接协议常量未载入。");
}
const MAX_ARCHIVE_BYTES = 24 * 1024 * 1024;
const MAX_TEXT_BYTES = 5 * 1024 * 1024;
const CAPTURE_MODES = new Set(["cleaned-article", "full-page", "selection", "link-only"]);
const OPERATION_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const extensionAPI = globalThis.browser ?? globalThis.chrome;
const menuAPI = extensionAPI.contextMenus ?? extensionAPI.menus;
if (!globalThis.KNOWLEDGE_BACKGROUND_MODULES_LOADED
    && typeof globalThis.importScripts === "function") {
  globalThis.importScripts(
    "background-security.js",
    "background-queue-storage.js",
    "background-queue-operations.js",
    "background-capture.js"
  );
}
if (!globalThis.KNOWLEDGE_BACKGROUND_MODULES_LOADED) {
  throw new Error("浏览器后台职责模块未载入。");
}
function newOperationID() {
  const nativeID = globalThis.crypto?.randomUUID?.();
  if (nativeID && OPERATION_ID_PATTERN.test(nativeID)) return nativeID.toLowerCase();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (character) => {
    const value = Math.floor(Math.random() * 16);
    return (character === "x" ? value : ((value & 0x3) | 0x8)).toString(16);
  });
}

function normalizedOperationID(value) {
  const operationID = String(value || "").trim().toLowerCase();
  return OPERATION_ID_PATTERN.test(operationID) ? operationID : null;
}

function envelopeWithOperationID(envelope) {
  const operationID = normalizedOperationID(envelope?.operationID) || newOperationID();
  return { ...envelope, operationID };
}

extensionAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
  let operation;
  switch (message?.type) {
  case "toolbar-state":
    operation = setToolbarState(message.state, message.message);
    break;
  case "capture-tabs-batch":
    operation = captureTabsBatch(message);
    break;
  case "prepare-capture-preview":
    operation = prepareCapturePreview(message);
    break;
  case "save-prepared-capture":
    operation = savePreparedCapture(message);
    break;
  case "capture-and-save":
    operation = captureAndSave(message);
    break;
  case "capture-queue-status":
    operation = withQueueLock(captureQueueStatus);
    break;
  case "delete-capture-queue-item":
    operation = deleteCaptureQueueItem(message.queueID, Boolean(message.quarantined));
    break;
  case "export-capture-queue":
    operation = exportCaptureQueue();
    break;
  case "set-capture-queue-retention":
    operation = setCaptureQueueRetention(message.retentionDays);
    break;
  case "set-capture-queue-privacy":
    operation = setCaptureQueuePrivacy(message.privacyMode, message.allowPrivateSites);
    break;
  case "retry-capture-queue":
    operation = flushCaptureQueue(message.token, Boolean(message.force));
    break;
  case "open-knowledge-document":
    operation = openKnowledgeDocument(message.documentID, message.token);
    break;
  case "resolve-duplicate-capture":
    operation = resolveDuplicateCapture(message.queueID, message.resolution, message.token);
    break;
  case "cancel-duplicate-capture":
    operation = cancelDuplicateCapture(message.queueID);
    break;
  case "discard-capture-queue":
    operation = discardCaptureQueue();
    break;
  case "validate-archive-resource-url":
    operation = validateArchiveResourceURL(message.url, sender);
    break;
  case "confirm-archive-resource-peer":
    operation = confirmArchiveResourcePeer(message.url, message.guardID, sender);
    break;
  case "bridge-request":
    operation = bridgeRequestForPopup(message);
    break;
  default:
    return false;
  }
  const reportsCaptureState = [
    "capture-and-save", "save-prepared-capture", "capture-tabs-batch",
    "resolve-duplicate-capture", "retry-capture-queue"
  ].includes(message?.type);
  if (reportsCaptureState) setToolbarState("saving").catch(() => {});
  operation
    .then(async (result) => {
      if (reportsCaptureState) await reflectCaptureResult(result);
      sendResponse({ ok: true, result });
    })
    .catch(async (error) => {
      if (reportsCaptureState) await setToolbarState("error", readableError(error));
      sendResponse({ ok: false, error: readableError(error), code: error?.code || null });
    });
  return true;
});

extensionAPI.alarms?.onAlarm?.addListener((alarm) => {
  if (alarm.name === CAPTURE_QUEUE_ALARM) {
    flushCaptureQueue(null, false).catch(() => {});
  }
});
extensionAPI.runtime.onStartup?.addListener(() => {
  scheduleCaptureQueueRetry().catch(() => {});
  setupContextMenus().catch(() => {});
});
extensionAPI.runtime.onInstalled?.addListener(() => {
  scheduleCaptureQueueRetry().catch(() => {});
  setupContextMenus().catch(() => {});
});
menuAPI?.onClicked?.addListener((info, tab) => {
  handleContextMenuClick(info, tab).catch((error) => {
    setToolbarState("error", readableError(error)).catch(() => {});
  });
});
extensionAPI.commands?.onCommand?.addListener((command, tab) => {
  handleCommand(command, tab).catch((error) => {
    setToolbarState("error", readableError(error)).catch(() => {});
  });
});

async function setToolbarState(state, message = "") {
  const action = extensionAPI.action;
  if (!action) return { state };
  const presentation = {
    connected: { text: "ON", color: "#188038", title: "资料采集：已连接到本机资料库" },
    connecting: { text: "…", color: "#3478f6", title: "资料采集：正在连接" },
    saving: { text: "…", color: "#3478f6", title: "资料采集：正在保存" },
    success: { text: "✓", color: "#188038", title: "资料采集：保存成功" },
    offline: { text: "离", color: "#9a6700", title: "资料采集：应用离线，内容将进入队列" },
    error: { text: "!", color: "#d93025", title: "资料采集：操作失败" },
    disconnected: { text: "", color: "#6e7781", title: "资料采集：尚未连接" }
  }[state] || { text: "", color: "#6e7781", title: "保存到资料库" };
  const title = message ? `${presentation.title}；${message}` : presentation.title;
  await Promise.all([
    action.setBadgeBackgroundColor({ color: presentation.color }),
    action.setBadgeText({ text: presentation.text }),
    action.setTitle({ title })
  ]);
  return { state };
}

async function setQueueToolbarState(count, blocked = 0) {
  if (count <= 0) return setToolbarState("connected");
  const action = extensionAPI.action;
  if (!action) return;
  const text = count > 99 ? "99+" : String(count);
  const title = blocked > 0
    ? `资料采集：${count} 项待处理，其中 ${blocked} 项需要确认`
    : `资料采集：${count} 项等待写入资料库`;
  await Promise.all([
    action.setBadgeBackgroundColor({ color: blocked > 0 ? "#d93025" : "#9a6700" }),
    action.setBadgeText({ text }),
    action.setTitle({ title })
  ]);
}

async function reflectCaptureResult(result) {
  const queuedCount = Number(result?.queuedCount || 0);
  const blockedCount = Number(result?.blockedCount || 0);
  if (queuedCount > 0) return setQueueToolbarState(queuedCount, blockedCount);
  const failures = Number(result?.failedCount || 0);
  if (failures > 0) {
    return setToolbarState("error", `${failures} 个标签页保存失败`);
  }
  if (result?.importedCount === 0 && !result?.documentID
      && !(result?.receipts || []).length && result?.requestedCount == null) {
    return setToolbarState("connected");
  }
  return setToolbarState("success");
}

async function setupContextMenus() {
  if (!menuAPI) return;
  if (globalThis.browser) {
    await menuAPI.removeAll();
  } else {
    await new Promise((resolve) => menuAPI.removeAll(resolve));
  }
  menuAPI.create({
    id: "knowledge-save-cleaned",
    title: "保存净化正文到资料库",
    contexts: ["page"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
  menuAPI.create({
    id: "knowledge-save-selection",
    title: "保存选中文字到资料库",
    contexts: ["selection"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
  menuAPI.create({
    id: "knowledge-save-link",
    title: "仅保存此链接到资料库",
    contexts: ["link"],
    targetUrlPatterns: ["http://*/*", "https://*/*"]
  });
}

async function handleContextMenuClick(info, tab) {
  if (!tab?.id) throw new Error("没有找到可保存的标签页。");
  if (info.menuItemId === "knowledge-save-cleaned") {
    return quickSaveTab(tab, "cleaned-article");
  }
  if (info.menuItemId === "knowledge-save-selection") {
    const text = String(info.selectionText || "").trim();
    if (!text) throw new Error("没有可保存的选中文字。");
    return quickSavePreparedCapture(tab, contextCapture({
      sourceURL: info.pageUrl || tab.url,
      title: tab.title || "网页摘录",
      contentText: text,
      captureMode: "selection"
    }));
  }
  if (info.menuItemId === "knowledge-save-link") {
    const sourceURL = info.linkUrl;
    if (!/^https?:/i.test(sourceURL || "")) throw new Error("该链接不能保存到资料库。");
    const title = String(info.selectionText || sourceURL).trim();
    return quickSavePreparedCapture(tab, contextCapture({
      sourceURL,
      title,
      contentText: `[${escapedMarkdownLabel(title)}](${sourceURL})`,
      captureMode: "link-only"
    }));
  }
}

async function handleCommand(command, tab) {
  if (!tab?.id) {
    [tab] = await extensionAPI.tabs.query({ active: true, currentWindow: true });
  }
  if (!tab?.id) throw new Error("没有找到当前标签页。");
  if (command === "quick-save-cleaned") return quickSaveTab(tab, "cleaned-article");
  if (command === "quick-save-selection") return quickSaveTab(tab, "selection");
}

async function quickSaveTab(tab, captureMode) {
  const settings = await quickSaveSettings(tab.url);
  await setToolbarState("saving");
  const result = await captureAndSave({
    tabId: tab.id,
    token: settings.token,
    folderID: settings.folderID,
    newFolderName: null,
    captureMode,
    allowsAIUse: settings.allowsAIUse
  });
  await rememberBackgroundReceipt(result);
  await reflectCaptureResult(result);
  return result;
}

async function quickSavePreparedCapture(tab, capture) {
  const settings = await quickSaveSettings(capture.sourceURL || tab.url);
  capture.allowsAIUse = settings.allowsAIUse;
  await setToolbarState("saving");
  const result = await savePreparedCapture({
    tabId: tab.id,
    token: settings.token,
    folderID: settings.folderID,
    newFolderName: null,
    captureMode: capture.captureMode,
    capture
  });
  await rememberBackgroundReceipt(result);
  await reflectCaptureResult(result);
  return result;
}

async function quickSaveSettings(sourceURL) {
  const stored = await extensionAPI.storage.local.get([
    "bridgeToken",
    "selectedKnowledgeFolderID",
    "knowledgeDomainFoldersV1",
    "defaultKnowledgeAllowsAIUseV1"
  ]);
  if (!stored.bridgeToken) throw new Error("请先打开插件并连接本机资料库。");
  const domain = normalizedDomain(sourceURL);
  return {
    token: stored.bridgeToken,
    folderID: stored.knowledgeDomainFoldersV1?.[domain]
      || stored.selectedKnowledgeFolderID
      || null,
    allowsAIUse: stored.defaultKnowledgeAllowsAIUseV1 !== false
  };
}

function contextCapture({ sourceURL, title, contentText, captureMode }) {
  return {
    schemaVersion: 1,
    sourceURL,
    title,
    authors: [],
    language: null,
    summary: "",
    tags: [],
    capturedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contentText,
    originalHTML: null,
    archiveFormat: null,
    archiveData: null,
    archiveEmbeddedResourceCount: null,
    archiveMissingResourceCount: null,
    archiveWasTruncated: null,
    captureMode,
    allowsAIUse: true
  };
}

function escapedMarkdownLabel(value) {
  return String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/\[/g, "\\[")
    .replace(/\]/g, "\\]");
}

function normalizedDomain(value) {
  try {
    const host = new URL(value).hostname.toLowerCase();
    return host.startsWith("www.") ? host.slice(4) : host;
  } catch {
    return "";
  }
}

function normalizedPageIdentityURL(value) {
  try {
    const url = new URL(String(value || ""));
    if (!["http:", "https:"].includes(url.protocol)
        || !url.hostname
        || url.username
        || url.password) return null;
    return url.href;
  } catch {
    return null;
  }
}

function sanitizedPageIdentity(value) {
  const url = normalizedPageIdentityURL(value?.url || value?.pageURL);
  if (!url) throw new Error("页面身份无效，请重新保存。");
  const documentId = typeof value?.documentId === "string" && value.documentId.trim()
    ? value.documentId.trim()
    : null;
  return { url, documentId };
}

function pageIdentityFromInjection(injection, page) {
  const result = injection?.[0];
  return sanitizedPageIdentity({
    url: page?.pageURL || page?.sourceURL,
    documentId: result?.documentId || null
  });
}

function pageIdentityChangedError() {
  const error = new Error("页面已发生跳转，保存已取消；请重新保存。");
  error.code = "page-identity-changed";
  return error;
}

function assertMatchingPageIdentity(expectedValue, actualValue) {
  const expected = sanitizedPageIdentity(expectedValue);
  const actual = sanitizedPageIdentity(actualValue);
  if (expected.url !== actual.url
      || (expected.documentId && expected.documentId !== actual.documentId)) {
    throw pageIdentityChangedError();
  }
  return actual;
}

async function readTabPageIdentity(tabId) {
  const injection = await extensionAPI.scripting.executeScript({
    target: { tabId },
    func: readPageIdentity
  });
  return pageIdentityFromInjection(injection, injection?.[0]?.result);
}

function readPageIdentity() {
  return { pageURL: location.href };
}

async function rememberBackgroundReceipt(result) {
  const receipt = result?.receipt || result;
  if (receipt?.documentID) {
    await extensionAPI.storage.local.set({ lastKnowledgeSaveReceiptV1: receipt });
  }
}

async function captureAndSave(message) {
  const captureMode = message.captureMode
    || (message.includeArchive ? "full-page" : "cleaned-article");
  const prepared = await prepareCapturePreview({
    tabId: message.tabId,
    captureMode,
    expectedPageIdentity: message.expectedPageIdentity || null
  });
  prepared.capture.allowsAIUse = message.allowsAIUse !== false;
  return savePreparedCapture({
    ...message,
    captureMode,
    operationID: prepared.operationID,
    pageIdentity: prepared.pageIdentity,
    capture: prepared.capture
  });
}

async function captureTabsBatch(message) {
  const temporaryPermissionOrigins = normalizedTemporaryPermissionOrigins(
    message.temporaryPermissionOrigins
  );
  let result;
  let captureError;
  try {
    result = await performCaptureTabsBatch(message);
  } catch (error) {
    captureError = error;
  }
  const unreleasedTemporaryOrigins = await releaseTemporaryPermissionOrigins(
    temporaryPermissionOrigins
  );
  if (captureError) throw captureError;
  return {
    ...result,
    temporaryPermissionsReleased: unreleasedTemporaryOrigins.length === 0,
    unreleasedTemporaryOrigins
  };
}

async function performCaptureTabsBatch(message) {
  const tabIdentities = normalizedBatchTabIdentities(message.tabIdentities);
  if (!message.token || tabIdentities.length < 1) {
    throw new Error("没有可保存的网页标签页。");
  }
  const batchOperationID = normalizedOperationID(message.batchOperationID) || newOperationID();
  const captureMode = normalizedCaptureMode(message.captureMode);
  if (captureMode === "selection") {
    throw new Error("批量保存不支持“选中文字”模式，请选择净化正文、完整网页或仅链接。");
  }
  const receipts = [];
  const errors = [];
  const items = [];
  let conflictCount = 0;
  let queuedDuringBatch = 0;
  for (const plannedTab of tabIdentities) {
    const tabId = plannedTab.tabId;
    await reportBatchProgress(batchOperationID, plannedTab, "saving");
    try {
      const result = await captureAndSave({
        tabId,
        expectedPageIdentity: { url: plannedTab.url },
        token: message.token,
        folderID: message.folderID || null,
        newFolderName: message.newFolderName || null,
        captureMode,
        allowsAIUse: message.allowsAIUse !== false
      });
      let status;
      let receipt = null;
      if (result.requiresDuplicateResolution) {
        conflictCount += 1;
        status = "conflict";
      } else if (result.queued) {
        queuedDuringBatch += 1;
        status = "queued";
      } else if (result.documentID) {
        receipts.push(result);
        receipt = result;
        status = "saved";
      } else {
        throw new Error("资料库未返回该网页的保存结果。");
      }
      const item = {
        tabId,
        url: plannedTab.url,
        title: plannedTab.title,
        status,
        error: null,
        receipt
      };
      items.push(item);
      await reportBatchProgress(batchOperationID, plannedTab, status, null, receipt);
    } catch (error) {
      const message = readableError(error);
      errors.push({ tabId, message });
      items.push({
        tabId,
        url: plannedTab.url,
        title: plannedTab.title,
        status: "failed",
        error: message,
        receipt: null
      });
      await reportBatchProgress(batchOperationID, plannedTab, "failed", message);
    }
  }
  const summary = queueSummary(await readCaptureQueue());
  if (receipts.length) {
    await extensionAPI.storage.local.set({
      lastKnowledgeSaveReceiptV1: receipts[receipts.length - 1]
    });
  }
  return {
    batchOperationID,
    requestedCount: tabIdentities.length,
    savedCount: receipts.length,
    importedCount: receipts.length,
    queuedDuringBatch,
    conflictCount,
    failedCount: errors.length,
    errors,
    items,
    receipts,
    ...summary
  };
}

function normalizedBatchTabIdentities(values) {
  if (!Array.isArray(values)) return [];
  const result = [];
  const seenTabIDs = new Set();
  for (const value of values.slice(0, 10)) {
    const tabId = value?.tabId;
    const url = normalizedPageIdentityURL(value?.url);
    if (!Number.isInteger(tabId) || !url || seenTabIDs.has(tabId)) {
      throw new Error("批量授权计划已失效，请重新选择网页并授权。");
    }
    seenTabIDs.add(tabId);
    result.push({
      tabId,
      url,
      title: String(value?.title || "").trim().slice(0, 300)
    });
  }
  return result;
}

async function reportBatchProgress(batchOperationID, plannedTab, status, error = null, receipt = null) {
  try {
    const delivery = extensionAPI.runtime.sendMessage?.({
      type: "capture-tabs-batch-progress",
      batchOperationID,
      tabId: plannedTab.tabId,
      url: plannedTab.url,
      title: plannedTab.title,
      status,
      error,
      receipt
    });
    if (delivery && typeof delivery.then === "function") await delivery;
  } catch {
    // The popup may close while the background task continues; the final batch result remains authoritative.
  }
}

function normalizedTemporaryPermissionOrigins(values) {
  return Array.from(new Set(Array.isArray(values) ? values : []))
    .slice(0, 10)
    .map((value) => {
      const raw = String(value || "").trim();
      if (!raw.endsWith("/*")) return null;
      try {
        const url = new URL(raw.slice(0, -1));
        if (!["http:", "https:"].includes(url.protocol)
            || !url.hostname
            || url.hostname.includes("*")
            || url.username
            || url.password) return null;
        const normalized = `${url.protocol}//${url.hostname}/*`;
        return raw === normalized ? normalized : null;
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function releaseTemporaryPermissionOrigins(origins) {
  if (!origins.length) return [];
  try {
    await extensionAPI.permissions.remove({ origins });
  } catch {
    // The popup may already have removed them. Verify exact origins below.
  }
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

async function prepareCapturePreview(message) {
  if (!Number.isInteger(message.tabId)) {
    throw new Error("没有找到可采集的浏览器标签页。");
  }
  const captureMode = normalizedCaptureMode(message.captureMode);
  const injection = await extensionAPI.scripting.executeScript({
    target: { tabId: message.tabId },
    func: extractPage,
    args: [MAX_ARCHIVE_BYTES, MAX_TEXT_BYTES, false, captureMode]
  });
  const page = injection?.[0]?.result;
  if (!page?.sourceURL || !page?.contentText) {
    throw new Error(captureMode === "selection"
      ? "当前页面没有选中文字；请先选择内容再保存。"
      : "没有从当前页面提取到可保存的内容。");
  }
  const pageIdentity = pageIdentityFromInjection(injection, page);
  if (message.expectedPageIdentity) {
    assertMatchingPageIdentity(message.expectedPageIdentity, pageIdentity);
  }
  const capture = captureFromPage(page, captureMode);
  const textBytes = new TextEncoder().encode(JSON.stringify(capture)).length;
  const estimatedArchiveBytes = captureMode === "full-page"
    ? Math.min(MAX_ARCHIVE_BYTES, Math.max(0, Number(page.estimatedArchiveBytes || 0)))
    : 0;
  return {
    operationID: newOperationID(),
    captureMode,
    pageIdentity,
    capture,
    previewText: previewExcerpt(capture.contentText),
    estimatedSizeBytes: textBytes + estimatedArchiveBytes,
    archiveType: captureMode === "full-page"
      ? (extensionAPI.pageCapture?.saveAsMHTML ? "mhtml" : "html")
      : "none"
  };
}

async function savePreparedCapture(message) {
  if (!message.token || !Number.isInteger(message.tabId)) {
    throw new Error("连接信息不完整，请重新打开插件。");
  }
  const captureMode = normalizedCaptureMode(message.captureMode);
  const capture = sanitizedPreparedCapture(message.capture, captureMode);
  const expectedPageIdentity = captureMode === "full-page"
    ? sanitizedPageIdentity(message.pageIdentity)
    : null;

  let archiveData = null;
  let archiveFormat = null;
  let archiveReport = null;
  const supportsMHTML = Boolean(extensionAPI.pageCapture?.saveAsMHTML);
  if (captureMode === "full-page" && supportsMHTML) {
    assertMatchingPageIdentity(
      expectedPageIdentity,
      await readTabPageIdentity(message.tabId)
    );
    const archive = await saveAsMHTML(message.tabId).catch(() => null);
    if (archive) {
      assertMatchingPageIdentity(
        expectedPageIdentity,
        await readTabPageIdentity(message.tabId)
      );
    }
    if (archive && archive.size <= MAX_ARCHIVE_BYTES) {
      archiveData = await blobToBase64(archive);
      archiveFormat = "mhtml";
    }
  }
  if (captureMode === "full-page" && !archiveData) {
    const injection = await extensionAPI.scripting.executeScript({
      target: { tabId: message.tabId },
      func: extractPage,
      args: [MAX_ARCHIVE_BYTES, MAX_TEXT_BYTES, true, "full-page"]
    });
    const archivePage = injection?.[0]?.result;
    if (!archivePage?.originalHTML) {
      throw new Error("浏览器没有返回可保存的完整网页归档。");
    }
    assertMatchingPageIdentity(
      expectedPageIdentity,
      pageIdentityFromInjection(injection, archivePage)
    );
    const archive = new Blob([archivePage.originalHTML], { type: "text/html;charset=utf-8" });
    if (archive.size <= MAX_ARCHIVE_BYTES) {
      archiveData = await blobToBase64(archive);
      archiveFormat = "html";
      archiveReport = archivePage?.archiveReport || {
        format: "html",
        embeddedResourceCount: 0,
        missingResourceCount: 0,
        wasTruncated: false
      };
    }
  }

  const finalizedCapture = {
    ...capture,
    originalHTML: null,
    archiveFormat,
    archiveData,
    archiveEmbeddedResourceCount: archiveReport?.embeddedResourceCount ?? null,
    archiveMissingResourceCount: archiveReport?.missingResourceCount ?? null,
    archiveWasTruncated: archiveReport?.wasTruncated ?? null
  };

  const envelope = envelopeWithOperationID({
    operationID: message.operationID,
    capture: finalizedCapture,
    folderID: message.folderID || null,
    newFolderName: message.newFolderName || null
  });
  try {
    const payload = await submitCaptureEnvelope(envelope, message.token);
    if (payload.requiresDuplicateResolution) {
      const privacyContext = await captureQueuePrivacyContext(message.tabId, envelope);
      const queued = await enqueueDuplicateConflict(
        envelope,
        payload.conflict,
        archiveReport,
        privacyContext
      );
      return {
        ...payload,
        conflictQueueID: queued.queueID,
        queuedCount: queued.queuedCount,
        blockedCount: queued.blockedCount,
        archiveReport
      };
    }
    return { ...payload, archiveReport };
  } catch (error) {
    if (!error?.retryable) throw error;
    const privacyContext = await captureQueuePrivacyContext(message.tabId, envelope);
    const queue = await enqueueCapture(envelope, archiveReport, error, privacyContext);
    return {
      queued: true,
      queuedCount: queue.queuedCount,
      blockedCount: queue.blockedCount,
      archiveReport
    };
  }
}

function normalizedCaptureMode(value) {
  const mode = String(value || "cleaned-article");
  if (!CAPTURE_MODES.has(mode)) throw new Error("采集模式无效，请重新选择后保存。");
  return mode;
}

function captureFromPage(page, captureMode) {
  return {
    schemaVersion: 1,
    sourceURL: page.sourceURL,
    title: page.title,
    authors: page.authors || [],
    language: page.language || null,
    summary: page.summary || "",
    tags: page.tags || [],
    capturedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contentText: page.contentText,
    originalHTML: null,
    archiveFormat: null,
    archiveData: null,
    archiveEmbeddedResourceCount: null,
    archiveMissingResourceCount: null,
    archiveWasTruncated: null,
    captureMode,
    allowsAIUse: true
  };
}

function sanitizedPreparedCapture(value, captureMode) {
  if (!value || value.schemaVersion !== 1) {
    throw new Error("采集内容已失效，请重新保存。");
  }
  let sourceURL;
  try {
    sourceURL = new URL(String(value.sourceURL || ""));
  } catch {
    throw new Error("页面地址无效，请重新保存。");
  }
  if (!["http:", "https:"].includes(sourceURL.protocol)
      || sourceURL.username || sourceURL.password) {
    throw new Error("页面地址无效，请重新保存。");
  }
  sourceURL.hash = "";
  const title = String(value.title || "").trim().slice(0, 300);
  const contentText = String(value.contentText || "").trim();
  if (!title) throw new Error("标题不能为空。");
  if (!contentText) throw new Error("保存内容为空，请重新保存。");
  if (new TextEncoder().encode(contentText).length > MAX_TEXT_BYTES) {
    throw new Error("正文超过 5 MB，请缩小选择范围后重试。");
  }
  const normalizedList = (items, maximumCount, maximumLength) => (Array.isArray(items) ? items : [])
    .map((item) => String(item || "").trim().slice(0, maximumLength))
    .filter(Boolean)
    .slice(0, maximumCount);
  return {
    schemaVersion: 1,
    sourceURL: sourceURL.href,
    title,
    authors: normalizedList(value.authors, 30, 120),
    language: String(value.language || "").trim().slice(0, 40) || null,
    summary: String(value.summary || "").trim().slice(0, 20_000),
    tags: normalizedList(value.tags, 50, 80),
    capturedAt: value.capturedAt || new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contentText,
    originalHTML: null,
    archiveFormat: null,
    archiveData: null,
    archiveEmbeddedResourceCount: null,
    archiveMissingResourceCount: null,
    archiveWasTruncated: null,
    captureMode,
    allowsAIUse: value.allowsAIUse !== false
  };
}

function previewExcerpt(value) {
  const maximumCharacters = 12_000;
  return value.length <= maximumCharacters
    ? value
    : `${value.slice(0, maximumCharacters)}\n\n……片段已截断，实际保存会保留完整正文。`;
}

async function submitCaptureEnvelope(envelope, token) {
  const requestEnvelope = envelopeWithOperationID(envelope);
  const response = await performBridgeRequest("/v1/import", "POST", token, requestEnvelope);
  if (!response.ok) {
    await handleBridgeAuthenticationFailure(response.status, response.payload);
    const retryable = response.status === 0
      || response.status === 408
      || response.status === 425
      || response.status === 429
      || response.status >= 500;
    const error = bridgeError(
      response.payload.error || "资料库拒绝了页面（HTTP " + response.status + "）。",
      response.status,
      retryable
    );
    error.code = response.payload.code || null;
    throw error;
  }
  if (normalizedOperationID(response.payload.operationID)
      !== normalizedOperationID(requestEnvelope.operationID)) {
    const error = bridgeError(
      "应用返回的保存操作回执不匹配；请升级应用和扩展后重新保存。",
      409,
      false
    );
    error.code = "operation-receipt-mismatch";
    throw error;
  }
  return response.payload;
}

async function openKnowledgeDocument(documentID, token) {
  if (!documentID || !token) {
    throw new Error("资料定位信息不完整，请重新连接插件。");
  }
  const response = await performBridgeRequest("/v1/open", "POST", token, { documentID });
  if (!response.ok) {
    await handleBridgeAuthenticationFailure(response.status, response.payload);
    const error = bridgeError(
      response.payload.error || "无法在资料库中打开该资料。",
      response.status,
      false
    );
    error.code = response.payload.code || null;
    throw error;
  }
  return response.payload;
}

async function bridgeRequestForPopup(message) {
  const path = String(message.path || "");
  const method = String(message.method || "GET").toUpperCase();
  const response = await performBridgeRequest(path, method, message.token, message.body ?? null);
  if (!response.ok) {
    await handleBridgeAuthenticationFailure(response.status, response.payload);
    const error = bridgeError(
      response.payload.error || `连接失败（HTTP ${response.status}）`,
      response.status,
      response.status === 0 || response.status >= 500
    );
    error.code = response.payload.code || null;
    throw error;
  }
  return response.payload;
}

async function performBridgeRequest(path, method, token, body = null) {
  const normalizedMethod = String(method || "").toUpperCase();
  if (!NATIVE_MESSAGING_PROTOCOL.routes[path]?.includes(normalizedMethod)) {
    throw new Error("扩展请求了未允许的本机资料库接口。");
  }
  if (!token) {
    return {
      ok: false,
      status: 401,
      payload: { error: "缺少连接令牌，请重新配对。", code: "invalid-token" },
      transport: "none"
    };
  }
  try {
    const bodyJSON = body == null ? null : JSON.stringify(body);
    if (bodyJSON != null
        && new TextEncoder().encode(bodyJSON).length
          > NATIVE_MESSAGING_PROTOCOL.maximumInputBytes) {
      throw new Error("本机桥接请求正文超过协议上限。");
    }
    const headers = {
      "Authorization": `Bearer ${token}`,
      [NATIVE_MESSAGING_PROTOCOL.loopback.protocolHeaderName]:
        NATIVE_MESSAGING_PROTOCOL.loopback.protocolHeaderValue
    };
    if (bodyJSON != null) headers["Content-Type"] = "application/json";
    const response = await fetch(
      `${NATIVE_MESSAGING_PROTOCOL.loopback.baseURL}${path}`,
      {
        method: normalizedMethod,
        headers,
        body: bodyJSON,
        cache: "no-store",
        credentials: "omit",
        redirect: "error"
      }
    );
    let payload = {};
    try {
      payload = await response.json();
    } catch {
      if (response.status !== 204) {
        throw new Error("应用返回了无效的本机桥接响应。");
      }
    }
    return {
      ok: response.ok,
      status: response.status,
      payload,
      transport: "loopback"
    };
  } catch (loopbackError) {
    return {
      ok: false,
      status: 0,
      payload: {
        error: "无法连接 RepoPress。请先打开应用，再确认连接令牌有效。",
        code: "loopback-bridge-unavailable",
        detail: readableError(loopbackError)
      },
      transport: "loopback"
    };
  }
}

function bridgeError(message, status, retryable) {
  const error = new Error(message);
  error.status = status;
  error.retryable = retryable;
  return error;
}

async function handleBridgeAuthenticationFailure(status, payload) {
  if (![401, 403].includes(status)
      || !["token-expired", "invalid-token"].includes(payload?.code)) return;
  await extensionAPI.storage.local.remove(["bridgeToken"]);
  await setToolbarState("disconnected", payload.error || "需要重新配对");
}

function readableError(error) {
  if (String(error?.message || error).includes("Failed to fetch")) {
    return "无法连接应用。请打开“RepoPress”，并确认连接令牌有效。";
  }
  return error?.message || String(error);
}
