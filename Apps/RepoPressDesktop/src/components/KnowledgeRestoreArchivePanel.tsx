import { useEffect, useRef, useState } from "react";
import type {
  KnowledgeRestoreArchiveAction,
  KnowledgeRestoreArchiveEntry,
  KnowledgeRestoreArchiveGateway,
  KnowledgeRestoreArchivePlan,
  KnowledgeRestoreArchiveReceipt,
  KnowledgeRestoreArchiveStatus,
  KnowledgeRestoreTerminalPhase,
} from "../contracts/knowledgeRestoreArchive";

export interface KnowledgeRestoreArchivePanelProps {
  gateway: KnowledgeRestoreArchiveGateway;
  enabled: boolean;
  disabled?: boolean;
  refreshKey?: number;
}

const TTL_MS = 300_000;
const HISTORY_LIMIT = 4;
const MAX_SNAPSHOT_FILES = 2_049;
const MAX_SNAPSHOT_BYTES = 66 * 1024 * 1024;
const MAX_TIME = 8.64e15;
const statusKeys = ["schemaVersion", "scope", "state", "transactionId", "phase", "currentManifestSha256", "transactionJournalSha256", "snapshotManifestSha256", "snapshotPresent", "snapshotFileCount", "snapshotByteSize", "history", "historyLimit", "canArchive", "canResume", "transactionSlotReleased", "libraryAccessBlocked", "filesystemWrites"] as const;
const entryKeys = ["transactionId", "phase", "previousManifestSha256", "projectedManifestSha256", "snapshotManifestSha256", "snapshotPresent", "snapshotFileCount", "snapshotByteSize", "archivedAtEpochMs"] as const;
const planKeys = ["schemaVersion", "scope", "planId", "action", "status", "requiresAcknowledgement", "preservesSnapshot", "currentLibraryChanged", "disablesDirectRollback", "releasesTransactionSlot", "checkedAtEpochMs", "expiresAtEpochMs"] as const;
const receiptKeys = ["schemaVersion", "scope", "planId", "transactionId", "action", "state", "entry", "snapshotRetained", "currentLibraryChanged", "transactionSlotReleased", "journalArchived", "libraryAccessBlocked", "completedAtEpochMs"] as const;
const terminalPhases: KnowledgeRestoreTerminalPhase[] = ["committed", "rolledBack", "cancelled"];

const record = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);
const exactKeys = (value: Record<string, unknown>, keys: readonly string[]) => {
  const actual = Object.keys(value);
  return actual.length === keys.length && keys.every((key) => Object.prototype.hasOwnProperty.call(value, key));
};
const uuidV4 = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
const sha256 = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const safeInt = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value);
const validTime = (value: unknown): value is number => safeInt(value) && value > 0 && value <= MAX_TIME;
const snapshot = (value: unknown) => JSON.stringify(value);
const copy = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

function validSnapshotFields(value: {
  snapshotPresent: unknown;
  snapshotManifestSha256: unknown;
  snapshotFileCount: unknown;
  snapshotByteSize: unknown;
}) {
  if (typeof value.snapshotPresent !== "boolean") return false;
  if (!value.snapshotPresent) {
    return value.snapshotManifestSha256 === null && value.snapshotFileCount === 0 && value.snapshotByteSize === 0;
  }
  return sha256(value.snapshotManifestSha256)
    && safeInt(value.snapshotFileCount) && value.snapshotFileCount >= 1 && value.snapshotFileCount <= MAX_SNAPSHOT_FILES
    && safeInt(value.snapshotByteSize) && value.snapshotByteSize >= 1 && value.snapshotByteSize <= MAX_SNAPSHOT_BYTES;
}

function validEntry(value: unknown, now: number): value is KnowledgeRestoreArchiveEntry {
  if (!record(value) || !exactKeys(value, entryKeys)) return false;
  const entry = value as unknown as KnowledgeRestoreArchiveEntry;
  return uuidV4(entry.transactionId) && terminalPhases.includes(entry.phase)
    && sha256(entry.previousManifestSha256) && sha256(entry.projectedManifestSha256)
    && validSnapshotFields(entry) && validTime(entry.archivedAtEpochMs) && entry.archivedAtEpochMs <= now;
}

function validHistory(value: unknown, now: number): value is KnowledgeRestoreArchiveEntry[] {
  if (!Array.isArray(value) || value.length > HISTORY_LIMIT || !value.every((entry) => validEntry(entry, now))) return false;
  return new Set(value.map((entry) => entry.transactionId)).size === value.length;
}

function validKnownStatusFields(status: KnowledgeRestoreArchiveStatus) {
  return uuidV4(status.transactionId) && terminalPhases.includes(status.phase as KnowledgeRestoreTerminalPhase)
    && sha256(status.currentManifestSha256) && sha256(status.transactionJournalSha256)
    && validSnapshotFields(status);
}

function validStatus(value: unknown, now = Date.now()): value is KnowledgeRestoreArchiveStatus {
  if (!record(value) || !exactKeys(value, statusKeys)) return false;
  const status = value as unknown as KnowledgeRestoreArchiveStatus;
  if (status.schemaVersion !== 1 || status.scope !== "knowledgeRestoreArchiveStatus" || status.historyLimit !== HISTORY_LIMIT
    || status.filesystemWrites !== false || typeof status.canArchive !== "boolean" || typeof status.canResume !== "boolean"
    || typeof status.transactionSlotReleased !== "boolean" || typeof status.libraryAccessBlocked !== "boolean"
    || !validHistory(status.history, now)) return false;

  if (status.state === "none") {
    return status.transactionId === null && status.phase === null && status.currentManifestSha256 === null
      && status.transactionJournalSha256 === null && status.snapshotManifestSha256 === null
      && status.snapshotPresent === false && status.snapshotFileCount === null && status.snapshotByteSize === null
      && !status.canArchive && !status.canResume && status.transactionSlotReleased && !status.libraryAccessBlocked;
  }
  if (status.state === "eligible") {
    return validKnownStatusFields(status) && status.canArchive === (status.history.length < HISTORY_LIMIT)
      && !status.canResume && !status.transactionSlotReleased && !status.libraryAccessBlocked
      && !status.history.some((entry) => entry.transactionId === status.transactionId);
  }
  if (status.state === "archiving" || status.state === "archived") {
    return validKnownStatusFields(status) && !status.canArchive && status.canResume
      && !status.transactionSlotReleased && status.libraryAccessBlocked
      && !status.history.some((entry) => entry.transactionId === status.transactionId);
  }
  if (status.state === "blocked" || status.state === "unavailable") {
    return status.transactionId === null && status.phase === null && status.currentManifestSha256 === null
      && status.transactionJournalSha256 === null && status.snapshotManifestSha256 === null
      && status.snapshotPresent === false && status.snapshotFileCount === null && status.snapshotByteSize === null
      && status.history.length === 0 && !status.canArchive && !status.canResume && !status.transactionSlotReleased
      && (status.state === "blocked" || status.libraryAccessBlocked);
  }
  return false;
}

function actionAllowed(status: KnowledgeRestoreArchiveStatus, action: KnowledgeRestoreArchiveAction) {
  return action === "archive"
    ? status.state === "eligible" && status.canArchive
    : (status.state === "archiving" || status.state === "archived") && status.canResume;
}

function validPlan(
  value: unknown,
  status: KnowledgeRestoreArchiveStatus,
  statusSnapshot: string,
  action: KnowledgeRestoreArchiveAction,
  now = Date.now(),
): value is KnowledgeRestoreArchivePlan {
  if (!record(value) || !exactKeys(value, planKeys)) return false;
  const plan = value as unknown as KnowledgeRestoreArchivePlan;
  return plan.schemaVersion === 1 && plan.scope === "knowledgeRestoreArchivePlan" && uuidV4(plan.planId)
    && plan.action === action && actionAllowed(status, action) && validStatus(plan.status, now)
    && snapshot(plan.status) === statusSnapshot && snapshot(status) === statusSnapshot
    && plan.requiresAcknowledgement === true && plan.preservesSnapshot === true
    && plan.currentLibraryChanged === false && plan.disablesDirectRollback === true && plan.releasesTransactionSlot === true
    && validTime(plan.checkedAtEpochMs) && validTime(plan.expiresAtEpochMs)
    && plan.checkedAtEpochMs <= now && plan.expiresAtEpochMs > now
    && plan.expiresAtEpochMs - plan.checkedAtEpochMs === TTL_MS;
}

function validReceipt(value: unknown, plan: KnowledgeRestoreArchivePlan, now = Date.now()): value is KnowledgeRestoreArchiveReceipt {
  if (!record(value) || !exactKeys(value, receiptKeys) || plan.status.transactionId === null || plan.status.phase === null) return false;
  const receipt = value as unknown as KnowledgeRestoreArchiveReceipt;
  if (receipt.schemaVersion !== 1 || receipt.scope !== "knowledgeRestoreArchiveReceipt" || receipt.planId !== plan.planId
    || receipt.transactionId !== plan.status.transactionId || receipt.action !== plan.action || receipt.state !== "archived"
    || receipt.snapshotRetained !== plan.status.snapshotPresent || receipt.currentLibraryChanged !== false
    || receipt.transactionSlotReleased !== true || receipt.journalArchived !== true || receipt.libraryAccessBlocked !== false
    || !validTime(receipt.completedAtEpochMs) || receipt.completedAtEpochMs < plan.checkedAtEpochMs
    || receipt.completedAtEpochMs > now || !validEntry(receipt.entry, receipt.completedAtEpochMs)) return false;
  return receipt.entry.transactionId === plan.status.transactionId && receipt.entry.phase === plan.status.phase
    && receipt.entry.snapshotPresent === plan.status.snapshotPresent
    && receipt.entry.snapshotManifestSha256 === plan.status.snapshotManifestSha256
    && receipt.entry.snapshotFileCount === plan.status.snapshotFileCount
    && receipt.entry.snapshotByteSize === plan.status.snapshotByteSize
    && (plan.action === "archive"
      ? receipt.entry.archivedAtEpochMs >= plan.checkedAtEpochMs
      : receipt.entry.archivedAtEpochMs <= plan.checkedAtEpochMs)
    && receipt.entry.archivedAtEpochMs <= receipt.completedAtEpochMs;
}

const recognizablePlanId = (value: unknown) => record(value) && uuidV4(value.planId);

type Context = {
  gateway: KnowledgeRestoreArchiveGateway;
  enabled: boolean;
  disabled: boolean;
  refreshKey: number | undefined;
};
type StatusBinding = { value: KnowledgeRestoreArchiveStatus; snapshot: string; context: Context };
type PlanBinding = { value: KnowledgeRestoreArchivePlan; snapshot: string; status: StatusBinding; context: Context };

const stateLabel: Record<KnowledgeRestoreArchiveStatus["state"], string> = {
  none: "没有占用事务槽的恢复事务",
  eligible: "已知终态，可准备归档",
  archiving: "归档意图已持久化，需要恢复",
  archived: "归档已写入，需要完成恢复",
  blocked: "状态不完整或历史损坏，已阻止归档",
  unavailable: "归档状态不可用",
};
const phaseLabel: Record<KnowledgeRestoreTerminalPhase, string> = {
  committed: "已完成", rolledBack: "已回滚", cancelled: "已取消",
};

export function KnowledgeRestoreArchivePanel({ gateway, enabled, disabled = false, refreshKey }: KnowledgeRestoreArchivePanelProps) {
  const [status, setStatus] = useState<KnowledgeRestoreArchiveStatus | null>(null);
  const [plan, setPlan] = useState<KnowledgeRestoreArchivePlan | null>(null);
  const [receipt, setReceipt] = useState<KnowledgeRestoreArchiveReceipt | null>(null);
  const [acknowledged, setAcknowledged] = useState(false);
  const [busy, setBusy] = useState<"inspecting" | "planning" | "executing" | null>(null);
  const [error, setError] = useState("");
  const context: Context = { gateway, enabled, disabled, refreshKey };
  const contextRef = useRef(context);
  contextRef.current = context;
  const statusRef = useRef<StatusBinding | null>(null);
  const planRef = useRef<PlanBinding | null>(null);
  const receiptRef = useRef<{ value: KnowledgeRestoreArchiveReceipt; context: Context } | null>(null);
  const acknowledgementRef = useRef(false);
  const busyRef = useRef(false);
  const generation = useRef(0);
  const usable = enabled && !disabled;

  const same = (candidate: Context) => {
    const current = contextRef.current;
    return candidate.gateway === current.gateway && candidate.enabled === current.enabled
      && candidate.disabled === current.disabled && candidate.refreshKey === current.refreshKey;
  };
  const discardId = (planId: string, sourceGateway: KnowledgeRestoreArchiveGateway) => {
    void sourceGateway.discardKnowledgeRestoreArchive(planId).catch(() => undefined);
  };
  const discardPlan = () => {
    const bound = planRef.current;
    planRef.current = null;
    if (bound) discardId(bound.value.planId, bound.context.gateway);
    setPlan(null); acknowledgementRef.current = false; setAcknowledged(false);
  };
  const invalidate = (clearStatus = true) => {
    discardPlan(); generation.current += 1; receiptRef.current = null; setReceipt(null); setError("");
    if (clearStatus) { statusRef.current = null; setStatus(null); }
  };

  const statusBinding = statusRef.current;
  const shownStatus = usable && status && statusBinding?.value === status && same(statusBinding.context)
    && snapshot(status) === statusBinding.snapshot && validStatus(status) ? status : null;
  const planBinding = planRef.current;
  const shownPlan = usable && plan && planBinding?.value === plan && same(planBinding.context)
    && shownStatus && statusBinding && planBinding.status === statusBinding
    && snapshot(plan) === planBinding.snapshot
    && validPlan(plan, shownStatus, statusBinding.snapshot, plan.action) ? plan : null;
  const shownReceipt = usable && receipt && receiptRef.current?.value === receipt && same(receiptRef.current.context) ? receipt : null;

  useEffect(() => {
    const old = planRef.current;
    planRef.current = null;
    if (old) discardId(old.value.planId, old.context.gateway);
    statusRef.current = null; receiptRef.current = null; acknowledgementRef.current = false;
    generation.current += 1; busyRef.current = false;
    setStatus(null); setPlan(null); setReceipt(null); setAcknowledged(false); setBusy(null); setError("");
    return () => {
      const current = planRef.current;
      planRef.current = null;
      if (current) discardId(current.value.planId, current.context.gateway);
      statusRef.current = null; receiptRef.current = null; acknowledgementRef.current = false;
      generation.current += 1; busyRef.current = false;
    };
  }, [gateway, enabled, disabled, refreshKey]);

  useEffect(() => {
    const binding = planRef.current;
    if (!binding || binding.value !== plan) return;
    const timer = window.setTimeout(() => {
      if (planRef.current !== binding) return;
      discardPlan(); generation.current += 1;
      setError("归档计划已过期，请重新检查并准备。");
    }, Math.max(0, binding.value.expiresAtEpochMs - Date.now()));
    return () => window.clearTimeout(timer);
  }, [plan?.planId, plan?.expiresAtEpochMs]);

  async function inspect() {
    const requestContext = { ...contextRef.current };
    if (!same(context) || !requestContext.enabled || requestContext.disabled || busyRef.current) return;
    invalidate();
    const request = ++generation.current; busyRef.current = true; setBusy("inspecting");
    try {
      const next: unknown = await requestContext.gateway.inspectKnowledgeRestoreArchive();
      if (request !== generation.current || !same(requestContext)) return;
      if (!validStatus(next)) throw new Error("invalid archive status");
      const accepted = copy(next);
      if (!validStatus(accepted)) throw new Error("invalid copied archive status");
      const binding: StatusBinding = { value: accepted, snapshot: snapshot(accepted), context: requestContext };
      statusRef.current = binding; setStatus(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("无法核验恢复归档状态；读取失败不表示事务槽可用，请勿开始新的恢复安装。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function prepare(action: KnowledgeRestoreArchiveAction) {
    const currentStatus = shownStatus;
    const currentBinding = statusRef.current;
    const requestContext = { ...contextRef.current };
    if (!currentStatus || !currentBinding || currentStatus.transactionId === null || !same(context)
      || !same(requestContext) || !requestContext.enabled || requestContext.disabled || busyRef.current
      || snapshot(currentStatus) !== currentBinding.snapshot || !actionAllowed(currentStatus, action)) return;
    discardPlan(); receiptRef.current = null; setReceipt(null); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("planning");
    try {
      const next: unknown = await requestContext.gateway.planKnowledgeRestoreArchive(currentStatus.transactionId, action);
      if (request !== generation.current || !same(requestContext) || statusRef.current !== currentBinding) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, requestContext.gateway);
        return;
      }
      if (!validPlan(next, currentStatus, currentBinding.snapshot, action)) {
        if (recognizablePlanId(next)) discardId((next as { planId: string }).planId, requestContext.gateway);
        throw new Error("invalid archive plan");
      }
      const accepted = copy(next);
      if (!validPlan(accepted, currentStatus, currentBinding.snapshot, action)) throw new Error("invalid copied archive plan");
      const binding: PlanBinding = { value: accepted, snapshot: snapshot(accepted), status: currentBinding, context: requestContext };
      planRef.current = binding; setPlan(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("归档计划无效；请重新检查状态。系统不会自动归档、恢复、写入或删除文件。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  async function execute() {
    const binding = planRef.current;
    const currentStatusBinding = statusRef.current;
    const requestContext = { ...contextRef.current };
    if (!binding || !currentStatusBinding || !same(context) || !same(requestContext) || !requestContext.enabled
      || requestContext.disabled || busyRef.current || !acknowledged || !acknowledgementRef.current
      || !same(binding.context) || binding.status !== currentStatusBinding || snapshot(binding.value) !== binding.snapshot) return;
    const now = Date.now();
    if (now < binding.value.checkedAtEpochMs || now >= binding.value.expiresAtEpochMs
      || !validPlan(binding.value, currentStatusBinding.value, currentStatusBinding.snapshot, binding.value.action, now)) {
      discardPlan(); generation.current += 1; setError("归档计划已过期或系统时间已变化，请重新检查并准备。"); return;
    }

    // Consume the one-use UI capability before crossing the gateway boundary.
    planRef.current = null; statusRef.current = null; receiptRef.current = null;
    setPlan(null); setStatus(null); setReceipt(null); acknowledgementRef.current = false; setAcknowledged(false); setError("");
    const request = ++generation.current; busyRef.current = true; setBusy("executing");
    try {
      const next: unknown = await requestContext.gateway.executeKnowledgeRestoreArchive(binding.value.planId, true);
      if (request !== generation.current || !same(requestContext)) return;
      if (!validReceipt(next, binding.value)) throw new Error("invalid archive receipt");
      const accepted = copy(next);
      if (!validReceipt(accepted, binding.value)) throw new Error("invalid copied archive receipt");
      receiptRef.current = { value: accepted, context: requestContext }; setReceipt(accepted);
    } catch {
      if (request === generation.current && same(requestContext)) {
        setError("归档可能已写入，但完成状态未知；计划已消耗。请重新检查归档状态，系统不会自动重试。");
      }
    } finally {
      if (request === generation.current) { busyRef.current = false; setBusy(null); }
    }
  }

  function changeAcknowledgement(value: boolean) {
    if (!shownPlan || busyRef.current || !usable || !same(context)) return;
    acknowledgementRef.current = value; setAcknowledged(value);
  }

  function abandonPlan() {
    if (!shownPlan || busyRef.current || !usable || !same(context)) return;
    discardPlan(); generation.current += 1; setError("");
  }

  if (!enabled) return null;
  return <section className="operation-plan" aria-label="知识库恢复事务归档" aria-busy={busy !== null}>
    <h4>知识库恢复事务归档</h4>
    <p className="publish-muted">手动检查已知终态事务后，可将事务日志和完整保留快照登记到最多 4 条的私有历史，并释放唯一事务槽。</p>
    <p className="publish-warning">归档会禁用 P52 直接回滚，但不会删除快照、回收磁盘空间或改变当前资料库。保留历史和快照可能包含私密明文。</p>
    <button type="button" onClick={() => void inspect()} disabled={!usable || busy !== null}>检查归档状态</button>
    {busy && <p role="status">{busy === "inspecting" ? "正在只读检查归档状态…" : busy === "planning" ? "正在准备一次性归档计划…" : "正在执行一次性归档操作…"}</p>}
    {error && <p role="alert" className="publish-warning">{error}</p>}

    {shownStatus && <div className="operation-plan">
      <p><strong>只读归档状态</strong></p>
      <p>状态：{stateLabel[shownStatus.state]}；私有历史：{shownStatus.history.length}/{shownStatus.historyLimit}</p>
      {shownStatus.transactionId && shownStatus.phase && <p>事务 ID：{shownStatus.transactionId}；终态：{phaseLabel[shownStatus.phase]}</p>}
      {shownStatus.currentManifestSha256 && <p>当前清单 SHA-256：{shownStatus.currentManifestSha256}</p>}
      <p>资料库访问：{shownStatus.libraryAccessBlocked ? "已阻止" : "可用"}；事务槽：{shownStatus.transactionSlotReleased ? "已释放" : "仍占用"}</p>
      {shownStatus.snapshotPresent && <p>完整快照：已保留；文件 {shownStatus.snapshotFileCount}；字节 {shownStatus.snapshotByteSize}；SHA-256：{shownStatus.snapshotManifestSha256}</p>}
      {!shownStatus.snapshotPresent && shownStatus.snapshotFileCount !== null && <p>完整快照：未形成；取消终态仍可归档日志。</p>}
      {shownStatus.canArchive && <button type="button" onClick={() => void prepare("archive")} disabled={busy !== null}>准备归档计划</button>}
      {shownStatus.canResume && <button type="button" onClick={() => void prepare("resume")} disabled={busy !== null}>准备恢复归档计划</button>}
      {!shownStatus.canArchive && !shownStatus.canResume && <p className="publish-muted">当前状态没有可准备的归档操作。</p>}
    </div>}

    {shownPlan && <div className="operation-plan">
      <p><strong>{shownPlan.action === "archive" ? "归档计划" : "恢复归档计划"}（一次性，5 分钟内有效）</strong></p>
      <p>事务 ID：{shownPlan.status.transactionId}；操作：{shownPlan.action === "archive" ? "归档已知终态" : "恢复已中断归档"}</p>
      <p className="publish-warning">确认后会登记私有历史并释放事务槽；P52 直接回滚将不可用。快照和日志不会被删除，也不会回收磁盘容量。</p>
      <label><input type="checkbox" checked={acknowledged} onChange={(event) => changeAcknowledgement(event.target.checked)} disabled={busy !== null} />我确认保留私密明文快照和最多 4 条历史，释放事务槽，并接受直接回滚被禁用。</label>
      <button type="button" onClick={() => void execute()} disabled={!acknowledged || busy !== null}>确认并执行归档</button>
      <button type="button" onClick={abandonPlan} disabled={busy !== null}>放弃归档计划</button>
    </div>}

    {shownReceipt && <div className="operation-plan">
      <p role="status">恢复事务已归档，唯一事务槽已释放。</p>
      <p>事务 ID：{shownReceipt.transactionId}；终态：{phaseLabel[shownReceipt.entry.phase]}；归档日志已持久化。</p>
      <p>{shownReceipt.snapshotRetained ? "完整私有快照继续保留，不会自动清理。" : "该取消事务没有完整快照；归档未声明或执行磁盘清理。"}</p>
    </div>}
  </section>;
}
