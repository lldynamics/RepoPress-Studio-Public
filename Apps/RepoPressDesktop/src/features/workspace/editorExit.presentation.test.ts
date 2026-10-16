import { describe, expect, it, vi } from "vitest";
import type { EditorExitGateway } from "../../platform/editorExitGateway";
import { EditorExitController, type EditorExitState } from "./editorExit";

describe("editor exit local error presentation", () => {
  it.each([
    [{ code: "exit_document_changed" }, "文章在校验期间发生变化。请返回编辑后重新关闭窗口。"],
    [new Error("private /tmp/设置-{path}.json"), "未能完成保存或读回校验，窗口已保留。可重试、导出当前文章恢复包，或返回编辑。"],
  ])("marks only the controlled failure and clears it on retry and cancel", async (reason, source) => {
    const states: EditorExitState[] = [];
    const release = vi.fn();
    const gateway: EditorExitGateway = {
      prepare: vi.fn().mockRejectedValueOnce(reason).mockResolvedValueOnce({ planId: "original-plan", exportPath: null }),
      complete: vi.fn(async () => undefined),
      selectExportDirectory: vi.fn(async () => null),
    };
    const controller = new EditorExitController({
      gateway, gate: { freeze: vi.fn(() => release) } as never,
      readSnapshot: () => ({ draft: null, dirty: false, recoveryEnabled: true }),
      canStart: () => true, suspendRecovery: vi.fn(), onBlocked: vi.fn(), onState: state => states.push(state),
    });
    controller.request(); await controller.finish("recovery");
    expect(states[states.length - 1]).toMatchObject({ open: true, busy: false, error: source, errorPresentation: { source } });
    expect(JSON.stringify(states[states.length - 1])).not.toContain("private /tmp");
    controller.cancel(); expect(states[states.length - 1]).toEqual({ open: false, busy: false, snapshot: null, error: "", exportPath: null });
    expect(release).toHaveBeenCalledTimes(1);
    controller.request();
    await controller.finish("recovery");
    expect(states[states.length - 1]?.error).toBe(""); expect(states[states.length - 1]?.errorPresentation).toBeUndefined();
    expect(gateway.prepare).toHaveBeenCalledTimes(2); expect(gateway.complete).toHaveBeenCalledWith("original-plan");
    controller.cancel();
    expect(release).toHaveBeenCalledTimes(1);
  });
});
