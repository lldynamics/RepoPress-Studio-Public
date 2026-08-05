function captureOperationKey(envelope) {
  return normalizedOperationID(envelope?.operationID);
}

function queueRetryDelay(attempts) {
  return Math.min(60 * 60 * 1_000, 30 * 1_000 * (2 ** Math.min(attempts, 7)));
}

async function enqueueCapture(envelope, archiveReport, originalError, privacyContext = {}) {
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const queue = [...store.entries];
    const now = new Date().toISOString();
    const protectedPayload = protectedQueuePayload(
      envelopeWithOperationID(envelope),
      archiveReport,
      store.privacySettings,
      privacyContext
    );
    envelope = protectedPayload.envelope;
    const operationKey = captureOperationKey(envelope);
    const existingIndex = queue.findIndex((entry) =>
      captureOperationKey(entry.envelope) === operationKey
    );
    const existing = existingIndex >= 0 ? queue[existingIndex] : null;
    const entry = {
      schemaVersion: CAPTURE_QUEUE_ITEM_SCHEMA_VERSION,
      id: existing?.id || globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      attempts: 1,
      nextAttemptAt: new Date(Date.now() + queueRetryDelay(1)).toISOString(),
      blocked: false,
      lastError: readableError(originalError),
      envelope,
      archiveReport: protectedPayload.archiveReport,
      storedContentMode: protectedPayload.storedContentMode,
      privacyContext: {
        isIncognito: Boolean(privacyContext?.isIncognito),
        isPrivateNetwork: Boolean(privacyContext?.isPrivateNetwork)
      }
    };
    if (existingIndex >= 0) {
      queue.splice(existingIndex, 1, entry);
    } else {
      queue.push(entry);
    }
    queue.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
    const nextStore = { ...store, entries: queue };
    const summary = queueSummary(queue, {
      retentionDays: store.retentionDays,
      quarantine: store.quarantine,
      privacySettings: store.privacySettings,
      store: nextStore
    });
    if (summary.queuedCount > MAX_QUEUE_ITEMS || summary.totalBytes > MAX_QUEUE_BYTES) {
      throw new Error("待保存队列已满，请先打开应用完成重试，或在插件中清理队列。");
    }
    try {
      await writeCaptureQueueStore(nextStore);
    } catch {
      throw new Error("浏览器无法写入待保存队列，请打开应用后重试。");
    }
    return summary;
  });
}

async function enqueueDuplicateConflict(
  envelope,
  conflict,
  archiveReport,
  privacyContext = {}
) {
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const queue = [...store.entries];
    const now = new Date().toISOString();
    const protectedPayload = protectedQueuePayload(
      envelopeWithOperationID(envelope),
      archiveReport,
      store.privacySettings,
      privacyContext
    );
    envelope = protectedPayload.envelope;
    const operationKey = captureOperationKey(envelope);
    const existingIndex = queue.findIndex((entry) =>
      captureOperationKey(entry.envelope) === operationKey
    );
    const existing = existingIndex >= 0 ? queue[existingIndex] : null;
    const entry = {
      schemaVersion: CAPTURE_QUEUE_ITEM_SCHEMA_VERSION,
      id: existing?.id || globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      attempts: Number(existing?.attempts || 0),
      nextAttemptAt: null,
      blocked: true,
      lastError: "检测到同网址资料，需要选择处理方式。",
      envelope,
      archiveReport: protectedPayload.archiveReport,
      storedContentMode: protectedPayload.storedContentMode,
      privacyContext: {
        isIncognito: Boolean(privacyContext?.isIncognito),
        isPrivateNetwork: Boolean(privacyContext?.isPrivateNetwork)
      },
      duplicateConflict: conflict
    };
    if (existingIndex >= 0) {
      queue.splice(existingIndex, 1, entry);
    } else {
      queue.push(entry);
    }
    queue.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
    const nextStore = { ...store, entries: queue };
    const summary = queueSummary(queue, {
      retentionDays: store.retentionDays,
      quarantine: store.quarantine,
      privacySettings: store.privacySettings,
      store: nextStore
    });
    if (summary.queuedCount > MAX_QUEUE_ITEMS || summary.totalBytes > MAX_QUEUE_BYTES) {
      throw new Error("待保存队列已满，无法保留重复网页的处理选择。");
    }
    await writeCaptureQueueStore(nextStore);
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

async function deleteCaptureQueueItem(queueID, quarantined) {
  if (!queueID) throw new Error("待保存项目标识无效。");
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const entries = quarantined
      ? store.entries
      : store.entries.filter((entry) => entry.id !== queueID);
    const quarantine = quarantined
      ? store.quarantine.filter((entry) => entry.id !== queueID)
      : store.quarantine;
    if (entries.length === store.entries.length
        && quarantine.length === store.quarantine.length) {
      throw new Error("该待保存项目已经不存在。");
    }
    const persisted = await writeCaptureQueueStore({ ...store, entries, quarantine });
    return queueSummary(persisted.entries, {
      retentionDays: store.retentionDays,
      quarantine: persisted.quarantine,
      store: persisted
    });
  });
}

async function exportCaptureQueue() {
  const stored = await extensionAPI.storage.local.get([
    CAPTURE_QUEUE_KEY,
    CAPTURE_QUEUE_RETENTION_KEY,
    CAPTURE_QUEUE_PRIVACY_KEY
  ]);
  const exportedAt = new Date().toISOString();
  const rawQueue = redactedQueueSnapshot(stored?.[CAPTURE_QUEUE_KEY] ?? null);
  const entries = Array.isArray(rawQueue?.entries)
    ? rawQueue.entries
    : Array.isArray(rawQueue) ? rawQueue : [];
  const containsPrivateReadingContent = entries.some(
    (entry) => entry?.storedContentMode !== "links-only"
  ) || Boolean(rawQueue?.quarantine?.some((entry) => entry?.rawValue != null));
  const privacySettings = normalizedQueuePrivacySettings(
    stored?.[CAPTURE_QUEUE_PRIVACY_KEY],
    stored?.[CAPTURE_QUEUE_PRIVACY_KEY] == null && containsPrivateReadingContent
  );
  return {
    fileName: `knowledge-capture-queue-${exportedAt.slice(0, 10)}.json`,
    export: {
      exportSchemaVersion: 1,
      exportedAt,
      retentionDays: normalizedQueueRetentionDays(stored?.[CAPTURE_QUEUE_RETENTION_KEY]),
      privacySettings,
      containsPrivateMetadata: entries.length > 0,
      containsPrivateReadingContent,
      queue: rawQueue
    }
  };
}

async function setCaptureQueueRetention(value) {
  const retentionDays = Number(value);
  if (!CAPTURE_QUEUE_RETENTION_OPTIONS.has(retentionDays)) {
    throw new Error("离线队列保留期限无效。");
  }
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const pruning = pruneCaptureQueueStore(store, retentionDays);
    await extensionAPI.storage.local.set({ [CAPTURE_QUEUE_RETENTION_KEY]: retentionDays });
    const persisted = await writeCaptureQueueStore(pruning.store);
    return queueSummary(persisted.entries, {
      retentionDays,
      purgedCount: pruning.purgedCount,
      quarantine: persisted.quarantine,
      privacySettings: persisted.privacySettings,
      store: persisted
    });
  });
}

async function setCaptureQueuePrivacy(modeValue, allowPrivateSitesValue) {
  const mode = String(modeValue || "");
  if (!CAPTURE_QUEUE_PRIVACY_MODES.has(mode)) {
    throw new Error("离线队列隐私模式无效。");
  }
  const privacySettings = {
    mode,
    allowPrivateSites: allowPrivateSitesValue === true
  };
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    let entries = store.entries;
    let quarantine = store.quarantine;
    let purgedCount = 0;
    let minimizedCount = 0;

    if (mode === "disabled") {
      purgedCount = entries.length + quarantine.length;
      entries = [];
      quarantine = [];
    } else {
      if (mode === "links-only") {
        entries = entries.map((entry) => {
          if (entry.storedContentMode === "links-only") return entry;
          minimizedCount += 1;
          return minimizedQueueEntry(entry);
        });
        quarantine = quarantine.map((entry) => ({
          ...entry,
          byteSize: 0,
          rawValue: null,
          reason: `${String(entry.reason || "项目已隔离。")} 原始内容已按隐私设置移除。`
        }));
      }
      if (!privacySettings.allowPrivateSites) {
        const beforeCount = entries.length;
        entries = entries.filter((entry) => !queueEntryIsPrivate(entry));
        purgedCount += beforeCount - entries.length;
      }
    }

    const persisted = await writeCaptureQueueStore({
      ...store,
      entries,
      quarantine,
      privacySettings
    });
    return queueSummary(persisted.entries, {
      retentionDays: store.retentionDays,
      purgedCount,
      minimizedCount,
      quarantine: persisted.quarantine,
      privacySettings,
      store: persisted
    });
  });
}

async function discardCaptureQueue() {
  return withQueueLock(async () => {
    const stored = await extensionAPI.storage.local.get([
      CAPTURE_QUEUE_RETENTION_KEY,
      CAPTURE_QUEUE_PRIVACY_KEY
    ]);
    const retentionDays = normalizedQueueRetentionDays(stored?.[CAPTURE_QUEUE_RETENTION_KEY]);
    const privacySettings = normalizedQueuePrivacySettings(
      stored?.[CAPTURE_QUEUE_PRIVACY_KEY]
    );
    const store = { ...emptyCaptureQueueStore(), privacySettings };
    await writeCaptureQueueStore(store);
    return {
      importedCount: 0,
      ...queueSummary([], {
        retentionDays,
        quarantine: [],
        privacySettings,
        store
      })
    };
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
  const store = await readCaptureQueueStore();
  const queue = store.entries;
  await updateCaptureQueueAlarm(queue.some((entry) => !entry.blocked));
  if (queue.length || store.quarantine.length) {
    const summary = queueSummary(queue, { quarantine: store.quarantine });
    await setQueueToolbarState(
      summary.queuedCount + summary.quarantinedCount,
      summary.blockedCount + summary.quarantinedCount
    );
  } else {
    const stored = await extensionAPI.storage.local.get(["bridgeToken"]);
    await setToolbarState(stored.bridgeToken ? "connected" : "disconnected");
  }
  if (queue.length) await flushCaptureQueue(null, false);
}
