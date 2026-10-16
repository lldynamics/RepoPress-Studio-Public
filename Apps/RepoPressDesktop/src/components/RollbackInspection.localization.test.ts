import { act, createElement, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type { RollbackCandidateGateway, RollbackCandidatePlan } from "../contracts/rollbackCandidate";
import type { RollbackChangePreview, RollbackChangePreviewGateway } from "../contracts/rollbackChangePreview";
import type { RollbackQualificationGateway, RollbackQualificationPlan, RollbackQualificationReport } from "../contracts/rollbackQualification";
import { I18nProvider } from "../i18n/i18n";
import { RollbackCandidatePanel } from "./RollbackCandidatePanel";
import { RollbackChangePreviewPanel } from "./RollbackChangePreviewPanel";
import { RollbackQualificationPanel } from "./RollbackQualificationPanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const sha = (letter: string) => letter.repeat(40);
const checkedAt = Date.UTC(2026, 0, 1, 2, 3, 4);
const entry: ReleaseLedgerEntry = {
  source: "gitPush",
  recordId: "push-原文",
  revision: 4,
  operation: "push",
  branch: "分支-原文",
  targetBranch: null,
  expectedSha: sha("a"),
  remoteUrl: "https://example.test/原文.git",
  startedAtEpochMs: 1_000,
  checkedAtEpochMs: 2_000,
  status: "pushVerified",
};

let host: HTMLDivElement;
let root: Root;

beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  vi.useRealTimers();
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function render(locale: "zh-CN" | "en-US", child: ReactElement) {
  act(() => root.render(createElement(I18nProvider, { locale, children: child })));
}

async function settle() {
  await act(async () => { await Promise.resolve(); });
}

function button(label: string): HTMLButtonElement {
  const found = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);
  if (!found) throw new Error(`Missing button: ${label}`);
  return found;
}

function qualificationPlan(overrides: Partial<RollbackQualificationPlan> = {}): RollbackQualificationPlan {
  return {
    sessionId: "session",
    recordId: entry.recordId,
    revision: entry.revision,
    branch: entry.branch,
    remoteUrl: entry.remoteUrl,
    expectedSha: entry.expectedSha,
    parentSha: sha("b"),
    localStatus: "candidate",
    blockers: [],
    planId: "计划-原文",
    expiresAtEpochMs: Date.now() + 60_000,
    ...overrides,
  };
}

function qualificationReport(plan: RollbackQualificationPlan): RollbackQualificationReport {
  return {
    sessionId: plan.sessionId,
    recordId: plan.recordId,
    revision: plan.revision,
    branch: plan.branch,
    remoteUrl: plan.remoteUrl,
    expectedSha: plan.expectedSha,
    parentSha: plan.parentSha,
    status: "qualified",
    blockers: [],
    remoteSha: plan.expectedSha,
    checkedAtEpochMs: checkedAt,
  };
}

function changePreview(): RollbackChangePreview {
  return {
    sessionId: "session",
    recordId: entry.recordId,
    revision: entry.revision,
    branch: entry.branch,
    remoteUrl: entry.remoteUrl,
    expectedSha: entry.expectedSha,
    parentSha: sha("b"),
    status: "complete",
    changes: [{
      path: "文档/原文.md",
      action: "replace",
      published: { mode: "100644", objectId: sha("c"), byteSize: 10 },
      restore: { mode: "100644", objectId: sha("d"), byteSize: 11 },
      verification: "verified",
      issues: [],
    }],
    omittedPaths: 0,
    blockers: [],
    warnings: [],
    summary: { visible: 1, deleteFiles: 0, restoreFiles: 0, replaceFiles: 1, unsupportedFiles: 0, verifiedFiles: 1 },
    checkedAtEpochMs: checkedAt,
  };
}

function candidatePlan(overrides: Partial<RollbackCandidatePlan> = {}): RollbackCandidatePlan {
  return {
    sessionId: "session",
    recordId: entry.recordId,
    revision: entry.revision,
    branch: entry.branch,
    remoteUrl: entry.remoteUrl,
    expectedSha: entry.expectedSha,
    parentSha: sha("b"),
    status: "ready",
    planId: "123e4567-e89b-12d3-a456-426614174000",
    sourceTreeSha: sha("c"),
    targetTreeSha: sha("d"),
    changedPaths: 2,
    targetFiles: 1,
    blockers: [],
    checkedAtEpochMs: Date.now(),
    expiresAtEpochMs: Date.now() + 60_000,
    ...overrides,
  };
}

describe("rollback inspection localization", () => {
  it("preserves a qualification plan and its in-flight query through zh/en/zh changes", async () => {
    const planRequest = deferred<RollbackQualificationPlan>();
    const reportRequest = deferred<RollbackQualificationReport>();
    const frozenPlan = qualificationPlan();
    const gateway: RollbackQualificationGateway = {
      planRollbackQualification: vi.fn(() => planRequest.promise),
      checkRollbackQualification: vi.fn(() => reportRequest.promise),
    };
    const view = () => createElement(RollbackQualificationPanel, { gateway, sessionId: "session", entry, enabled: true });

    render("zh-CN", view());
    await act(async () => button("审阅回滚条件").click());
    render("en-US", view());
    expect(gateway.planRollbackQualification).toHaveBeenCalledTimes(1);
    expect(host.querySelector("section")?.getAttribute("aria-label")).toBe("Read-only rollback qualification review");
    await act(async () => planRequest.resolve(frozenPlan));
    expect(host.textContent).toContain(entry.branch);
    expect(host.textContent).toContain(entry.remoteUrl);
    expect(host.textContent).toContain(entry.expectedSha);

    await act(async () => button("Confirm read-only remote-head query").click());
    render("zh-CN", view());
    render("en-US", view());
    expect(gateway.checkRollbackQualification).toHaveBeenCalledTimes(1);
    expect(gateway.checkRollbackQualification).toHaveBeenCalledWith("session", frozenPlan.planId);
    await act(async () => reportRequest.resolve(qualificationReport(frozenPlan)));
    expect(host.textContent).toContain("Basic conditions met at query time");
    expect(host.textContent).toContain(new Date(checkedAt).toLocaleString("en-US"));

    render("zh-CN", view());
    expect(host.textContent).toContain("查询时基础条件满足");
    expect(host.textContent).toContain(new Date(checkedAt).toLocaleString("zh-CN"));
    expect(gateway.planRollbackQualification).toHaveBeenCalledTimes(1);
    expect(gateway.checkRollbackQualification).toHaveBeenCalledTimes(1);
  });

  it("keeps preview literals while localizing controls and rejects a stale response", async () => {
    const first = deferred<RollbackChangePreview>();
    const second = deferred<RollbackChangePreview>();
    const gateway: RollbackChangePreviewGateway = {
      inspectRollbackChanges: vi.fn()
        .mockImplementationOnce(() => first.promise)
        .mockImplementationOnce(() => second.promise),
    };
    const view = (sessionId = "session") => createElement(RollbackChangePreviewPanel, { gateway, sessionId, entry, enabled: true });

    render("zh-CN", view());
    await act(async () => button("预览单提交逆向变更").click());
    render("en-US", view());
    expect(gateway.inspectRollbackChanges).toHaveBeenCalledTimes(1);
    await act(async () => first.resolve(changePreview()));
    expect(host.textContent).toContain("Preview complete");
    expect(host.textContent).toContain("Replace");
    expect(host.textContent).toContain("Verified");
    expect(host.textContent).toContain("文档/原文.md");
    expect(host.textContent).toContain(entry.expectedSha);
    expect(host.textContent).toContain(new Date(checkedAt).toLocaleString("en-US"));

    render("zh-CN", view());
    expect(host.textContent).toContain("预览完整");
    expect(host.textContent).toContain("文档/原文.md");
    expect(gateway.inspectRollbackChanges).toHaveBeenCalledTimes(1);

    await act(async () => button("预览单提交逆向变更").click());
    render("en-US", view("other-session"));
    await act(async () => second.resolve(changePreview()));
    expect(gateway.inspectRollbackChanges).toHaveBeenCalledTimes(2);
    expect(host.textContent).not.toContain("文档/原文.md");
    expect(host.textContent).not.toContain("Preview complete");
  });

  it("preserves and cancels the exact candidate plan once across a locale change", async () => {
    const request = deferred<RollbackCandidatePlan>();
    const frozenPlan = candidatePlan();
    const gateway: RollbackCandidateGateway = {
      planRollbackCandidate: vi.fn(() => request.promise),
      generateRollbackCandidate: vi.fn(),
      discardRollbackCandidate: vi.fn(async () => undefined),
    };
    const view = () => createElement(RollbackCandidatePanel, { gateway, sessionId: "session", entry, enabled: true });

    render("zh-CN", view());
    await act(async () => button("准备候选计划").click());
    render("en-US", view());
    expect(gateway.planRollbackCandidate).toHaveBeenCalledTimes(1);
    await act(async () => request.resolve(frozenPlan));
    expect(host.textContent).toContain("Candidate plan ready");
    expect(host.textContent).toContain(frozenPlan.sourceTreeSha);
    expect(host.textContent).toContain(frozenPlan.expectedSha);
    await act(async () => button("Cancel candidate plan").click());
    expect(gateway.discardRollbackCandidate).toHaveBeenCalledTimes(1);
    expect(gateway.discardRollbackCandidate).toHaveBeenCalledWith("session", frozenPlan.planId);
    expect(gateway.generateRollbackCandidate).not.toHaveBeenCalled();

    render("zh-CN", view());
    expect(host.textContent).not.toContain("候选计划已准备");
    expect(gateway.planRollbackCandidate).toHaveBeenCalledTimes(1);
    expect(gateway.discardRollbackCandidate).toHaveBeenCalledTimes(1);
  });

  it("expires a candidate plan once without restarting its timer on locale changes", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));
    const frozenPlan = candidatePlan({ checkedAtEpochMs: Date.now(), expiresAtEpochMs: Date.now() + 1_000 });
    const gateway: RollbackCandidateGateway = {
      planRollbackCandidate: vi.fn(async () => frozenPlan),
      generateRollbackCandidate: vi.fn(),
      discardRollbackCandidate: vi.fn(async () => undefined),
    };
    const view = () => createElement(RollbackCandidatePanel, { gateway, sessionId: "session", entry, enabled: true });

    render("zh-CN", view());
    await act(async () => button("准备候选计划").click());
    await settle();
    render("en-US", view());
    await act(async () => { vi.advanceTimersByTime(1_001); });
    expect(host.querySelector("[role='alert']")?.textContent).toBe("The candidate plan expired. Prepare it again.");
    expect(gateway.planRollbackCandidate).toHaveBeenCalledTimes(1);
    expect(gateway.discardRollbackCandidate).toHaveBeenCalledTimes(1);
    expect(gateway.discardRollbackCandidate).toHaveBeenCalledWith("session", frozenPlan.planId);

    render("zh-CN", view());
    expect(host.querySelector("[role='alert']")?.textContent).toBe("候选计划已过期，请重新准备。");
    expect(gateway.discardRollbackCandidate).toHaveBeenCalledTimes(1);
  });

  it("localizes controlled generic errors without exposing or translating arbitrary failures", async () => {
    const gateway: RollbackChangePreviewGateway = {
      inspectRollbackChanges: vi.fn(async () => { throw new Error("后端-原始错误"); }),
    };
    const view = () => createElement(RollbackChangePreviewPanel, { gateway, sessionId: "session", entry, enabled: true });

    render("en-US", view());
    await act(async () => button("Preview single-commit inverse changes").click());
    expect(host.querySelector("[role='alert']")?.textContent).toBe("Unable to read the single-commit inverse-change preview.");
    expect(host.textContent).not.toContain("后端-原始错误");
    render("zh-CN", view());
    expect(host.querySelector("[role='alert']")?.textContent).toBe("无法读取单提交逆向变更预览。");
    expect(gateway.inspectRollbackChanges).toHaveBeenCalledTimes(1);
  });
});
