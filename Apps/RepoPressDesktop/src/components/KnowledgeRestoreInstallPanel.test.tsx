import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KNOWLEDGE_CANDIDATE_CHECK_LIMITS } from "../contracts/knowledgeCandidateCheck";
import { KNOWLEDGE_MERGE_PROJECTION_LIMITS, type KnowledgeMergeProjectionPlan } from "../contracts/knowledgeMergeProjection";
import type {
  KnowledgeRestoreDiagnosis,
  KnowledgeRestoreInstallGateway,
  KnowledgeRestoreInstallPlan,
  KnowledgeRestoreReceipt,
  KnowledgeRestoreRecoveryAction,
  KnowledgeRestoreRecoveryPlan,
} from "../contracts/knowledgeRestoreInstall";
import { KnowledgeRestoreInstallPanel } from "./KnowledgeRestoreInstallPanel";

const now = 1700000000000;
const stageId = "11111111-1111-4111-8111-111111111111";
const candidatePath = "/private/repopress-knowledge-stage-" + stageId;
const installPlanId = "55555555-5555-4555-8555-555555555555";
const transactionId = "66666666-6666-4666-8666-666666666666";
const recoveryPlanId = "77777777-7777-4777-8777-777777777777";
const sha = (character: string) => character.repeat(64);

function projectionPlan(): KnowledgeMergeProjectionPlan {
  return {
    schemaVersion: 1, scope: "knowledgeMergeProjection", planId: "44444444-4444-4444-8444-444444444444",
    source: {
      schemaVersion: 1, scope: "knowledgeRestoreQualification", planId: "22222222-2222-4222-8222-222222222222",
      targetScope: "currentAppKnowledgeLibrary",
      candidate: {
        reportId: "33333333-3333-4333-8333-333333333333", candidatePath, stagePlanId: stageId,
        schemaVersion: 1, scope: "selectedKnowledgeCandidate", sourcePackageSha256: sha("a"), manifestSha256: sha("b"),
        candidateInventorySha256: sha("c"), candidateFileCount: 4, candidateByteSize: 900, itemCount: 2,
        revisionCount: 2, folderCount: 0,
        currentLibrary: { state: "checked", manifestSha256: sha("d"), itemCount: 1, revisionCount: 1, folderCount: 0 },
        conflicts: { candidateOnlyItems: 1, currentOnlyItems: 0, identicalItems: 1, changedItems: 0,
          candidateOnlyFolders: 0, currentOnlyFolders: 0, identicalFolders: 0, changedFolders: 0 },
        limits: KNOWLEDGE_CANDIDATE_CHECK_LIMITS, candidateStructureVerified: true, candidateContentsVerified: true,
        privatePermissionsVerified: true, sourcePackageHashVerified: false, candidateAuthenticityVerified: false,
        currentLibraryResourcesVerified: false, comparisonScope: "manifestIdentityAndMetadataOnly",
        consistentSnapshot: false, filesystemWrites: false, currentLibraryChanged: false, restoreReady: false,
        checkedAtEpochMs: now, expiresAtEpochMs: now + 300000,
      },
      currentResources: { state: "checked", fileCount: 1, byteSize: 100, inventorySha256: sha("e"),
        unreferencedFilesVerified: false, externalReferencesVerified: false },
      strategy: "requireNoIdentityConflicts",
      qualification: { state: "evidenceReady", reason: "none", addItems: 1, retainItems: 1, skipCandidateItems: 1,
        addFolders: 0, retainFolders: 0, skipCandidateFolders: 0 },
      currentOnlyPreserved: true, candidatePermissionsApplied: false, projectedManifestValidated: false,
      consistentSnapshot: false, filesystemWrites: false, restoreReady: false,
      checkedAtEpochMs: now, expiresAtEpochMs: now + 300000,
    },
    projection: { state: "validated", reason: "none", manifestSha256: sha("f"), manifestByteSize: 700,
      itemCount: 2, revisionCount: 2, folderCount: 0, fileCount: 2, resourceByteSize: 200, bodyByteSize: 200,
      archiveByteSize: 0, importedItems: 1, importedFolders: 0, resetPermissionItems: 1,
      completedOperationsExcluded: true },
    limits: KNOWLEDGE_MERGE_PROJECTION_LIMITS, privacyMode: "disableImportedPermissions",
    privacyResetAcknowledgementRequired: true, currentPermissionsPreserved: true, sourcePermissionsCopied: false,
    projectedManifestValidated: true, filesystemWrites: false, currentLibraryChanged: false, restoreReady: false,
    consistentSnapshot: false, checkedAtEpochMs: now, expiresAtEpochMs: now + 300000,
  };
}

function installPlan(): KnowledgeRestoreInstallPlan {
  return {
    schemaVersion: 1, scope: "knowledgeRestoreInstall", planId: installPlanId, projection: projectionPlan(),
    requiresAcknowledgement: true, writesCurrentLibrary: true, preservesRollbackSnapshot: true,
    importedPermissionsDisabled: true, currentOnlyPreserved: true, completedOperationsExcluded: true,
    transactionLimit: 1, checkedAtEpochMs: now, expiresAtEpochMs: now + 300000,
  };
}

function diagnosis(overrides: Partial<KnowledgeRestoreDiagnosis> = {}): KnowledgeRestoreDiagnosis {
  return {
    schemaVersion: 1, scope: "knowledgeRestoreDiagnosis", state: "installed", transactionId, phase: "intent",
    previousManifestSha256: sha("d"), projectedManifestSha256: sha("f"), canFinalize: true, canRollback: true,
    canCancel: false, libraryAccessBlocked: true, snapshotRetained: true, filesystemWrites: false, ...overrides,
  };
}

function recoveryPlan(action: KnowledgeRestoreRecoveryAction = "finalize"): KnowledgeRestoreRecoveryPlan {
  return {
    schemaVersion: 1, scope: "knowledgeRestoreRecovery", planId: recoveryPlanId, transactionId, action,
    diagnosis: diagnosis(), requiresAcknowledgement: true, preservesSnapshot: true,
    checkedAtEpochMs: now, expiresAtEpochMs: now + 300000,
  };
}

function receipt(action: "install" | KnowledgeRestoreRecoveryAction = "install"): KnowledgeRestoreReceipt {
  return {
    schemaVersion: 1, scope: "knowledgeRestoreReceipt",
    planId: action === "install" ? installPlanId : recoveryPlanId,
    transactionId, state: action === "install" || action === "finalize" ? "committed" : action === "rollback" ? "rolledBack" : "cancelled",
    action, previousManifestSha256: sha("d"), projectedManifestSha256: sha("f"), importedPermissionsDisabled: true,
    snapshotRetained: true, journalPersisted: true, libraryAccessBlocked: false, completedAtEpochMs: now,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

type MockGateway = { [K in keyof KnowledgeRestoreInstallGateway]: ReturnType<typeof vi.fn> };
let gateway: MockGateway;
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
const render = (props: Partial<React.ComponentProps<typeof KnowledgeRestoreInstallPanel>> = {}) =>
  root.render(createElement(KnowledgeRestoreInstallPanel, {
    gateway: gateway as unknown as KnowledgeRestoreInstallGateway, enabled: true, ...props,
  }));
const button = (label: string) => [...host.querySelectorAll("button")].find(item => item.textContent === label) as HTMLButtonElement | undefined;
const click = async (label: string) => { await act(async () => { button(label)!.click(); }); };
const acknowledge = async () => {
  const checkbox = host.querySelector("input[type=checkbox]") as HTMLInputElement;
  await act(async () => { checkbox.click(); });
};
const prepareInstall = async () => { await click("选择候选目录"); await click("准备安装计划"); };
function handler(element: Element) {
  const key = Object.keys(element).find(value => value.startsWith("__reactProps"))!;
  return (element as unknown as Record<string, { onClick: () => void }>)[key].onClick;
}

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
describe("KnowledgeRestoreInstallPanel", () => {
  beforeEach(() => {
    vi.useFakeTimers(); vi.setSystemTime(now);
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      selectKnowledgeCandidateDirectory: vi.fn(async () => candidatePath),
      planKnowledgeRestoreInstall: vi.fn(async () => installPlan()),
      executeKnowledgeRestoreInstall: vi.fn(async () => receipt()),
      inspectKnowledgeRestore: vi.fn(async () => diagnosis()),
      planKnowledgeRestoreRecovery: vi.fn(async () => recoveryPlan()),
      executeKnowledgeRestoreRecovery: vi.fn(async () => receipt("finalize")),
      discardKnowledgeRestoreInstall: vi.fn(async () => undefined),
    };
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("requires explicit selection and acknowledgement, then consumes a valid install plan once", async () => {
    await act(async () => render());
    expect(gateway.inspectKnowledgeRestore).not.toHaveBeenCalled();
    expect(button("准备安装计划")).toBeUndefined();
    await prepareInstall();
    expect(gateway.planKnowledgeRestoreInstall).toHaveBeenCalledExactlyOnceWith(candidatePath, "requireNoIdentityConflicts");
    expect(button("确认并安装")!.disabled).toBe(true);
    expect(host.textContent).toContain("事务上限：1");
    expect(host.textContent).toContain("未知或未引用文件时会拒绝安装");
    expect(host.textContent).toContain("外部附件与来源真实性不在本次核验范围内");
    expect(host.textContent).toContain("完成、回滚或取消后仍被占用");
    expect(host.textContent).toContain("可能包含私密明文");
    expect(host.textContent).toContain("不会隐式删除");
    await acknowledge(); await click("确认并安装");
    expect(gateway.executeKnowledgeRestoreInstall).toHaveBeenCalledExactlyOnceWith(installPlanId, true);
    expect(host.textContent).toContain("安装已提交");
    expect(host.textContent).toContain("旧快照已保留");
    expect(host.textContent).toContain("后端自动重新加载");
    expect(button("检查恢复状态")!.disabled).toBe(false);
  });

  it("uses a separate explicit recovery plan and acknowledgement after readonly inspection", async () => {
    await act(async () => render()); await click("检查恢复状态");
    expect(host.textContent).toContain("只读恢复诊断");
    expect(button("确认执行恢复操作")).toBeUndefined();
    await click("准备完成计划");
    expect(gateway.planKnowledgeRestoreRecovery).toHaveBeenCalledExactlyOnceWith(transactionId, "finalize");
    expect(button("确认执行恢复操作")!.disabled).toBe(true);
    await acknowledge(); await click("确认执行恢复操作");
    expect(gateway.executeKnowledgeRestoreRecovery).toHaveBeenCalledExactlyOnceWith(recoveryPlanId, true);
    expect(host.textContent).toContain("完成事务已完成");
  });

  it.each([
    ["none", diagnosis({ state: "none", transactionId: null, phase: null, previousManifestSha256: null,
      projectedManifestSha256: null, canFinalize: false, canRollback: false, libraryAccessBlocked: false,
      snapshotRetained: false })],
    ["changed", diagnosis({ state: "changed", canFinalize: false, canRollback: false })],
    ["rolledBack", diagnosis({ state: "rolledBack", phase: "rolledBack", canFinalize: false, canRollback: false,
      libraryAccessBlocked: false })],
  ] as const)("shows blocked diagnosis %s without recovery controls", async (_state, value) => {
    gateway.inspectKnowledgeRestore.mockResolvedValue(value);
    await act(async () => render()); await click("检查恢复状态");
    expect(host.textContent).toContain("当前诊断没有可准备的恢复操作");
    expect(button("准备完成计划")).toBeUndefined();
    expect(button("准备回滚计划")).toBeUndefined();
    expect(button("准备取消计划")).toBeUndefined();
    expect(gateway.planKnowledgeRestoreRecovery).not.toHaveBeenCalled();
  });

  it.each([
    ["extra key", (plan: KnowledgeRestoreInstallPlan) => { (plan as unknown as Record<string, unknown>).secret = "x"; }],
    ["bad id", (plan: KnowledgeRestoreInstallPlan) => { plan.planId = "not-an-id"; }],
    ["transaction limit", (plan: KnowledgeRestoreInstallPlan) => { plan.transactionLimit = 2 as 1; }],
    ["nested count", (plan: KnowledgeRestoreInstallPlan) => { plan.projection.projection.itemCount = 99; }],
    ["nested limit", (plan: KnowledgeRestoreInstallPlan) => { plan.projection.limits = { ...plan.projection.limits, items: 1 } as unknown as typeof plan.projection.limits; }],
    ["fixed flag", (plan: KnowledgeRestoreInstallPlan) => { plan.importedPermissionsDisabled = false as true; }],
    ["TTL", (plan: KnowledgeRestoreInstallPlan) => { plan.expiresAtEpochMs += 1; }],
  ])("rejects invalid install plan field: %s", async (_label, mutate) => {
    const value = installPlan(); (mutate as (plan: KnowledgeRestoreInstallPlan) => void)(value);
    gateway.planKnowledgeRestoreInstall.mockResolvedValue(value);
    await act(async () => render()); await prepareInstall();
    expect(host.textContent).toContain("安装计划无效");
    expect(button("确认并安装")).toBeUndefined();
    if (value.planId === installPlanId) expect(gateway.discardKnowledgeRestoreInstall).toHaveBeenCalledWith(installPlanId);
  });

  it.each([
    ["transaction id", (value: KnowledgeRestoreDiagnosis) => { value.transactionId = "bad"; }],
    ["manifest hash", (value: KnowledgeRestoreDiagnosis) => { value.previousManifestSha256 = "bad"; }],
    ["phase", (value: KnowledgeRestoreDiagnosis) => { value.phase = "preparing"; }],
    ["action flags", (value: KnowledgeRestoreDiagnosis) => { value.canCancel = true; }],
    ["write flag", (value: KnowledgeRestoreDiagnosis) => { value.filesystemWrites = true as false; }],
  ])("rejects invalid readonly diagnosis field: %s", async (_label, mutate) => {
    const value = diagnosis(); (mutate as (value: KnowledgeRestoreDiagnosis) => void)(value);
    gateway.inspectKnowledgeRestore.mockResolvedValue(value);
    await act(async () => render()); await click("检查恢复状态");
    expect(host.textContent).toContain("读取失败不表示没有未完成事务");
    expect(button("准备完成计划")).toBeUndefined();
  });

  it("allows explicit early cancellation without claiming that a complete snapshot exists", async () => {
    const preparing = diagnosis({ state: "preparing", phase: "preparing", canFinalize: false, canRollback: false,
      canCancel: true, snapshotRetained: false });
    const cancelPlan: KnowledgeRestoreRecoveryPlan = {
      ...recoveryPlan("cancel"), diagnosis: preparing, action: "cancel",
    };
    const cancelReceipt = receipt("cancel"); cancelReceipt.snapshotRetained = false;
    gateway.inspectKnowledgeRestore.mockResolvedValue(preparing);
    gateway.planKnowledgeRestoreRecovery.mockResolvedValue(cancelPlan);
    gateway.executeKnowledgeRestoreRecovery.mockResolvedValue(cancelReceipt);
    await act(async () => render()); await click("检查恢复状态");
    expect(host.textContent).toContain("旧快照：未确认");
    await click("准备取消计划"); await acknowledge(); await click("确认执行恢复操作");
    expect(gateway.executeKnowledgeRestoreRecovery).toHaveBeenCalledWith(recoveryPlanId, true);
    expect(host.textContent).toContain("完整旧快照尚未形成");
    expect(host.textContent).not.toContain("完整旧快照已保留");
  });

  it.each([
    ["plan id", (value: KnowledgeRestoreReceipt) => { value.planId = recoveryPlanId; }],
    ["transaction id", (value: KnowledgeRestoreReceipt) => { value.transactionId = "bad"; }],
    ["previous hash", (value: KnowledgeRestoreReceipt) => { value.previousManifestSha256 = sha("a"); }],
    ["projected hash", (value: KnowledgeRestoreReceipt) => { value.projectedManifestSha256 = sha("a"); }],
    ["future time", (value: KnowledgeRestoreReceipt) => { value.completedAtEpochMs = now + 1; }],
    ["before check", (value: KnowledgeRestoreReceipt) => { value.completedAtEpochMs = now - 1; }],
    ["journal flag", (value: KnowledgeRestoreReceipt) => { value.journalPersisted = false as true; }],
  ])("consumes once and rejects invalid receipt field: %s", async (_label, mutate) => {
    const value = receipt(); (mutate as (value: KnowledgeRestoreReceipt) => void)(value);
    gateway.executeKnowledgeRestoreInstall.mockResolvedValue(value);
    await act(async () => render()); await prepareInstall(); await acknowledge(); await click("确认并安装");
    expect(gateway.executeKnowledgeRestoreInstall).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("可能已写入文件，未确认完成；请检查恢复状态");
    expect(host.textContent).not.toContain("安装已提交");
    expect(button("确认并安装")).toBeUndefined();
  });

  it("copies accepted DTOs and binds execution to the complete validated snapshot", async () => {
    const serverPlan = installPlan();
    const serverReceipt = receipt();
    gateway.planKnowledgeRestoreInstall.mockResolvedValue(serverPlan);
    gateway.executeKnowledgeRestoreInstall.mockResolvedValue(serverReceipt);
    await act(async () => render()); await prepareInstall();
    serverPlan.planId = recoveryPlanId;
    serverPlan.projection.projection.itemCount = 99;
    serverPlan.projection.source.candidate.currentLibrary.manifestSha256 = sha("a");
    await acknowledge(); await click("确认并安装");
    expect(gateway.executeKnowledgeRestoreInstall).toHaveBeenCalledWith(installPlanId, true);
    serverReceipt.projectedManifestSha256 = sha("a");
    await act(async () => render());
    expect(host.textContent).toContain(sha("f"));
    expect(host.textContent).not.toContain(sha("a"));
  });

  it("discards a recognizable late plan through its original gateway after context invalidation", async () => {
    const pending = deferred<KnowledgeRestoreInstallPlan>();
    gateway.planKnowledgeRestoreInstall.mockReturnValue(pending.promise);
    await act(async () => render()); await click("选择候选目录"); await click("准备安装计划");
    const original = gateway;
    await act(async () => render({ refreshKey: 1 }));
    await act(async () => pending.resolve(installPlan()));
    expect(original.discardKnowledgeRestoreInstall).toHaveBeenCalledWith(installPlanId);
    expect(button("确认并安装")).toBeUndefined();
  });

  it("ignores a late receipt after disabling the panel", async () => {
    const pending = deferred<KnowledgeRestoreReceipt>();
    gateway.executeKnowledgeRestoreInstall.mockReturnValue(pending.promise);
    await act(async () => render()); await prepareInstall(); await acknowledge(); await click("确认并安装");
    await act(async () => render({ disabled: true }));
    await act(async () => pending.resolve(receipt()));
    expect(host.textContent).not.toContain("安装已提交");
  });

  it("consumes synchronously to block duplicate execution and old handlers", async () => {
    const pending = deferred<KnowledgeRestoreReceipt>();
    gateway.executeKnowledgeRestoreInstall.mockReturnValue(pending.promise);
    await act(async () => render()); await prepareInstall(); await acknowledge();
    const invoke = handler(button("确认并安装")!);
    await act(async () => { invoke(); invoke(); });
    expect(gateway.executeKnowledgeRestoreInstall).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(receipt()));
    await act(async () => invoke());
    expect(gateway.executeKnowledgeRestoreInstall).toHaveBeenCalledTimes(1);
  });

  it("expires on wall time before an old confirmation callback can execute", async () => {
    await act(async () => render()); await prepareInstall(); await acknowledge();
    const invoke = handler(button("确认并安装")!);
    vi.setSystemTime(now + 300000);
    await act(async () => invoke());
    expect(gateway.executeKnowledgeRestoreInstall).not.toHaveBeenCalled();
    expect(gateway.discardKnowledgeRestoreInstall).toHaveBeenCalledWith(installPlanId);
    expect(host.textContent).toContain("计划已过期");
  });

  it("reports an unknown write outcome without claiming safety and keeps explicit inspection available", async () => {
    gateway.executeKnowledgeRestoreInstall.mockRejectedValue(new Error("ambiguous"));
    await act(async () => render()); await prepareInstall(); await acknowledge(); await click("确认并安装");
    expect(host.textContent).toContain("可能已写入文件，未确认完成；请检查恢复状态");
    expect(host.textContent).not.toContain("当前资料库不变");
    expect(host.textContent).not.toContain("安装已提交");
    expect(button("检查恢复状态")!.disabled).toBe(false);
    expect(gateway.inspectKnowledgeRestore).not.toHaveBeenCalled();
    await click("检查恢复状态");
    expect(gateway.inspectKnowledgeRestore).toHaveBeenCalledTimes(1);
  });
});
