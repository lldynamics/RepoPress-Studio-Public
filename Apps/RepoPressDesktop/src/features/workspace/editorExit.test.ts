import { describe, expect, it, vi } from "vitest";
import type { EditorExitGateway } from "../../platform/editorExitGateway";
import { EditorExitController, type EditorExitSnapshot, type EditorExitState } from "./editorExit";

const snapshot = (text = "正文", dirty = true): EditorExitSnapshot => ({
  draft: { sessionId: "session", documentId: "doc", text, expectedSha256: "a".repeat(64) },
  dirty,
  recoveryEnabled: true,
});

function harness(initial = snapshot()) {
  let current = initial;
  let releaseCount = 0;
  const release = vi.fn(() => { releaseCount += 1; });
  const gate = { freeze: vi.fn(() => release) };
  const gateway: EditorExitGateway = {
    prepare: vi.fn(async () => ({ planId: "plan", exportPath: null })),
    complete: vi.fn(async () => undefined),
    selectExportDirectory: vi.fn(async () => "/exports"),
  };
  const states: EditorExitState[] = [];
  const onBlocked = vi.fn();
  const controller = new EditorExitController({
    gate: gate as never,
    gateway,
    readSnapshot: () => current,
    canStart: () => true,
    suspendRecovery: vi.fn(),
    onState: (state) => states.push(state),
    onBlocked,
  });
  return {
    controller,
    gateway,
    gate,
    release,
    get releaseCount() { return releaseCount; },
    states,
    onBlocked,
    setSnapshot(next: EditorExitSnapshot) { current = next; },
  };
}

describe("EditorExitController", () => {
  it("captures clean, dirty, Unicode, and empty snapshots exactly", () => {
    const clean = harness(snapshot("你好🙂", false));
    clean.controller.request();
    expect(clean.states[clean.states.length - 1]).toMatchObject({ open: true, snapshot: snapshot("你好🙂", false) });

    const empty = harness(snapshot("", true));
    empty.controller.request();
    expect(empty.states[empty.states.length - 1]?.snapshot).toEqual(snapshot("", true));
  });

  it("does not complete when prepare fails, and keeps the dialog open with an error", async () => {
    const test = harness();
    vi.mocked(test.gateway.prepare).mockRejectedValueOnce({ code: "exit_snapshot_changed" });
    test.controller.request();
    await test.controller.finish("recovery");
    expect(test.gateway.complete).not.toHaveBeenCalled();
    expect(test.states[test.states.length - 1]).toMatchObject({ open: true, busy: false, error: expect.stringContaining("发生变化") });
  });

  it("keeps the dialog open when complete fails", async () => {
    const test = harness();
    vi.mocked(test.gateway.complete).mockRejectedValueOnce(new Error("readback failed"));
    test.controller.request();
    await test.controller.finish("recovery");
    expect(test.states[test.states.length - 1]).toMatchObject({ open: true, busy: false, error: expect.stringContaining("未能完成") });
    expect(test.release).not.toHaveBeenCalled();
  });

  it("retains the freeze after export cancellation until cancel releases it", async () => {
    const test = harness();
    vi.mocked(test.gateway.selectExportDirectory).mockResolvedValueOnce(null);
    test.controller.request();
    await test.controller.finish("export");
    expect(test.states[test.states.length - 1]).toMatchObject({ open: true, busy: false });
    expect(test.release).not.toHaveBeenCalled();
    test.controller.cancel();
    expect(test.release).toHaveBeenCalledTimes(1);
    expect(test.states[test.states.length - 1]).toEqual({ open: false, busy: false, snapshot: null, error: "", exportPath: null });
  });

  it("blocks complete when the exact snapshot drifts during async prepare", async () => {
    const test = harness();
    let resolvePrepare!: (plan: { planId: string; exportPath: string | null }) => void;
    vi.mocked(test.gateway.prepare).mockReturnValueOnce(new Promise((resolve) => { resolvePrepare = resolve; }));
    test.controller.request();
    const finishing = test.controller.finish("recovery");
    test.setSnapshot(snapshot("changed after prepare began"));
    resolvePrepare({ planId: "plan", exportPath: null });
    await finishing;
    expect(test.gateway.complete).not.toHaveBeenCalled();
    expect(test.states[test.states.length - 1]).toMatchObject({ open: true, busy: false, error: expect.stringContaining("发生变化") });
  });

  it("ignores duplicate requests and finish clicks while busy", async () => {
    const test = harness();
    let resolvePrepare!: (plan: { planId: string; exportPath: string | null }) => void;
    vi.mocked(test.gateway.prepare).mockReturnValueOnce(new Promise((resolve) => { resolvePrepare = resolve; }));
    test.controller.request();
    test.controller.request();
    const first = test.controller.finish("recovery");
    const second = test.controller.finish("recovery");
    expect(test.gate.freeze).toHaveBeenCalledTimes(1);
    expect(test.gateway.prepare).toHaveBeenCalledTimes(1);
    resolvePrepare({ planId: "plan", exportPath: null });
    await Promise.all([first, second]);
    expect(test.gateway.complete).toHaveBeenCalledTimes(1);
  });

  it("blocks at canStart and when the gate refuses a freeze", () => {
    const blocked = harness();
    blocked.controller = new EditorExitController({
      gate: blocked.gate as never,
      gateway: blocked.gateway,
      readSnapshot: () => snapshot(),
      canStart: () => false,
      suspendRecovery: vi.fn(),
      onState: (state) => blocked.states.push(state),
      onBlocked: blocked.onBlocked,
    });
    blocked.controller.request();
    expect(blocked.gate.freeze).not.toHaveBeenCalled();
    expect(blocked.onBlocked).toHaveBeenCalledWith(expect.stringContaining("面板"));

    const refused = harness();
    vi.mocked(refused.gate.freeze).mockImplementationOnce(() => { throw { code: "exit_busy" }; });
    refused.controller.request();
    expect(refused.onBlocked).toHaveBeenCalledWith(expect.stringContaining("操作仍在进行"));
    expect(refused.states).toHaveLength(0);
  });

  it("releases the gate on cancel and dispose, while successful finish remains frozen", async () => {
    const cancelled = harness();
    cancelled.controller.request();
    cancelled.controller.cancel();
    expect(cancelled.releaseCount).toBe(1);

    const disposed = harness();
    disposed.controller.request();
    disposed.controller.dispose();
    expect(disposed.releaseCount).toBe(1);

    const finished = harness();
    finished.controller.request();
    await finished.controller.finish("recovery");
    expect(finished.gateway.complete).toHaveBeenCalledWith("plan");
    expect(finished.release).not.toHaveBeenCalled();
  });
});
