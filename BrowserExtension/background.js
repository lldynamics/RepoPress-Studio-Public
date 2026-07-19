const NATIVE_HOST_NAME = "com.jinfang.personal_site_publisher.knowledge";
const NATIVE_MESSAGE_SCHEMA_VERSION = 1;
const MAX_ARCHIVE_BYTES = 24 * 1024 * 1024;
const MAX_TEXT_BYTES = 5 * 1024 * 1024;
const CAPTURE_QUEUE_KEY = "pendingKnowledgeCapturesV1";
const CAPTURE_QUEUE_ALARM = "retry-pending-knowledge-captures";
const MAX_QUEUE_ITEMS = 10;
const MAX_QUEUE_BYTES = 96 * 1024 * 1024;
const CAPTURE_MODES = new Set(["cleaned-article", "full-page", "selection", "link-only"]);
const extensionAPI = globalThis.browser ?? globalThis.chrome;
const menuAPI = extensionAPI.contextMenus ?? extensionAPI.menus;
let queueOperation = Promise.resolve();

extensionAPI.runtime.onMessage.addListener((message, _sender, sendResponse) => {
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
    operation = withQueueLock(async () => queueSummary(await readCaptureQueue()));
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
    captureMode
  });
  prepared.capture.allowsAIUse = message.allowsAIUse !== false;
  return savePreparedCapture({
    ...message,
    captureMode,
    capture: prepared.capture
  });
}

async function captureTabsBatch(message) {
  const tabIDs = Array.from(new Set(message.tabIDs || []))
    .filter(Number.isInteger)
    .slice(0, 10);
  if (!message.token || tabIDs.length < 2) {
    throw new Error("请先选择至少两个可保存的网页标签页。");
  }
  const captureMode = normalizedCaptureMode(message.captureMode);
  if (captureMode === "selection") {
    throw new Error("批量保存不支持“选中文字”模式，请选择净化正文、完整网页或仅链接。");
  }
  const receipts = [];
  const errors = [];
  let conflictCount = 0;
  let queuedDuringBatch = 0;
  for (const tabId of tabIDs) {
    try {
      const result = await captureAndSave({
        tabId,
        token: message.token,
        folderID: message.folderID || null,
        newFolderName: message.newFolderName || null,
        captureMode,
        allowsAIUse: message.allowsAIUse !== false
      });
      if (result.requiresDuplicateResolution) conflictCount += 1;
      else if (result.queued) queuedDuringBatch += 1;
      else if (result.documentID) receipts.push(result);
    } catch (error) {
      errors.push({ tabId, message: readableError(error) });
    }
  }
  const summary = queueSummary(await readCaptureQueue());
  if (receipts.length) {
    await extensionAPI.storage.local.set({
      lastKnowledgeSaveReceiptV1: receipts[receipts.length - 1]
    });
  }
  return {
    requestedCount: tabIDs.length,
    savedCount: receipts.length,
    importedCount: receipts.length,
    queuedDuringBatch,
    conflictCount,
    failedCount: errors.length,
    errors,
    receipts,
    ...summary
  };
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
      ? "当前页面没有选中文字；请先选择内容再生成预览。"
      : "没有从当前页面提取到可保存的内容。");
  }
  const capture = captureFromPage(page, captureMode);
  const textBytes = new TextEncoder().encode(JSON.stringify(capture)).length;
  const estimatedArchiveBytes = captureMode === "full-page"
    ? Math.min(MAX_ARCHIVE_BYTES, Math.max(0, Number(page.estimatedArchiveBytes || 0)))
    : 0;
  return {
    captureMode,
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

  let archiveData = null;
  let archiveFormat = null;
  let archiveReport = null;
  const supportsMHTML = Boolean(extensionAPI.pageCapture?.saveAsMHTML);
  if (captureMode === "full-page" && supportsMHTML) {
    const archive = await saveAsMHTML(message.tabId).catch(() => null);
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

  const envelope = {
    capture: finalizedCapture,
    folderID: message.folderID || null,
    newFolderName: message.newFolderName || null
  };
  try {
    const payload = await submitCaptureEnvelope(envelope, message.token);
    if (payload.requiresDuplicateResolution) {
      const queued = await enqueueDuplicateConflict(envelope, payload.conflict, archiveReport);
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
    const queue = await enqueueCapture(envelope, archiveReport, error);
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
  if (!CAPTURE_MODES.has(mode)) throw new Error("采集模式无效，请重新生成预览。");
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
    throw new Error("保存预览已失效，请重新生成。");
  }
  let sourceURL;
  try {
    sourceURL = new URL(String(value.sourceURL || ""));
  } catch {
    throw new Error("页面地址无效，请重新生成预览。");
  }
  if (!["http:", "https:"].includes(sourceURL.protocol)
      || sourceURL.username || sourceURL.password) {
    throw new Error("页面地址无效，请重新生成预览。");
  }
  sourceURL.hash = "";
  const title = String(value.title || "").trim().slice(0, 300);
  const contentText = String(value.contentText || "").trim();
  if (!title) throw new Error("标题不能为空。");
  if (!contentText) throw new Error("保存内容为空，请重新生成预览。");
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
    : `${value.slice(0, maximumCharacters)}\n\n……预览已截断，保存时会保留完整正文。`;
}

async function submitCaptureEnvelope(envelope, token) {
  const response = await performBridgeRequest("/v1/import", "POST", token, envelope);
  if (!response.ok) {
    await handleBridgeAuthenticationFailure(response.status, response.payload);
    const retryable = response.status === 0
      || response.status === 408
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
  if (!token) {
    return {
      ok: false,
      status: 401,
      payload: { error: "缺少连接令牌，请重新配对。", code: "invalid-token" },
      transport: "none"
    };
  }
  if (supportsNativeMessaging()) {
    try {
      const response = await sendNativeHostMessage({
        schemaVersion: NATIVE_MESSAGE_SCHEMA_VERSION,
        path,
        method,
        token,
        bodyJSON: body == null ? null : JSON.stringify(body)
      });
      if (!response || response.schemaVersion !== NATIVE_MESSAGE_SCHEMA_VERSION
          || typeof response.status !== "number" || typeof response.payload !== "object") {
        throw new Error("原生宿主返回了无效响应。");
      }
      return {
        ok: Boolean(response.ok),
        status: response.status,
        payload: response.payload || {},
        transport: "native"
      };
    } catch (nativeError) {
      return {
        ok: false,
        status: 0,
        payload: {
          error: "无法连接浏览器原生宿主。请在应用的浏览器资料采集窗口安装或修复对应浏览器的原生连接。",
          code: "native-host-unavailable",
          detail: readableError(nativeError)
        },
        transport: "native"
      };
    }
  }
  return {
    ok: false,
    status: 0,
    payload: {
      error: "当前浏览器不支持原生连接，请升级浏览器后重试。",
      code: "native-messaging-unsupported"
    },
    transport: "none"
  };
}

function supportsNativeMessaging() {
  return typeof extensionAPI.runtime?.sendNativeMessage === "function";
}

function sendNativeHostMessage(message) {
  if (typeof globalThis.browser !== "undefined") {
    return extensionAPI.runtime.sendNativeMessage(NATIVE_HOST_NAME, message);
  }
  return new Promise((resolve, reject) => {
    extensionAPI.runtime.sendNativeMessage(NATIVE_HOST_NAME, message, (response) => {
      const lastError = extensionAPI.runtime.lastError;
      if (lastError) {
        reject(new Error(lastError.message || "原生宿主连接失败。"));
      } else {
        resolve(response);
      }
    });
  });
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

function withQueueLock(operation) {
  const result = queueOperation.then(operation, operation);
  queueOperation = result.catch(() => {});
  return result;
}

async function readCaptureQueue() {
  const stored = await extensionAPI.storage.local.get([CAPTURE_QUEUE_KEY]);
  const queue = stored?.[CAPTURE_QUEUE_KEY];
  if (!Array.isArray(queue)) return [];
  return queue.filter((entry) =>
    entry
    && entry.schemaVersion === 1
    && entry.envelope?.capture?.sourceURL
    && entry.envelope?.capture?.contentText
  );
}

async function writeCaptureQueue(queue) {
  await extensionAPI.storage.local.set({ [CAPTURE_QUEUE_KEY]: queue });
  await updateCaptureQueueAlarm(queue.some((entry) => !entry.blocked));
  if (queue.length) {
    const summary = queueSummary(queue);
    await setQueueToolbarState(summary.queuedCount, summary.blockedCount);
  }
}

function queueSummary(queue) {
  return {
    queuedCount: queue.length,
    blockedCount: queue.filter((entry) => entry.blocked).length,
    totalBytes: new TextEncoder().encode(JSON.stringify(queue)).length,
    oldestCapturedAt: queue[0]?.createdAt || null,
    duplicateConflicts: queue
      .filter((entry) => entry.duplicateConflict)
      .map((entry) => ({
        queueID: entry.id,
        conflict: entry.duplicateConflict,
        targetFolderID: entry.envelope.folderID || null,
        targetNewFolderName: entry.envelope.newFolderName || null
      }))
  };
}

function captureDestinationKey(envelope) {
  return JSON.stringify([
    envelope.capture.sourceURL,
    envelope.folderID || null,
    envelope.newFolderName || null
  ]);
}

function queueRetryDelay(attempts) {
  return Math.min(60 * 60 * 1_000, 30 * 1_000 * (2 ** Math.min(attempts, 7)));
}

async function enqueueCapture(envelope, archiveReport, originalError) {
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    const now = new Date().toISOString();
    const destinationKey = captureDestinationKey(envelope);
    const existingIndex = queue.findIndex((entry) =>
      captureDestinationKey(entry.envelope) === destinationKey
    );
    const existing = existingIndex >= 0 ? queue[existingIndex] : null;
    const entry = {
      schemaVersion: 1,
      id: existing?.id || globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      attempts: 1,
      nextAttemptAt: new Date(Date.now() + queueRetryDelay(1)).toISOString(),
      blocked: false,
      lastError: readableError(originalError),
      envelope,
      archiveReport: archiveReport || null
    };
    if (existingIndex >= 0) {
      queue.splice(existingIndex, 1, entry);
    } else {
      queue.push(entry);
    }
    queue.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
    const summary = queueSummary(queue);
    if (summary.queuedCount > MAX_QUEUE_ITEMS || summary.totalBytes > MAX_QUEUE_BYTES) {
      throw new Error("待保存队列已满，请先打开应用完成重试，或在插件中清理队列。");
    }
    try {
      await writeCaptureQueue(queue);
    } catch {
      throw new Error("浏览器无法写入待保存队列，请打开应用后重试。");
    }
    return summary;
  });
}

async function enqueueDuplicateConflict(envelope, conflict, archiveReport) {
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    const now = new Date().toISOString();
    const destinationKey = captureDestinationKey(envelope);
    const existingIndex = queue.findIndex((entry) =>
      captureDestinationKey(entry.envelope) === destinationKey
    );
    const existing = existingIndex >= 0 ? queue[existingIndex] : null;
    const entry = {
      schemaVersion: 1,
      id: existing?.id || globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      attempts: Number(existing?.attempts || 0),
      nextAttemptAt: null,
      blocked: true,
      lastError: "检测到同网址资料，需要选择处理方式。",
      envelope,
      archiveReport: archiveReport || null,
      duplicateConflict: conflict
    };
    if (existingIndex >= 0) {
      queue.splice(existingIndex, 1, entry);
    } else {
      queue.push(entry);
    }
    queue.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
    const summary = queueSummary(queue);
    if (summary.queuedCount > MAX_QUEUE_ITEMS || summary.totalBytes > MAX_QUEUE_BYTES) {
      throw new Error("待保存队列已满，无法保留重复网页的处理选择。");
    }
    await writeCaptureQueue(queue);
    return { queueID: entry.id, ...summary };
  });
}

async function flushCaptureQueue(explicitToken = null, force = false) {
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    if (!queue.length) return { importedCount: 0, receipts: [], ...queueSummary(queue) };
    const stored = explicitToken
      ? null
      : await extensionAPI.storage.local.get(["bridgeToken"]);
    const token = explicitToken || stored?.bridgeToken;
    if (!token) return { importedCount: 0, receipts: [], ...queueSummary(queue) };

    const remaining = [];
    let importedCount = 0;
    const receipts = [];
    for (let index = 0; index < queue.length; index += 1) {
      const entry = queue[index];
      if ((!force && entry.blocked)
          || (!force && Date.parse(entry.nextAttemptAt || "") > Date.now())) {
        remaining.push(entry);
        continue;
      }
      try {
        const receipt = await submitCaptureEnvelope(entry.envelope, token);
        if (receipt.requiresDuplicateResolution) {
          remaining.push({
            ...entry,
            blocked: true,
            nextAttemptAt: null,
            updatedAt: new Date().toISOString(),
            lastError: "检测到同网址资料，需要选择处理方式。",
            duplicateConflict: receipt.conflict
          });
          continue;
        }
        receipts.push(receipt);
        importedCount += 1;
      } catch (error) {
        const attempts = Number(entry.attempts || 0) + 1;
        const updated = {
          ...entry,
          attempts,
          updatedAt: new Date().toISOString(),
          nextAttemptAt: error.retryable
            ? new Date(Date.now() + queueRetryDelay(attempts)).toISOString()
            : null,
          blocked: !error.retryable,
          lastError: readableError(error)
        };
        remaining.push(updated);
        if (error.retryable || error.status === 401 || error.status === 403) {
          remaining.push(...queue.slice(index + 1));
          break;
        }
      }
    }
    await writeCaptureQueue(remaining);
    return { importedCount, receipts, ...queueSummary(remaining) };
  });
}

async function resolveDuplicateCapture(queueID, resolution, token) {
  if (!queueID || !["save-new-version", "move-only", "keep-copy"].includes(resolution)) {
    throw new Error("重复网页处理方式无效。");
  }
  if (!token) throw new Error("请先重新连接应用。");
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    const index = queue.findIndex((entry) => entry.id === queueID && entry.duplicateConflict);
    if (index < 0) throw new Error("该重复网页处理请求已不存在。");
    const entry = queue[index];
    const receipt = await submitCaptureEnvelope({
      ...entry.envelope,
      duplicateResolution: resolution
    }, token);
    if (receipt.requiresDuplicateResolution) {
      throw new Error("资料库仍需要确认重复网页的处理方式。");
    }
    queue.splice(index, 1);
    await writeCaptureQueue(queue);
    return { receipt, ...queueSummary(queue) };
  });
}

async function cancelDuplicateCapture(queueID) {
  if (!queueID) throw new Error("重复网页处理请求无效。");
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    const remaining = queue.filter((entry) => entry.id !== queueID);
    await writeCaptureQueue(remaining);
    return queueSummary(remaining);
  });
}

async function discardCaptureQueue() {
  return withQueueLock(async () => {
    await writeCaptureQueue([]);
    await setToolbarState("connected");
    return { importedCount: 0, ...queueSummary([]) };
  });
}

async function updateCaptureQueueAlarm(hasRetryableEntries) {
  if (!extensionAPI.alarms) return;
  if (hasRetryableEntries) {
    await extensionAPI.alarms.create(CAPTURE_QUEUE_ALARM, { periodInMinutes: 1 });
  } else {
    await extensionAPI.alarms.clear(CAPTURE_QUEUE_ALARM);
  }
}

async function scheduleCaptureQueueRetry() {
  const queue = await readCaptureQueue();
  await updateCaptureQueueAlarm(queue.some((entry) => !entry.blocked));
  if (queue.length) {
    const summary = queueSummary(queue);
    await setQueueToolbarState(summary.queuedCount, summary.blockedCount);
  } else {
    const stored = await extensionAPI.storage.local.get(["bridgeToken"]);
    await setToolbarState(stored.bridgeToken ? "connected" : "disconnected");
  }
  if (queue.length) await flushCaptureQueue(null, false);
}

async function extractPage(maxHTMLBytes, maxTextBytes, makeSelfContainedArchive, captureMode) {
  const readMeta = (...selectors) => {
    for (const selector of selectors) {
      const value = document.querySelector(selector)?.content?.trim();
      if (value) return value;
    }
    return null;
  };
  const splitList = (value) => (value || "")
    .split(/[,，;；]/)
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, 30);
  const normalize = (value) => (value || "")
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  const truncateUTF8 = (value, maximumBytes) => {
    const encoder = new TextEncoder();
    if (encoder.encode(value).length <= maximumBytes) return value;
    let lower = 0;
    let upper = value.length;
    while (lower < upper) {
      const middle = Math.ceil((lower + upper) / 2);
      if (encoder.encode(value.slice(0, middle)).length <= maximumBytes) {
        lower = middle;
      } else {
        upper = middle - 1;
      }
    }
    const truncated = value.slice(0, lower);
    const lastCodeUnit = truncated.charCodeAt(truncated.length - 1);
    return lastCodeUnit >= 0xD800 && lastCodeUnit <= 0xDBFF
      ? truncated.slice(0, -1)
      : truncated;
  };
  const safeLinkDestination = (rawValue) => {
    if (!rawValue) return null;
    try {
      const url = new URL(rawValue, document.baseURI);
      const scheme = url.protocol.toLowerCase();
      if (!["http:", "https:", "mailto:"].includes(scheme)) return null;
      if (["http:", "https:"].includes(scheme) && (url.username || url.password)) {
        return null;
      }
      return url.href
        .replace(/\(/g, "%28")
        .replace(/\)/g, "%29");
    } catch {
      return null;
    }
  };
  const normalizedInline = (value) => value
    .replace(/\s+/g, " ")
    .trim();
  const escapedLinkLabel = (value) => value
    .replace(/\\/g, "\\\\")
    .replace(/\[/g, "\\[")
    .replace(/\]/g, "\\]");
  const skippedElementNames = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS",
    "FORM", "INPUT", "BUTTON", "SELECT", "TEXTAREA", "NAV", "FOOTER",
    "ASIDE", "DIALOG", "IFRAME", "OBJECT", "EMBED"
  ]);
  const noiseTokenPattern = /(^|[-_\s])(nav|menu|sidebar|footer|advert(?:isement)?|ads?|promo|cookie|consent|share|social|related|recommend(?:ed|ation)?|comment|popup|modal|newsletter|subscribe|paywall|breadcrumb|toolbar)([-_\s]|$)/i;
  const isNoiseElement = (element) => {
    if (skippedElementNames.has(element.tagName) || element.hidden) return true;
    if ((element.getAttribute("aria-hidden") || "").toLowerCase() === "true") return true;
    const role = (element.getAttribute("role") || "").toLowerCase();
    if (["navigation", "complementary", "dialog"].includes(role)) return true;
    const identity = `${element.id || ""} ${element.className || ""}`;
    return noiseTokenPattern.test(identity);
  };
  const blockElementNames = new Set([
    "ADDRESS", "ARTICLE", "ASIDE", "DD", "DETAILS", "DIV", "DL", "DT",
    "FIGCAPTION", "FIGURE", "FOOTER", "HEADER", "MAIN", "NAV", "SECTION",
    "SUMMARY", "TABLE", "TBODY", "TFOOT", "THEAD", "TR"
  ]);
  const renderChildren = (element, listDepth = 0) => Array.from(element.childNodes)
    .map((node) => renderNode(node, listDepth))
    .join("");
  const renderList = (list, listDepth) => {
    const ordered = list.tagName === "OL";
    const items = Array.from(list.children).filter((child) => child.tagName === "LI");
    const lines = items.map((item, index) => {
      const nestedLists = Array.from(item.children).filter((child) =>
        child.tagName === "UL" || child.tagName === "OL"
      );
      const body = normalizedInline(Array.from(item.childNodes)
        .filter((node) => !(node.nodeType === Node.ELEMENT_NODE
          && (node.tagName === "UL" || node.tagName === "OL")))
        .map((node) => renderNode(node, listDepth + 1))
        .join(""));
      const marker = ordered ? `${index + 1}. ` : "- ";
      const prefix = "  ".repeat(listDepth) + marker;
      const nested = nestedLists
        .map((nestedList) => renderList(nestedList, listDepth + 1).trimEnd())
        .filter(Boolean)
        .join("\n");
      return prefix + body + (nested ? `\n${nested}` : "");
    });
    return lines.length ? `${lines.join("\n")}\n\n` : "";
  };
  const renderNode = (node, listDepth = 0) => {
    if (node.nodeType === Node.TEXT_NODE) {
      return (node.nodeValue || "").replace(/\s+/g, " ");
    }
    if (node.nodeType !== Node.ELEMENT_NODE || isNoiseElement(node)) {
      return "";
    }

    const tagName = node.tagName;
    if (tagName === "BR") return "\n";
    if (tagName === "HR") return "\n\n---\n\n";
    if (tagName === "UL" || tagName === "OL") return renderList(node, listDepth);
    if (tagName === "LI") return renderChildren(node, listDepth);
    if (/^H[1-6]$/.test(tagName)) {
      const level = Number(tagName.slice(1));
      const heading = normalizedInline(renderChildren(node, listDepth));
      return heading ? `${"#".repeat(level)} ${heading}\n\n` : "";
    }
    if (tagName === "P") {
      const paragraph = normalizedInline(renderChildren(node, listDepth));
      return paragraph ? `${paragraph}\n\n` : "";
    }
    if (tagName === "A") {
      const label = normalizedInline(renderChildren(node, listDepth));
      const destination = safeLinkDestination(node.getAttribute("href"));
      if (!destination) return label;
      return `[${escapedLinkLabel(label || destination)}](${destination})`;
    }
    if (tagName === "IMG") {
      const alt = normalizedInline(node.getAttribute("alt") || "");
      const destination = safeLinkDestination(node.getAttribute("src"));
      if (!destination) return alt;
      return `![${escapedLinkLabel(alt)}](${destination})`;
    }
    if (tagName === "STRONG" || tagName === "B") {
      const text = normalizedInline(renderChildren(node, listDepth));
      return text ? `**${text}**` : "";
    }
    if (tagName === "EM" || tagName === "I") {
      const text = normalizedInline(renderChildren(node, listDepth));
      return text ? `*${text}*` : "";
    }
    if (tagName === "CODE" && node.parentElement?.tagName !== "PRE") {
      const text = normalizedInline(node.textContent || "");
      if (!text) return "";
      return text.includes("`") ? `\`\`${text}\`\`` : `\`${text}\``;
    }
    if (tagName === "PRE") {
      const text = (node.textContent || "").replace(/\n+$/, "");
      return text ? `\n\n\`\`\`\n${text}\n\`\`\`\n\n` : "";
    }
    if (tagName === "BLOCKQUOTE") {
      const text = normalize(renderChildren(node, listDepth));
      return text
        ? `${text.split("\n").map((line) => `> ${line}`).join("\n")}\n\n`
        : "";
    }

    const content = renderChildren(node, listDepth);
    if (tagName === "TD" || tagName === "TH") return `${normalizedInline(content)} | `;
    return blockElementNames.has(tagName) ? `${content}\n\n` : content;
  };

  const source = document.querySelector("article")
    || document.querySelector("main")
    || document.querySelector("[role='main']")
    || document.body;
  const contentMarkdown = normalize(renderNode(source));
  const cleanedContentText = truncateUTF8(
    contentMarkdown || normalize(source?.innerText || document.body?.innerText || ""),
    maxTextBytes
  );

  const canonical = document.querySelector("link[rel='canonical']")?.href;
  const sourceURL = canonical && /^https?:/i.test(canonical) ? canonical : location.href;
  const pageTitle = readMeta("meta[property='og:title']", "meta[name='twitter:title']")
    || document.title
    || new URL(sourceURL).hostname;
  const selectedText = truncateUTF8(
    normalize(globalThis.getSelection?.().toString() || ""),
    maxTextBytes
  );
  const linkText = `[${escapedLinkLabel(pageTitle)}](${safeLinkDestination(sourceURL) || sourceURL})`;
  const contentText = captureMode === "selection"
    ? selectedText
    : captureMode === "link-only"
      ? linkText
      : cleanedContentText;
  const clone = document.documentElement.cloneNode(true);
  clone.querySelectorAll("script,noscript,template,iframe,object,embed").forEach((node) => node.remove());
  clone.querySelectorAll("input,textarea,select").forEach((control) => {
    if (control.tagName === "INPUT") {
      const type = (control.getAttribute("type") || "text").toLowerCase();
      if (type === "hidden") {
        control.remove();
        return;
      }
      control.removeAttribute("value");
      if (["checkbox", "radio"].includes(type)) control.removeAttribute("checked");
    } else if (control.tagName === "TEXTAREA") {
      control.textContent = "";
    } else {
      Array.from(control.options || []).forEach((option) => option.removeAttribute("selected"));
    }
    control.setAttribute("disabled", "");
  });
  clone.querySelectorAll("*").forEach((element) => {
    Array.from(element.attributes).forEach((attribute) => {
      if (/^on/i.test(attribute.name)) element.removeAttribute(attribute.name);
      if (["href", "src", "action", "formaction"].includes(attribute.name.toLowerCase())
          && /^\s*javascript:/i.test(attribute.value)) {
        element.removeAttribute(attribute.name);
      }
    });
  });
  clone.querySelectorAll("base").forEach((base) => base.remove());
  const base = document.createElement("base");
  base.setAttribute("href", document.baseURI);
  (clone.querySelector("head") || clone).prepend(base);

  const basicSerialized = "<!doctype html>\n" + clone.outerHTML;
  const estimatedArchiveBytes = new TextEncoder().encode(basicSerialized).length;
  const archiveReport = {
    format: "html",
    embeddedResourceCount: 0,
    missingResourceCount: 0,
    wasTruncated: false
  };
  let serialized = basicSerialized;
  let archiveKnownResourceCount = 0;

  if (makeSelfContainedArchive) {
    const encoder = new TextEncoder();
    const resourceCache = new Map();
    const stylesheetCache = new Map();
    const embeddedURLs = new Set();
    const missingURLs = new Set();
    const archiveDeadline = Date.now() + 15_000;
    const maximumSingleResourceBytes = 5 * 1_024 * 1_024;
    let remainingBudget = Math.max(maxHTMLBytes - encoder.encode(basicSerialized).length - 64 * 1_024, 0);
    let reachedBudget = remainingBudget === 0;

    const resolvedResourceURL = (rawValue, baseURL = document.baseURI) => {
      if (!rawValue || /^\s*(data:|blob:|#)/i.test(rawValue)) return rawValue || null;
      try {
        const url = new URL(rawValue, baseURL);
        if (!["http:", "https:"].includes(url.protocol.toLowerCase())) return null;
        if (url.username || url.password) return null;
        url.hash = "";
        return url.href;
      } catch {
        return null;
      }
    };
    const markMissing = (url) => {
      if (url && /^https?:/i.test(url)) missingURLs.add(url);
    };
    const responseTimeout = () => Math.max(250, Math.min(4_000, archiveDeadline - Date.now()));
    const fetchWithDeadline = async (url) => {
      if (Date.now() >= archiveDeadline) throw new Error("archive deadline reached");
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), responseTimeout());
      try {
        const target = new URL(url);
        const sameOrigin = target.origin === location.origin;
        return await fetch(url, {
          cache: "force-cache",
          credentials: sameOrigin ? "include" : "omit",
          signal: controller.signal
        });
      } finally {
        clearTimeout(timeout);
      }
    };
    const blobAsDataURL = (blob) => new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(reader.error || new Error("resource read failed"));
      reader.onload = () => resolve(String(reader.result || ""));
      reader.readAsDataURL(blob);
    });
    const resourceDataURL = async (rawValue, baseURL = document.baseURI) => {
      if (/^\s*data:/i.test(rawValue || "")) return rawValue;
      const url = resolvedResourceURL(rawValue, baseURL);
      if (!url) return null;
      if (resourceCache.has(url)) return resourceCache.get(url);
      const task = (async () => {
        try {
          const response = await fetchWithDeadline(url);
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const blob = await response.blob();
          if (blob.size > maximumSingleResourceBytes) throw new Error("resource too large");
          const dataURL = await blobAsDataURL(blob);
          const cost = encoder.encode(dataURL).length;
          if (cost > remainingBudget) {
            reachedBudget = true;
            throw new Error("archive budget reached");
          }
          remainingBudget -= cost;
          embeddedURLs.add(url);
          return dataURL;
        } catch {
          markMissing(url);
          return null;
        }
      })();
      resourceCache.set(url, task);
      return task;
    };
    const stylesheetText = async (rawValue, baseURL = document.baseURI) => {
      const url = resolvedResourceURL(rawValue, baseURL);
      if (!url) return null;
      if (stylesheetCache.has(url)) return stylesheetCache.get(url);
      const task = (async () => {
        try {
          const response = await fetchWithDeadline(url);
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const css = await response.text();
          const cost = encoder.encode(css).length;
          if (cost > Math.min(1 * 1_024 * 1_024, remainingBudget)) {
            reachedBudget = true;
            throw new Error("stylesheet too large");
          }
          remainingBudget -= cost;
          embeddedURLs.add(url);
          return { css, url };
        } catch {
          markMissing(url);
          return null;
        }
      })();
      stylesheetCache.set(url, task);
      return task;
    };
    const inlineCSSResources = async (css, baseURL) => {
      const pattern = /url\(\s*(["']?)([^"')]+)\1\s*\)/gi;
      const matches = Array.from(css.matchAll(pattern));
      if (!matches.length) return css;
      let output = "";
      let cursor = 0;
      for (const match of matches) {
        output += css.slice(cursor, match.index);
        const rawURL = match[2].trim();
        const dataURL = await resourceDataURL(rawURL, baseURL);
        output += dataURL ? `url("${dataURL}")` : match[0];
        cursor = match.index + match[0].length;
      }
      return output + css.slice(cursor);
    };

    const originalImages = Array.from(document.querySelectorAll("img"));
    const clonedImages = Array.from(clone.querySelectorAll("img"));
    for (let index = 0; index < clonedImages.length; index += 1) {
      const original = originalImages[index];
      const target = clonedImages[index];
      const rawURL = original?.currentSrc || original?.getAttribute("src") || target.getAttribute("src");
      const dataURL = await resourceDataURL(rawURL);
      const absoluteURL = resolvedResourceURL(rawURL);
      if (dataURL) target.setAttribute("src", dataURL);
      else if (absoluteURL) target.setAttribute("src", absoluteURL);
      target.removeAttribute("srcset");
      target.removeAttribute("sizes");
      target.removeAttribute("loading");
      target.removeAttribute("crossorigin");
    }
    clone.querySelectorAll("picture source[srcset]").forEach((source) => source.removeAttribute("srcset"));

    for (const style of Array.from(clone.querySelectorAll("style"))) {
      style.textContent = await inlineCSSResources(style.textContent || "", document.baseURI);
    }
    for (const element of Array.from(clone.querySelectorAll("[style]"))) {
      element.setAttribute(
        "style",
        await inlineCSSResources(element.getAttribute("style") || "", document.baseURI)
      );
    }
    for (const link of Array.from(clone.querySelectorAll("link[rel~='stylesheet'][href]"))) {
      const fetched = await stylesheetText(link.getAttribute("href"));
      if (!fetched) {
        const absoluteURL = resolvedResourceURL(link.getAttribute("href"));
        if (absoluteURL) link.setAttribute("href", absoluteURL);
        continue;
      }
      const style = document.createElement("style");
      style.setAttribute("data-knowledge-archive-source", fetched.url);
      style.textContent = await inlineCSSResources(fetched.css, fetched.url);
      link.replaceWith(style);
    }
    for (const icon of Array.from(clone.querySelectorAll("link[rel~='icon'][href]"))) {
      const dataURL = await resourceDataURL(icon.getAttribute("href"));
      const absoluteURL = resolvedResourceURL(icon.getAttribute("href"));
      if (dataURL) icon.setAttribute("href", dataURL);
      else if (absoluteURL) icon.setAttribute("href", absoluteURL);
    }
    clone.querySelectorAll("a[href]").forEach((anchor) => {
      const absoluteURL = resolvedResourceURL(anchor.getAttribute("href"));
      if (absoluteURL) anchor.setAttribute("href", absoluteURL);
    });
    clone.querySelectorAll("video[src],audio[src],video[poster],source[src]").forEach((media) => {
      for (const attribute of ["src", "poster"]) {
        const rawURL = media.getAttribute(attribute);
        const absoluteURL = resolvedResourceURL(rawURL);
        if (absoluteURL) {
          media.setAttribute(attribute, absoluteURL);
          markMissing(absoluteURL);
        }
      }
    });

    archiveReport.embeddedResourceCount = embeddedURLs.size;
    archiveReport.missingResourceCount = missingURLs.size;
    archiveReport.wasTruncated = reachedBudget || Date.now() >= archiveDeadline;
    archiveKnownResourceCount = new Set([...embeddedURLs, ...missingURLs]).size;
    const reportMeta = document.createElement("meta");
    reportMeta.setAttribute("name", "knowledge-archive-report");
    reportMeta.setAttribute(
      "content",
      `embedded=${archiveReport.embeddedResourceCount}; missing=${archiveReport.missingResourceCount}; truncated=${archiveReport.wasTruncated}`
    );
    (clone.querySelector("head") || clone).prepend(reportMeta);
    serialized = "<!doctype html>\n" + clone.outerHTML;
  }

  if (new TextEncoder().encode(serialized).length > maxHTMLBytes) {
    archiveReport.wasTruncated = true;
    archiveReport.embeddedResourceCount = 0;
    archiveReport.missingResourceCount = Math.max(
      archiveReport.missingResourceCount,
      archiveKnownResourceCount
    );
    serialized = basicSerialized;
  }
  if (new TextEncoder().encode(serialized).length > maxHTMLBytes) {
    const escapeHTML = (value) => value
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
    serialized = `<!doctype html><html lang="${escapeHTML(document.documentElement.lang || "")}"><head><meta charset="utf-8"><title>${escapeHTML(document.title || sourceURL)}</title></head><body><main><h1>${escapeHTML(document.title || sourceURL)}</h1><p><a href="${escapeHTML(sourceURL)}">${escapeHTML(sourceURL)}</a></p><pre>${escapeHTML(contentText)}</pre></main></body></html>`;
  }

  const authors = splitList(readMeta(
    "meta[name='author']",
    "meta[property='article:author']",
    "meta[name='byl']"
  ));
  const tags = splitList(readMeta(
    "meta[name='keywords']",
    "meta[property='article:tag']"
  ));

  return {
    sourceURL,
    title: pageTitle,
    authors,
    language: document.documentElement.lang || null,
    summary: readMeta(
      "meta[name='description']",
      "meta[property='og:description']",
      "meta[name='twitter:description']"
    ),
    tags,
    contentText,
    originalHTML: serialized,
    archiveReport: makeSelfContainedArchive ? archiveReport : null,
    estimatedArchiveBytes
  };
}

function saveAsMHTML(tabId) {
  return new Promise((resolve, reject) => {
    extensionAPI.pageCapture.saveAsMHTML({ tabId }, (blob) => {
      const runtimeError = extensionAPI.runtime.lastError;
      if (runtimeError) {
        reject(new Error(runtimeError.message));
      } else if (!blob) {
        reject(new Error("浏览器没有返回 MHTML 归档。"));
      } else {
        resolve(blob);
      }
    });
  });
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error("读取页面归档失败。"));
    reader.onload = () => {
      const result = String(reader.result || "");
      resolve(result.slice(result.indexOf(",") + 1));
    };
    reader.readAsDataURL(blob);
  });
}

function readableError(error) {
  if (String(error?.message || error).includes("Failed to fetch")) {
    return "无法连接应用。请打开“个人网站发布控制台”，并确认连接令牌有效。";
  }
  return error?.message || String(error);
}
