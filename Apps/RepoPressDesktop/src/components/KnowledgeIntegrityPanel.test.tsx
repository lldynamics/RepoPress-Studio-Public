import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { KnowledgeIntegrityGateway, KnowledgeIntegrityReport, KnowledgeIntegrityRecheck } from "../contracts/knowledgeIntegrity";
import { KNOWLEDGE_INTEGRITY_EXCLUSIONS, KNOWLEDGE_INTEGRITY_LIMITS } from "../contracts/knowledgeIntegrity";
import { KnowledgeIntegrityPanel } from "./KnowledgeIntegrityPanel";

const clock = 1_700_000_000_000;
const body = { kind: "body" as const, referenceCount: 3, uniqueFiles: 2, verified: 2, missing: 0, unsafe: 0, unreadable: 0, invalid: 0, changed: 0, omitted: 0, verifiedBytes: 300 };
const archive = { kind: "archive" as const, referenceCount: 2, uniqueFiles: 2, verified: 2, missing: 0, unsafe: 0, unreadable: 0, invalid: 0, changed: 0, omitted: 0, verifiedBytes: 500 };
const bodyAtFileLimit = { kind: "body" as const, referenceCount: 1025, uniqueFiles: 1025, verified: 1024, missing: 0, unsafe: 0, unreadable: 0, invalid: 0, changed: 0, omitted: 1, verifiedBytes: 300 };
const report = (overrides: Partial<KnowledgeIntegrityReport> = {}): KnowledgeIntegrityReport => ({
  reportId: "11111111-1111-4111-8111-111111111111", schemaVersion: 1, scope: "applicationKnowledgeReferences", checkedAtEpochMs: clock,
  expiresAtEpochMs: clock + 300_000, status: "checked", manifestState: "verified", manifestSchemaVersion: 4, manifestSha256: "a".repeat(64), itemCount: 3, revisionCount: 3,
  resources: [body, archive], archiveMissingResources: 0, archiveTruncated: 0, archiveUnknownCompleteness: 0, issues: [], exclusions: [...KNOWLEDGE_INTEGRITY_EXCLUSIONS], limits: KNOWLEDGE_INTEGRITY_LIMITS,
  allReferencedFilesVerified: true, consistentSnapshot: false, backupReady: false, ...overrides,
});
const recheck = (comparison: KnowledgeIntegrityRecheck["comparison"], next = report({ reportId: "22222222-2222-4222-8222-222222222222" })): KnowledgeIntegrityRecheck => ({ report: next, comparison });
type Gateway = { [K in keyof KnowledgeIntegrityGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof KnowledgeIntegrityPanel>> = {}) { await act(async () => root.render(createElement(KnowledgeIntegrityPanel, { gateway: gateway as unknown as KnowledgeIntegrityGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function inspect() { const action = button(/明确检查资料引用/); expect(action).toBeDefined(); await act(async () => action!.click()); await settle(); await settle(); }

describe("KnowledgeIntegrityPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(clock); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { inspectKnowledgeIntegrity: vi.fn(async () => report()), recheckKnowledgeIntegrity: vi.fn(async () => recheck("unchanged")), discardKnowledgeIntegrity: vi.fn(async () => undefined) } as unknown as Gateway; });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("is lazy, exposes stable Chinese labels, and renders counts/issues without sensitive fixtures or action leakage", async () => {
    await render(); await settle();
    expect(host.textContent).toContain("资料引用完整性预检"); expect(button(/明确检查资料引用/)).toBeDefined();
    expect(gateway.inspectKnowledgeIntegrity).not.toHaveBeenCalled();
    await inspect();
    expect(gateway.inspectKnowledgeIntegrity).toHaveBeenCalledTimes(1); expect(host.textContent).toContain("3"); expect(host.textContent).toContain("2");
    expect(host.textContent).not.toMatch(/password|secret|fixture-secret/);
    expect(button(/导出|清理|修复|重试/)).toBeUndefined();
  });

  it.each([
    ["scope", { scope: "wrong" as never }], ["manifest schema", { manifestSchemaVersion: 3 }], ["schema version", { schemaVersion: 4 }],
    ["flags", { consistentSnapshot: true, backupReady: true }], ["TTL", { expiresAtEpochMs: clock + 299_999 }], ["expired", { checkedAtEpochMs: clock - 300_001, expiresAtEpochMs: clock - 1 }],
    ["bad exclusions", { exclusions: [KNOWLEDGE_INTEGRITY_EXCLUSIONS[0], KNOWLEDGE_INTEGRITY_EXCLUSIONS[0]] }], ["bad limits", { limits: { ...KNOWLEDGE_INTEGRITY_LIMITS, resourceFiles: 1 } }],
    ["duplicate issues", { issues: ["missingFile", "missingFile"] as never }], ["bad SHA", { manifestSha256: "Z".repeat(64) }], ["unsafe integer", { itemCount: Number.MAX_SAFE_INTEGER + 1 }],
    ["NaN", { revisionCount: Number.NaN }], ["count sums", { resources: [{ ...body, verified: 1 }, archive] }], ["body references", { resources: [{ ...body, referenceCount: 2 }, archive] }],
    ["archive references", { resources: [{ ...body }, { ...archive, referenceCount: 4 }] }], ["archive risk without issue", { archiveMissingResources: 1 }], ["unknown resource", { resources: [{ ...body }, { ...archive, kind: "other" as never }] }],
  ])("rejects malformed %s reports without presenting a healthy result", async (_name, invalid) => {
    gateway.inspectKnowledgeIntegrity.mockResolvedValueOnce(report(invalid as Partial<KnowledgeIntegrityReport>)); await render(); await inspect();
    expect(host.textContent).toMatch(/无法|失败|无效/); expect(host.textContent).not.toContain("检查完成"); expect(button(/明确重新核对资料引用/)).toBeUndefined();
  });

  it.each([
    ["limits null", { limits: null as never }],
    ["limits missing", { limits: undefined as never }],
    ["resources null", { resources: null as never }],
    ["resources missing", { resources: undefined as never }],
  ])("rejects %s and discards the identifiable invalid report", async (_name, invalid) => {
    gateway.inspectKnowledgeIntegrity.mockResolvedValueOnce(report(invalid as Partial<KnowledgeIntegrityReport>)); await render(); await inspect();
    expect(host.textContent).toMatch(/无法|失败|无效/);
    expect(gateway.discardKnowledgeIntegrity).toHaveBeenCalledWith(report().reportId);
  });

  it.each([
    ["missing", { status: "partial", manifestState: "missing", manifestSchemaVersion: null, itemCount: null, revisionCount: null, resources: [], archiveMissingResources: 0, archiveTruncated: 0, archiveUnknownCompleteness: 0, issues: ["manifestMissing"] as never, allReferencedFilesVerified: false }],
    ["partial archive", { status: "partial", archiveMissingResources: 1, issues: ["missingFile"] as never, allReferencedFilesVerified: false, resources: [{ ...body }, { ...archive, missing: 1, verified: 1 }] }],
    ["truncated archive", { status: "partial", archiveTruncated: 1, issues: ["incompleteArchive"] as never, allReferencedFilesVerified: false }],
    ["unknown archive", { status: "partial", archiveUnknownCompleteness: 1, issues: ["unknownArchiveCompleteness"] as never, allReferencedFilesVerified: false }],
    ["file limit", { status: "partial", resources: [bodyAtFileLimit, archive], issues: ["fileLimit"] as never, allReferencedFilesVerified: false }],
  ])("states %s archive/manifest completeness explicitly", async (_name, invalid) => {
    gateway.inspectKnowledgeIntegrity.mockResolvedValueOnce(report(invalid as Partial<KnowledgeIntegrityReport>)); await render(); await inspect();
    expect(host.textContent).toMatch(/部分|不完整|缺失|未知|无法/); expect(host.textContent).not.toContain("全部引用已验证");
  });

  it("supports explicit recheck/discard, consumes old rechecks, and requires a distinct valid receipt", async () => {
    await render(); await inspect(); const check = button(/明确重新核对资料引用/); expect(check).toBeDefined(); await act(async () => check!.click()); await settle(); await settle();
    expect(gateway.recheckKnowledgeIntegrity).toHaveBeenCalledWith(report().reportId); expect(host.textContent).toMatch(/未变化|unchanged|核对/);
    expect(button(/明确重新核对资料引用/)).toBeDefined(); await act(async () => button(/丢弃资料预检报告/)!.click()); await settle(); expect(gateway.discardKnowledgeIntegrity).toHaveBeenCalledWith("22222222-2222-4222-8222-222222222222");
    expect(button(/明确重新核对资料引用/)).toBeUndefined();
  });

  it("discards the previous report on repeated inspect and blocks a captured old DOM recheck", async () => {
    const next = report({ reportId: "33333333-3333-4333-8333-333333333333" });
    gateway.inspectKnowledgeIntegrity.mockResolvedValueOnce(report()).mockResolvedValueOnce(next);
    await render(); await inspect();
    const oldRecheck = button(/明确重新核对资料引用/)!;
    await act(async () => button(/明确检查资料引用/)!.click()); await settle(); await settle();
    expect(gateway.discardKnowledgeIntegrity).toHaveBeenCalledWith(report().reportId);
    expect(gateway.inspectKnowledgeIntegrity).toHaveBeenCalledTimes(2);
    const callsBefore = gateway.recheckKnowledgeIntegrity.mock.calls.length;
    await act(async () => { button(/丢弃资料预检报告/)!.click(); oldRecheck.click(); }); await settle();
    expect(gateway.recheckKnowledgeIntegrity.mock.calls.length).toBe(callsBefore);
  });

  it("discards a late fresh recheck through the original gateway after refresh", async () => {
    let resolve!: (value: KnowledgeIntegrityRecheck) => void;
    gateway.recheckKnowledgeIntegrity.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
    await render(); await inspect(); await act(async () => button(/明确重新核对资料引用/)!.click());
    const old = gateway; await render({ refreshKey: 9 }); resolve(recheck("changed")); await settle();
    expect(old.discardKnowledgeIntegrity).toHaveBeenCalledWith("22222222-2222-4222-8222-222222222222");
    expect(host.textContent).not.toContain("状态已变化");
  });

  it.each([
    ["same report id", recheck("changed", report())],
    ["unknown comparison", { report: report({ reportId: "22222222-2222-4222-8222-222222222222" }), comparison: "unknown" as never }],
    ["malformed new report", { report: report({ reportId: "22222222-2222-4222-8222-222222222222", manifestSha256: "Z".repeat(64) }), comparison: "changed" as const }],
  ])("consumes and rejects %s recheck receipts", async (_name, invalid) => {
    gateway.recheckKnowledgeIntegrity.mockResolvedValueOnce(invalid as KnowledgeIntegrityRecheck); await render(); await inspect();
    await act(async () => button(/明确重新核对资料引用/)!.click()); await settle(); await settle();
    expect(gateway.recheckKnowledgeIntegrity).toHaveBeenCalledTimes(1); expect(host.textContent).toMatch(/失败|重新检查/); expect(button(/明确重新核对资料引用/)).toBeUndefined();
    expect(gateway.discardKnowledgeIntegrity).toHaveBeenCalledWith((invalid as KnowledgeIntegrityRecheck).report.reportId);
  });

  it("rejects unchanged or changed comparisons for a partial fresh report and discards it", async () => {
    const partial = report({ reportId: "33333333-3333-4333-8333-333333333333", status: "partial", allReferencedFilesVerified: false, issues: ["missingFile"], resources: [body, { ...archive, missing: 1, verified: 1 }] });
    gateway.inspectKnowledgeIntegrity.mockResolvedValueOnce(partial);
    gateway.recheckKnowledgeIntegrity.mockResolvedValueOnce({ report: partial, comparison: "unchanged" });
    await render(); await inspect(); await act(async () => button(/明确重新核对资料引用/)!.click()); await settle(); await settle();
    expect(host.textContent).toMatch(/失败|重新检查/); expect(gateway.discardKnowledgeIntegrity).toHaveBeenCalledWith(partial.reportId);
  });

  it("discards on refresh/disabled/unmount and guards late and rejected responses through original gateway", async () => {
    let resolve!: (value: KnowledgeIntegrityReport) => void; gateway.inspectKnowledgeIntegrity.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); const old = gateway;
    await render(); await act(async () => button(/明确检查资料引用/)!.click()); await render({ refreshKey: 1 }); resolve(report()); await settle(); expect(old.discardKnowledgeIntegrity).toHaveBeenCalledWith(report().reportId);
    gateway.inspectKnowledgeIntegrity.mockRejectedValueOnce(new Error("unavailable")); await render({ enabled: true }); await inspect(); expect(host.textContent).toMatch(/无法|失败|不可用/); await render({ enabled: false });
    expect(host.textContent).not.toContain("全部引用已验证"); await act(async () => root.unmount());
  });
});
