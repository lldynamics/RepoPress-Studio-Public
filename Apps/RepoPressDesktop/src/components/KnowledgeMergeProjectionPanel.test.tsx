import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  KNOWLEDGE_MERGE_PROJECTION_LIMITS, type KnowledgeMergeProjectionGateway,
  type KnowledgeMergeProjectionPlan, type KnowledgeMergeProjectionReceipt,
} from "../contracts/knowledgeMergeProjection";
import { KNOWLEDGE_CANDIDATE_CHECK_LIMITS } from "../contracts/knowledgeCandidateCheck";
import { KnowledgeMergeProjectionPanel } from "./KnowledgeMergeProjectionPanel";

const now = 1700000000000;
const stage = "11111111-1111-4111-8111-111111111111";
const candidatePath = "/private/repopress-knowledge-stage-" + stage;
const sha = (c: string) => c.repeat(64);
function plan(): KnowledgeMergeProjectionPlan {
  return {
    schemaVersion: 1, scope: "knowledgeMergeProjection", planId: "44444444-4444-4444-8444-444444444444",
    source: {
      schemaVersion: 1, scope: "knowledgeRestoreQualification", planId: "22222222-2222-4222-8222-222222222222",
      targetScope: "currentAppKnowledgeLibrary",
      candidate: {
        reportId: "33333333-3333-4333-8333-333333333333", candidatePath, stagePlanId: stage,
        schemaVersion: 1, scope: "selectedKnowledgeCandidate", sourcePackageSha256: sha("a"),
        manifestSha256: sha("b"), candidateInventorySha256: sha("c"), candidateFileCount: 4,
        candidateByteSize: 900, itemCount: 2, revisionCount: 2, folderCount: 0,
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
      archiveByteSize: 0, importedItems: 1, importedFolders: 0, resetPermissionItems: 1, completedOperationsExcluded: true },
    limits: KNOWLEDGE_MERGE_PROJECTION_LIMITS, privacyMode: "disableImportedPermissions",
    privacyResetAcknowledgementRequired: true, currentPermissionsPreserved: true, sourcePermissionsCopied: false,
    projectedManifestValidated: true, filesystemWrites: false, currentLibraryChanged: false,
    restoreReady: false, consistentSnapshot: false, checkedAtEpochMs: now, expiresAtEpochMs: now + 300000,
  };
}
function receipt(): KnowledgeMergeProjectionReceipt {
  return {
    planId: plan().planId, projectionManifestSha256: sha("f"), itemCount: 2, revisionCount: 2, folderCount: 0,
    importedItems: 1, importedFolders: 0, resetPermissionItems: 1, privacyResetAcknowledged: true,
    importedPermissionsDisabled: true, currentPermissionsPreserved: true, sourcePermissionsCopied: false,
    validatedInMemory: true, filesystemWrites: false, currentLibraryChanged: false, restoreReady: false,
    consistentSnapshot: false, completedAtEpochMs: now,
  };
}
function blocked(reason: KnowledgeMergeProjectionPlan["projection"]["reason"]): KnowledgeMergeProjectionPlan {
  const p = plan();
  p.projectedManifestValidated = false;
  p.projection = {
    state: "blocked", reason, manifestSha256: null, manifestByteSize: null, itemCount: null,
    revisionCount: null, folderCount: null, fileCount: null, resourceByteSize: null, bodyByteSize: null,
    archiveByteSize: null, importedItems: null, importedFolders: null, resetPermissionItems: null,
    completedOperationsExcluded: true,
  };
  return p;
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(r => { resolve = r; });
  return { promise, resolve };
}
type G = { [K in keyof KnowledgeMergeProjectionGateway]: ReturnType<typeof vi.fn> };
let gateway: G; let host: HTMLDivElement; let root: ReturnType<typeof createRoot>;
const render = (props: Partial<React.ComponentProps<typeof KnowledgeMergeProjectionPanel>> = {}) =>
  root.render(createElement(KnowledgeMergeProjectionPanel, {
    gateway: gateway as unknown as KnowledgeMergeProjectionGateway, enabled: true, ...props,
  }));
const button = (label: string) => [...host.querySelectorAll("button")].find(b => b.textContent === label);
const click = async (label: string) => { await act(async () => { button(label)!.click(); }); };
const generate = async () => { await click("选择候选目录"); await click("生成内存投影"); };
const consent = async () => {
  await act(async () => { (host.querySelector("input[type=checkbox]") as HTMLInputElement).click(); });
};
function handler(element: Element, name: "onClick" | "onChange") {
  const key = Object.keys(element).find(k => k.startsWith("__reactProps"))!;
  return (element as unknown as Record<string, Record<string, (event?: unknown) => void>>)[key][name];
}

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
describe("KnowledgeMergeProjectionPanel", () => {
  beforeEach(() => {
    vi.useFakeTimers(); vi.setSystemTime(now);
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      selectKnowledgeCandidateDirectory: vi.fn(async () => candidatePath),
      planKnowledgeMergeProjection: vi.fn(async () => plan()),
      preflightKnowledgeMergeProjection: vi.fn(async () => receipt()),
      discardKnowledgeMergeProjection: vi.fn(async () => undefined),
    };
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("requires explicit selection and privacy acknowledgement for the imported permission reset", async () => {
    await act(async () => render());
    expect(button("生成内存投影")).toBeUndefined();
    await generate();
    expect(button("确认并做内存复验")!.disabled).toBe(true);
    expect(gateway.preflightKnowledgeMergeProjection).not.toHaveBeenCalled();
    expect(host.textContent).toContain("关闭原有权限的新增资料项：1");
    expect(host.textContent).toContain("当前资料权限保留");
    await consent(); await click("确认并做内存复验");
    expect(gateway.preflightKnowledgeMergeProjection).toHaveBeenCalledExactlyOnceWith(plan().planId, true);
    expect(host.textContent).toContain("内存复验完成");
    expect(button("确认并做内存复验")).toBeUndefined();
  });

  it.each(["folderNameCollision", "capacityExceeded", "manifestInvalid", "referenceMismatch"] as const)(
    "displays blocked %s without confirmation controls", async reason => {
      gateway.planKnowledgeMergeProjection.mockResolvedValue(blocked(reason));
      await act(async () => render()); await generate();
      expect(host.textContent).toContain("投影摘要");
      expect(host.querySelector("input[type=checkbox]")).toBeNull();
      expect(button("确认并做内存复验")).toBeUndefined();
      expect(gateway.preflightKnowledgeMergeProjection).not.toHaveBeenCalled();
    },
  );

  it("blocks unavailable current resource evidence with all projection counts unknown", async () => {
    const p = blocked("qualificationBlocked");
    p.source.currentResources = { state: "unsafe", fileCount: null, byteSize: null, inventorySha256: null,
      unreferencedFilesVerified: false, externalReferencesVerified: false };
    p.source.qualification = { state: "blocked", reason: "currentResourcesUnavailable", addItems: null,
      retainItems: null, skipCandidateItems: null, addFolders: null, retainFolders: null, skipCandidateFolders: null };
    gateway.planKnowledgeMergeProjection.mockResolvedValue(p);
    await act(async () => render()); await generate();
    expect(host.textContent).toContain("当前来源证据或身份策略不满足要求");
    expect(button("确认并做内存复验")).toBeUndefined();
  });

  it.each([
    ["resource sum", (p: KnowledgeMergeProjectionPlan) => { p.projection.archiveByteSize = 1; }],
    ["revisions below items", (p: KnowledgeMergeProjectionPlan) => { p.projection.revisionCount = 1; }],
    ["too many resource refs", (p: KnowledgeMergeProjectionPlan) => { p.projection.fileCount = 10; }],
    ["empty manifest", (p: KnowledgeMergeProjectionPlan) => { p.projection.manifestByteSize = 0; }],
    ["permission reset count", (p: KnowledgeMergeProjectionPlan) => { p.projection.resetPermissionItems = 2; }],
    ["fixed flag", (p: KnowledgeMergeProjectionPlan) => { (p as unknown as Record<string, unknown>).restoreReady = true; }],
    ["source count", (p: KnowledgeMergeProjectionPlan) => { p.source.qualification.addItems = 2; }],
    ["limit", (p: KnowledgeMergeProjectionPlan) => { p.limits = { ...p.limits, resourceBytes: 1 } as typeof p.limits; }],
  ])("rejects malformed %s and discards the server plan", async (_name, mutate) => {
    const p = plan(); (mutate as (p: KnowledgeMergeProjectionPlan) => void)(p);
    gateway.planKnowledgeMergeProjection.mockResolvedValue(p);
    await act(async () => render()); await generate();
    expect(host.textContent).toContain("投影计划无效");
    expect(gateway.discardKnowledgeMergeProjection).toHaveBeenCalledWith(p.planId);
    expect(button("确认并做内存复验")).toBeUndefined();
  });

  it.each([
    ["future time", (r: KnowledgeMergeProjectionReceipt) => { r.completedAtEpochMs = now + 1; }],
    ["before capture", (r: KnowledgeMergeProjectionReceipt) => { r.completedAtEpochMs = now - 1; }],
    ["wrong hash", (r: KnowledgeMergeProjectionReceipt) => { r.projectionManifestSha256 = sha("a"); }],
    ["wrong count", (r: KnowledgeMergeProjectionReceipt) => { r.itemCount = 99; }],
    ["privacy flag", (r: KnowledgeMergeProjectionReceipt) => { (r as unknown as Record<string, unknown>).importedPermissionsDisabled = false; }],
  ])("consumes and rejects a receipt with %s", async (_name, mutate) => {
    const r = receipt(); (mutate as (r: KnowledgeMergeProjectionReceipt) => void)(r);
    gateway.preflightKnowledgeMergeProjection.mockResolvedValue(r);
    await act(async () => render()); await generate(); await consent(); await click("确认并做内存复验");
    expect(host.textContent).toContain("内存复验失败");
    expect(button("确认并做内存复验")).toBeUndefined();
    expect(gateway.preflightKnowledgeMergeProjection).toHaveBeenCalledTimes(1);
  });

  it("copies the complete validated plan so IPC object mutations cannot alter acknowledgement or receipt binding", async () => {
    const p = plan();
    gateway.planKnowledgeMergeProjection.mockResolvedValue(p);
    await act(async () => render()); await generate();
    p.projection.manifestSha256 = sha("a"); p.projection.itemCount = 99;
    p.source.candidate.manifestSha256 = sha("a");
    (p as unknown as Record<string, unknown>).filesystemWrites = true;
    await consent(); await click("确认并做内存复验");
    expect(host.textContent).toContain("内存复验完成");
    expect(host.textContent).toContain("资料项：2");
  });

  it("copies receipts before rendering", async () => {
    const r = receipt(); gateway.preflightKnowledgeMergeProjection.mockResolvedValue(r);
    await act(async () => render()); await generate(); await consent(); await click("确认并做内存复验");
    r.itemCount = 99;
    await act(async () => render());
    expect(host.textContent).toContain("资料项：2");
    expect(host.textContent).not.toContain("资料项：99");
  });

  it("rejects expired consent even before the timer rerenders the panel", async () => {
    await act(async () => render()); await generate(); await consent();
    const invoke = handler(button("确认并做内存复验")!, "onClick");
    vi.setSystemTime(now + 300000);
    await act(async () => invoke());
    expect(gateway.preflightKnowledgeMergeProjection).not.toHaveBeenCalled();
  });

  it("expires and discards plans through the timer", async () => {
    await act(async () => render()); await generate();
    await act(async () => { vi.advanceTimersByTime(300000); });
    expect(host.textContent).toContain("投影计划已过期");
    expect(gateway.discardKnowledgeMergeProjection).toHaveBeenCalledWith(plan().planId);
  });

  it("prevents same-tick duplicate preflight calls and reuse of the old event", async () => {
    const pending = deferred<KnowledgeMergeProjectionReceipt>();
    gateway.preflightKnowledgeMergeProjection.mockReturnValue(pending.promise);
    await act(async () => render()); await generate(); await consent();
    const invoke = handler(button("确认并做内存复验")!, "onClick");
    await act(async () => { invoke(); invoke(); });
    expect(gateway.preflightKnowledgeMergeProjection).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(receipt()));
    await act(async () => invoke());
    expect(gateway.preflightKnowledgeMergeProjection).toHaveBeenCalledTimes(1);
  });

  it("rejects a delayed receipt once the plan lifetime has elapsed", async () => {
    const pending = deferred<KnowledgeMergeProjectionReceipt>();
    gateway.preflightKnowledgeMergeProjection.mockReturnValue(pending.promise);
    await act(async () => render()); await generate(); await consent(); await click("确认并做内存复验");
    vi.setSystemTime(now + 300000);
    await act(async () => pending.resolve(receipt()));
    expect(host.textContent).toContain("内存复验失败");
  });

  it("invalidates strategy and rejects the old confirmation callback", async () => {
    await act(async () => render()); await generate(); await consent();
    const invoke = handler(button("确认并做内存复验")!, "onClick");
    await act(async () => {
      const select = host.querySelector("select")!;
      select.value = "keepCurrentIdentities"; select.dispatchEvent(new Event("change", { bubbles: true }));
    });
    await act(async () => invoke());
    expect(gateway.preflightKnowledgeMergeProjection).not.toHaveBeenCalled();
    expect(button("确认并做内存复验")).toBeUndefined();
    const p = plan(); p.source.strategy = "keepCurrentIdentities";
    gateway.planKnowledgeMergeProjection.mockResolvedValue(p);
    await click("生成内存投影");
    expect(button("确认并做内存复验")!.disabled).toBe(true);
    expect(gateway.planKnowledgeMergeProjection).toHaveBeenLastCalledWith(candidatePath, "keepCurrentIdentities");
  });

  it.each(["disabled", "gateway", "refresh"] as const)("rejects old callbacks after %s context changes", async kind => {
    await act(async () => render()); await generate(); await consent();
    const confirm = handler(button("确认并做内存复验")!, "onClick");
    const generateOld = handler(button("生成内存投影")!, "onClick");
    const alternate = { ...gateway, preflightKnowledgeMergeProjection: vi.fn() };
    await act(async () => render(kind === "disabled" ? { disabled: true }
      : kind === "gateway" ? { gateway: alternate as unknown as KnowledgeMergeProjectionGateway } : { refreshKey: 1 }));
    await act(async () => { confirm(); generateOld(); });
    expect(gateway.preflightKnowledgeMergeProjection).not.toHaveBeenCalled();
    expect(gateway.planKnowledgeMergeProjection).toHaveBeenCalledTimes(1);
    expect(alternate.preflightKnowledgeMergeProjection).not.toHaveBeenCalled();
  });

  it("discards a late plan through its original gateway", async () => {
    const pending = deferred<KnowledgeMergeProjectionPlan>();
    gateway.planKnowledgeMergeProjection.mockReturnValue(pending.promise);
    await act(async () => render()); await click("选择候选目录"); await click("生成内存投影");
    const oldGateway = gateway;
    await act(async () => render({ enabled: false }));
    await act(async () => pending.resolve(plan()));
    expect(oldGateway.discardKnowledgeMergeProjection).toHaveBeenCalledWith(plan().planId);
    expect(button("确认并做内存复验")).toBeUndefined();
  });

  it("ignores late receipts after the panel is disabled", async () => {
    const pending = deferred<KnowledgeMergeProjectionReceipt>();
    gateway.preflightKnowledgeMergeProjection.mockReturnValue(pending.promise);
    await act(async () => render()); await generate(); await consent(); await click("确认并做内存复验");
    await act(async () => render({ disabled: true }));
    await act(async () => pending.resolve(receipt()));
    expect(host.textContent).not.toContain("内存复验完成");
    expect(gateway.discardKnowledgeMergeProjection).toHaveBeenCalledWith(plan().planId);
  });

  it("ignores late selection and never starts a hidden plan", async () => {
    const pending = deferred<string | null>();
    gateway.selectKnowledgeCandidateDirectory.mockReturnValue(pending.promise);
    await act(async () => render()); await click("选择候选目录");
    await act(async () => render({ enabled: false }));
    await act(async () => pending.resolve(candidatePath));
    expect(button("生成内存投影")).toBeUndefined();
    expect(gateway.planKnowledgeMergeProjection).not.toHaveBeenCalled();
  });

  it("cancels explicitly and resets acknowledgement before the next plan", async () => {
    await act(async () => render()); await generate(); await consent(); await click("取消投影");
    expect(gateway.discardKnowledgeMergeProjection).toHaveBeenCalledWith(plan().planId);
    await click("生成内存投影");
    expect(button("确认并做内存复验")!.disabled).toBe(true);
  });
});
