const CAPTURE_QUEUE_KEY = "pendingKnowledgeCapturesV1";
const CAPTURE_QUEUE_ALARM = "retry-pending-knowledge-captures";
const CAPTURE_QUEUE_RETENTION_KEY = "knowledgeCaptureQueueRetentionDaysV1";
const CAPTURE_QUEUE_PRIVACY_KEY = "knowledgeCaptureQueuePrivacyV1";
const CAPTURE_QUEUE_STORE_SCHEMA_VERSION = 2;
const CAPTURE_QUEUE_ITEM_SCHEMA_VERSION = 2;
const CAPTURE_QUEUE_DEFAULT_RETENTION_DAYS = 30;
const CAPTURE_QUEUE_RETENTION_OPTIONS = new Set([7, 30, 90, 365]);
const CAPTURE_QUEUE_PRIVACY_MODES = new Set(["disabled", "links-only", "full-content"]);
const CAPTURE_QUEUE_DEFAULT_PRIVACY_MODE = "links-only";
const MAX_QUEUE_ITEMS = 10;
const MAX_QUEUE_BYTES = 96 * 1024 * 1024;
let queueOperation = Promise.resolve();
function withQueueLock(operation) {
  const result = queueOperation.then(operation, operation);
  queueOperation = result.catch(() => {});
  return result;
}

function emptyCaptureQueueStore() {
  return {
    schemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
    updatedAt: new Date().toISOString(),
    entries: [],
    quarantine: []
  };
}

function normalizedQueueRetentionDays(value) {
  const days = Number(value);
  return CAPTURE_QUEUE_RETENTION_OPTIONS.has(days)
    ? days
    : CAPTURE_QUEUE_DEFAULT_RETENTION_DAYS;
}

function normalizedQueuePrivacySettings(value, legacyStoreHasContent = false) {
  const storedMode = String(value?.mode || "");
  const mode = CAPTURE_QUEUE_PRIVACY_MODES.has(storedMode)
    ? storedMode
    : legacyStoreHasContent
      ? "full-content"
      : CAPTURE_QUEUE_DEFAULT_PRIVACY_MODE;
  return {
    mode,
    allowPrivateSites: value?.allowPrivateSites === true
  };
}

function isPrivateQueueSourceURL(value) {
  try {
    return isBlockedArchiveHostname(new URL(String(value || "")).hostname);
  } catch {
    return true;
  }
}

function minimizedQueueCapture(capture) {
  const sourceURL = normalizedPageIdentityURL(capture?.sourceURL);
  if (!sourceURL) throw new Error("无法为离线队列保留有效链接。");
  return {
    schemaVersion: 1,
    sourceURL,
    title: String(capture?.title || sourceURL).trim().slice(0, 300),
    authors: [],
    language: null,
    summary: "",
    tags: [],
    capturedAt: normalizedQueueDate(capture?.capturedAt),
    contentText: sourceURL,
    originalHTML: null,
    archiveFormat: null,
    archiveData: null,
    archiveEmbeddedResourceCount: null,
    archiveMissingResourceCount: null,
    archiveWasTruncated: null,
    captureMode: "link-only",
    allowsLocalSemanticIndex: capture?.allowsLocalSemanticIndex === undefined
      ? capture?.allowsAIUse !== false
      : capture.allowsLocalSemanticIndex !== false,
    allowsRemoteAIUse: capture?.allowsRemoteAIUse === true
  };
}

function minimizedQueueEntry(entry) {
  return {
    ...entry,
    envelope: {
      ...entry.envelope,
      capture: minimizedQueueCapture(entry.envelope?.capture)
    },
    archiveReport: null,
    storedContentMode: "links-only"
  };
}

function queueEntryIsPrivate(entry) {
  return Boolean(entry?.privacyContext?.isIncognito)
    || Boolean(entry?.privacyContext?.isPrivateNetwork)
    || isPrivateQueueSourceURL(entry?.envelope?.capture?.sourceURL);
}

function queuePrivacyError(message, code) {
  const error = new Error(message);
  error.code = code;
  error.retryable = false;
  return error;
}

async function captureQueuePrivacyContext(tabID, envelope) {
  let isIncognito = false;
  if (Number.isInteger(tabID) && typeof extensionAPI.tabs?.get === "function") {
    try {
      const tab = await extensionAPI.tabs.get(tabID);
      isIncognito = Boolean(tab?.incognito);
    } catch {
      // A missing tabs grant must not weaken private-network URL checks.
    }
  }
  return {
    isIncognito,
    isPrivateNetwork: isPrivateQueueSourceURL(envelope?.capture?.sourceURL)
  };
}

function protectedQueuePayload(envelope, archiveReport, privacySettings, privacyContext) {
  if (privacySettings.mode === "disabled") {
    throw queuePrivacyError(
      "应用当前未连接，且离线队列已禁用；本次内容未写入浏览器存储。",
      "capture-queue-disabled"
    );
  }
  if (!privacySettings.allowPrivateSites
      && (privacyContext?.isIncognito || privacyContext?.isPrivateNetwork)) {
    throw queuePrivacyError(
      "无痕窗口或本地私网网页不会进入离线队列；请打开应用后重试。",
      "capture-queue-private-site-blocked"
    );
  }
  if (privacySettings.mode === "links-only") {
    return {
      envelope: {
        ...envelope,
        capture: minimizedQueueCapture(envelope?.capture)
      },
      archiveReport: null,
      storedContentMode: "links-only"
    };
  }
  return { envelope, archiveReport: archiveReport || null, storedContentMode: "full-content" };
}

function normalizedQueueDate(value, fallback = new Date().toISOString()) {
  const timestamp = Date.parse(String(value || ""));
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : fallback;
}

function queueJSONByteSize(value) {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).length;
  } catch {
    return 0;
  }
}

function redactedQueueSnapshot(value) {
  try {
    return JSON.parse(JSON.stringify(value, (key, item) =>
      /(token|secret|authorization|cookie|password|apiKey)/i.test(key)
        ? "[已移除敏感字段]"
        : item
    ));
  } catch {
    return { unavailable: true, description: "损坏数据无法序列化。" };
  }
}

function queueQuarantineRecord(value, reason, index = null) {
  const rawValue = redactedQueueSnapshot(value);
  const capture = rawValue?.envelope?.capture;
  const originalSchemaVersion = Number.isInteger(rawValue?.schemaVersion)
    ? rawValue.schemaVersion
    : null;
  return {
    id: newOperationID(),
    quarantinedAt: new Date().toISOString(),
    reason,
    originalIndex: index,
    originalSchemaVersion,
    title: String(capture?.title || "无法识别的队列项目").slice(0, 300),
    sourceURL: normalizedPageIdentityURL(capture?.sourceURL),
    byteSize: queueJSONByteSize(rawValue),
    rawValue
  };
}

function migrateCaptureQueueEntry(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("队列项目不是可识别的对象。");
  }
  if (![1, CAPTURE_QUEUE_ITEM_SCHEMA_VERSION].includes(value.schemaVersion)) {
    throw new Error(`不支持的队列项目 schema：${String(value.schemaVersion ?? "缺失")}。`);
  }
  const capture = value.envelope?.capture;
  const sourceURL = normalizedPageIdentityURL(capture?.sourceURL);
  if (!sourceURL || typeof capture?.contentText !== "string") {
    throw new Error("队列项目缺少有效的来源网址或正文。");
  }
  const now = new Date().toISOString();
  const storedContentMode = value.storedContentMode === "links-only"
    || (capture.captureMode === "link-only"
      && capture.contentText === sourceURL
      && !capture.archiveData)
    ? "links-only"
    : "full-content";
  return {
    ...value,
    schemaVersion: CAPTURE_QUEUE_ITEM_SCHEMA_VERSION,
    id: String(value.id || "").trim() || newOperationID(),
    createdAt: normalizedQueueDate(value.createdAt, now),
    updatedAt: normalizedQueueDate(value.updatedAt, now),
    attempts: Math.max(0, Number.isInteger(value.attempts) ? value.attempts : 0),
    nextAttemptAt: value.nextAttemptAt
      ? normalizedQueueDate(value.nextAttemptAt, null)
      : null,
    blocked: Boolean(value.blocked),
    lastError: String(value.lastError || "").slice(0, 1_000),
    storedContentMode,
    privacyContext: {
      isIncognito: Boolean(value.privacyContext?.isIncognito),
      isPrivateNetwork: Boolean(value.privacyContext?.isPrivateNetwork)
        || isPrivateQueueSourceURL(sourceURL)
    },
    envelope: envelopeWithOperationID({
      ...value.envelope,
      capture: { ...capture, sourceURL }
    })
  };
}

function migrateCaptureQueueStore(rawValue) {
  if (rawValue == null) {
    return { store: emptyCaptureQueueStore(), changed: false };
  }
  let candidates;
  let quarantine = [];
  let changed = false;
  if (Array.isArray(rawValue)) {
    candidates = rawValue;
    changed = true;
  } else if (typeof rawValue === "object") {
    if (rawValue.schemaVersion == null) {
      const store = emptyCaptureQueueStore();
      store.quarantine.push(queueQuarantineRecord(
        rawValue,
        "队列根记录缺少 schema，已隔离以避免丢失。"
      ));
      return { store, changed: true };
    }
    if (rawValue.schemaVersion !== CAPTURE_QUEUE_STORE_SCHEMA_VERSION) {
      const error = new Error(
        `离线队列 schema ${String(rawValue.schemaVersion)} 高于或不兼容当前版本；数据未被修改。`
      );
      error.code = "queue-schema-unsupported";
      error.schemaVersion = rawValue.schemaVersion;
      throw error;
    }
    if (Array.isArray(rawValue.entries)) {
      candidates = rawValue.entries;
    } else {
      candidates = [];
      quarantine.push(queueQuarantineRecord(
        rawValue.entries,
        "队列 entries 字段损坏，已隔离。"
      ));
      changed = true;
    }
    if (Array.isArray(rawValue.quarantine)) {
      quarantine.push(...rawValue.quarantine.map((item) => {
        const rawSnapshot = redactedQueueSnapshot(item?.rawValue);
        if (JSON.stringify(rawSnapshot) !== JSON.stringify(item?.rawValue)) changed = true;
        return {
          ...item,
          id: String(item?.id || "").trim() || newOperationID(),
          quarantinedAt: normalizedQueueDate(item?.quarantinedAt),
          reason: String(item?.reason || "已隔离的损坏项目。").slice(0, 1_000),
          byteSize: Number(item?.byteSize || queueJSONByteSize(rawSnapshot)),
          rawValue: rawSnapshot
        };
      }));
    } else if (rawValue.quarantine != null) {
      quarantine.push(queueQuarantineRecord(
        rawValue.quarantine,
        "队列 quarantine 字段损坏，已重新隔离。"
      ));
      changed = true;
    }
  } else {
    const store = emptyCaptureQueueStore();
    store.quarantine.push(queueQuarantineRecord(
      rawValue,
      "队列根记录类型损坏，已隔离以避免丢失。"
    ));
    return { store, changed: true };
  }

  const entries = [];
  for (const [index, candidate] of candidates.entries()) {
    try {
      const migrated = migrateCaptureQueueEntry(candidate);
      entries.push(migrated);
      if (candidate.schemaVersion !== CAPTURE_QUEUE_ITEM_SCHEMA_VERSION) changed = true;
    } catch (error) {
      quarantine.push(queueQuarantineRecord(candidate, readableError(error), index));
      changed = true;
    }
  }
  entries.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
  return {
    store: {
      schemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
      updatedAt: normalizedQueueDate(rawValue?.updatedAt),
      entries,
      quarantine
    },
    changed
  };
}

function pruneCaptureQueueStore(store, retentionDays, now = Date.now()) {
  const cutoff = now - retentionDays * 24 * 60 * 60 * 1_000;
  const entries = store.entries.filter((entry) => Date.parse(entry.createdAt) >= cutoff);
  const quarantine = store.quarantine.filter(
    (entry) => Date.parse(entry.quarantinedAt) >= cutoff
  );
  return {
    store: { ...store, entries, quarantine },
    purgedCount:
      store.entries.length - entries.length + store.quarantine.length - quarantine.length
  };
}

async function readCaptureQueueStore() {
  const stored = await extensionAPI.storage.local.get([
    CAPTURE_QUEUE_KEY,
    CAPTURE_QUEUE_RETENTION_KEY,
    CAPTURE_QUEUE_PRIVACY_KEY
  ]);
  const retentionDays = normalizedQueueRetentionDays(stored?.[CAPTURE_QUEUE_RETENTION_KEY]);
  let migration;
  try {
    migration = migrateCaptureQueueStore(stored?.[CAPTURE_QUEUE_KEY]);
  } catch (error) {
    error.retentionDays = retentionDays;
    throw error;
  }
  const pruning = pruneCaptureQueueStore(migration.store, retentionDays);
  const legacyStoreHasContent = pruning.store.entries.length > 0
    || pruning.store.quarantine.length > 0;
  const privacySettings = normalizedQueuePrivacySettings(
    stored?.[CAPTURE_QUEUE_PRIVACY_KEY],
    stored?.[CAPTURE_QUEUE_PRIVACY_KEY] == null && legacyStoreHasContent
  );
  const changed = migration.changed
    || pruning.purgedCount > 0
    || stored?.[CAPTURE_QUEUE_PRIVACY_KEY] == null;
  const store = {
    ...pruning.store,
    updatedAt: changed ? new Date().toISOString() : pruning.store.updatedAt
  };
  if (changed) {
    await extensionAPI.storage.local.set({
      [CAPTURE_QUEUE_KEY]: store,
      [CAPTURE_QUEUE_RETENTION_KEY]: retentionDays,
      [CAPTURE_QUEUE_PRIVACY_KEY]: privacySettings
    });
  }
  return {
    ...store,
    retentionDays,
    privacySettings,
    purgedCount: pruning.purgedCount
  };
}

async function writeCaptureQueueStore(store) {
  const privacySettings = normalizedQueuePrivacySettings(store.privacySettings);
  const persisted = {
    schemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
    updatedAt: new Date().toISOString(),
    entries: store.entries || [],
    quarantine: store.quarantine || []
  };
  await extensionAPI.storage.local.set({
    [CAPTURE_QUEUE_KEY]: persisted,
    [CAPTURE_QUEUE_PRIVACY_KEY]: privacySettings
  });
  await updateCaptureQueueAlarm(persisted.entries.some((entry) => !entry.blocked));
  if (persisted.entries.length || persisted.quarantine.length) {
    const summary = queueSummary(persisted.entries, {
      quarantine: persisted.quarantine,
      privacySettings
    });
    await setQueueToolbarState(
      summary.queuedCount + summary.quarantinedCount,
      summary.blockedCount + summary.quarantinedCount
    );
  } else {
    const stored = await extensionAPI.storage.local.get(["bridgeToken"]);
    await setToolbarState(stored.bridgeToken ? "connected" : "disconnected");
  }
  return { ...persisted, privacySettings };
}

async function readCaptureQueue() {
  return (await readCaptureQueueStore()).entries;
}

async function writeCaptureQueue(queue) {
  const store = await readCaptureQueueStore();
  await writeCaptureQueueStore({ ...store, entries: queue });
}

function captureQueueItemSummary(entry, retentionDays) {
  const capture = entry.envelope?.capture || {};
  const createdAt = normalizedQueueDate(entry.createdAt);
  return {
    id: entry.id,
    title: String(capture.title || "未命名网页").slice(0, 300),
    sourceURL: normalizedPageIdentityURL(capture.sourceURL),
    captureMode: capture.captureMode || "cleaned-article",
    allowsLocalSemanticIndex: capture.allowsLocalSemanticIndex === undefined
      ? capture.allowsAIUse !== false
      : capture.allowsLocalSemanticIndex !== false,
    allowsRemoteAIUse: capture.allowsRemoteAIUse === true,
    storedContentMode: entry.storedContentMode === "links-only"
      ? "links-only"
      : "full-content",
    folderID: entry.envelope?.folderID || null,
    newFolderName: entry.envelope?.newFolderName || null,
    createdAt,
    updatedAt: normalizedQueueDate(entry.updatedAt),
    expiresAt: new Date(
      Date.parse(createdAt) + retentionDays * 24 * 60 * 60 * 1_000
    ).toISOString(),
    attempts: Number(entry.attempts || 0),
    blocked: Boolean(entry.blocked),
    status: entry.duplicateConflict
      ? "duplicate"
      : entry.blocked
        ? "failed"
        : Number(entry.attempts || 0) > 0
          ? "retrying"
          : "queued",
    lastError: String(entry.lastError || ""),
    previewText: String(capture.contentText || "").replace(/\s+/g, " ").trim().slice(0, 240),
    byteSize: queueJSONByteSize(entry)
  };
}

function quarantinedQueueItemSummary(entry, retentionDays) {
  const quarantinedAt = normalizedQueueDate(entry.quarantinedAt);
  return {
    id: entry.id,
    title: String(entry.title || "无法识别的队列项目"),
    sourceURL: normalizedPageIdentityURL(entry.sourceURL),
    quarantinedAt,
    expiresAt: new Date(
      Date.parse(quarantinedAt) + retentionDays * 24 * 60 * 60 * 1_000
    ).toISOString(),
    reason: String(entry.reason || "项目已隔离。"),
    originalSchemaVersion: entry.originalSchemaVersion ?? null,
    byteSize: Number(entry.byteSize || 0)
  };
}

function queueSummary(queue, options = {}) {
  const retentionDays = normalizedQueueRetentionDays(options.retentionDays);
  const quarantine = options.quarantine || [];
  const hasContent = queue.length > 0 || quarantine.length > 0;
  const hasStoredFullContent = queue.some((entry) => entry.storedContentMode !== "links-only")
    || quarantine.some((entry) => entry?.rawValue != null);
  const privacySettings = normalizedQueuePrivacySettings(
    options.privacySettings,
    options.privacySettings == null && hasStoredFullContent
  );
  const storeValue = options.store || queue;
  return {
    queueState: hasContent ? "content" : "empty",
    queueSchemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
    retentionDays,
    privacyMode: privacySettings.mode,
    allowPrivateSites: privacySettings.allowPrivateSites,
    minimizedCount: Number(options.minimizedCount || 0),
    fullContentCount: queue.filter((entry) => entry.storedContentMode !== "links-only").length,
    linkOnlyCount: queue.filter((entry) => entry.storedContentMode === "links-only").length,
    purgedCount: Number(options.purgedCount || 0),
    queuedCount: queue.length,
    quarantinedCount: quarantine.length,
    blockedCount: queue.filter((entry) => entry.blocked).length,
    totalBytes: queueJSONByteSize(storeValue),
    oldestCapturedAt: queue[0]?.createdAt || null,
    queueItems: queue.map((entry) => captureQueueItemSummary(entry, retentionDays)),
    quarantinedItems: quarantine.map((entry) =>
      quarantinedQueueItemSummary(entry, retentionDays)
    ),
    duplicateConflicts: queue
      .filter((entry) => entry.duplicateConflict)
      .map((entry) => ({
        queueID: entry.id,
        conflict: entry.duplicateConflict,
        sourceURL: normalizedPageIdentityURL(entry.envelope?.capture?.sourceURL),
        createdAt: entry.createdAt || null,
        targetFolderID: entry.envelope.folderID || null,
        targetNewFolderName: entry.envelope.newFolderName || null
      }))
  };
}

async function captureQueueStatus() {
  try {
    const store = await readCaptureQueueStore();
    return queueSummary(store.entries, {
      retentionDays: store.retentionDays,
      purgedCount: store.purgedCount,
      quarantine: store.quarantine,
      privacySettings: store.privacySettings,
      store
    });
  } catch (error) {
    return {
      queueState: "failed",
      queueSchemaVersion: error?.schemaVersion ?? null,
      retentionDays: normalizedQueueRetentionDays(error?.retentionDays),
      privacyMode: null,
      allowPrivateSites: false,
      purgedCount: 0,
      queuedCount: 0,
      quarantinedCount: 0,
      blockedCount: 0,
      totalBytes: 0,
      queueItems: [],
      quarantinedItems: [],
      duplicateConflicts: [],
      queueErrorCode: error?.code || "queue-read-failed",
      queueError: readableError(error)
    };
  }
}
