import type { SaveRecoveryDraftRequest } from "../../contracts/repository";
import type { EditorExitGateway } from "../../platform/editorExitGateway";
import type { ExitActivityGate } from "../../platform/exitActivity";
import type { UiMessage } from "../../i18n/uiMessage";

export interface EditorExitSnapshot {
  draft: SaveRecoveryDraftRequest | null;
  dirty: boolean;
  recoveryEnabled: boolean;
  workspaceWarning?: boolean;
}
export interface EditorExitState {
  open: boolean;
  busy: boolean;
  snapshot: EditorExitSnapshot | null;
  error: string;
  /** Only controller-generated messages carry a translatable presentation source. */
  errorPresentation?: UiMessage;
  exportPath: string | null;
}
const closedState = (): EditorExitState => ({ open: false, busy: false, snapshot: null, error: "", exportPath: null });

/** A frozen current-editor transaction, not a whole-workspace shutdown ledger. */
export class EditorExitController {
  private state = closedState();
  private release: (() => void) | null = null;
  constructor(private readonly dependencies: {
    gate: ExitActivityGate;
    gateway: EditorExitGateway;
    readSnapshot: () => EditorExitSnapshot;
    canStart: () => boolean;
    suspendRecovery: () => void;
    onState: (state: EditorExitState) => void;
    onBlocked: (message: string) => void;
  }) {}

  request(): void {
    if (this.state.open) return;
    if (!this.dependencies.canStart()) {
      this.dependencies.onBlocked("请先完成并关闭打开的面板，返回写作区，等待当前操作结束后再关闭窗口。");
      return;
    }
    try {
      this.release = this.dependencies.gate.freeze();
      this.dependencies.suspendRecovery();
      const snapshot = this.dependencies.readSnapshot();
      this.update({ ...closedState(), open: true, snapshot });
    } catch {
      this.release?.(); this.release = null;
      this.dependencies.onBlocked("操作仍在进行，窗口已保留。请等待完成后再次关闭窗口。");
    }
  }

  cancel(): void {
    if (this.state.busy) return;
    this.release?.(); this.release = null;
    this.update(closedState());
  }

  async finish(mode: "recovery" | "export"): Promise<void> {
    const snapshot = this.state.snapshot;
    if (!this.state.open || this.state.busy || !snapshot) return;
    this.update({ ...this.state, busy: true, error: "", errorPresentation: undefined });
    try {
      let directory: string | null = null;
      if (mode === "export") {
        directory = await this.dependencies.gateway.selectExportDirectory();
        if (!directory) { this.update({ ...this.state, busy: false }); return; }
      }
      this.assertUnchanged(snapshot);
      const draft = mode === "export" || snapshot.dirty ? snapshot.draft : null;
      if (snapshot.dirty && !draft) throw new Error("exit_snapshot_changed");
      const plan = await this.dependencies.gateway.prepare(draft, directory);
      this.update({ ...this.state, exportPath: plan.exportPath });
      this.assertUnchanged(snapshot);
      await this.dependencies.gateway.complete(plan.planId);
      // Keep the editor frozen until the native runtime exits. Never assume an
      // IPC response means the OS has already destroyed the window.
    } catch (error) {
      const source = exitError(error);
      this.update({ ...this.state, busy: false, error: source, errorPresentation: { source } });
    }
  }

  dispose(): void { this.release?.(); this.release = null; }
  private assertUnchanged(expected: EditorExitSnapshot): void {
    if (JSON.stringify(this.dependencies.readSnapshot()) !== JSON.stringify(expected)) throw new Error("exit_snapshot_changed");
  }
  private update(state: EditorExitState): void { this.state = state; this.dependencies.onState(state); }
}

function exitError(error: unknown): string {
  const code = (error as { code?: string })?.code ?? (error instanceof Error ? error.message : "");
  if (code === "exit_snapshot_changed" || code === "exit_document_changed") return "文章在校验期间发生变化。请返回编辑后重新关闭窗口。";
  if (code === "exit_ai_busy") return "AI 流式任务仍在进行。请返回并等待任务完成，再关闭窗口。";
  if (code === "exit_untrusted_workspace") return "已有恢复文件无法读取，已保留原文件。请导出当前文章恢复包后退出。";
  if (code === "exit_recovery_disabled") return "自动恢复已关闭。请导出当前文章恢复包，或返回编辑并保存文章。";
  return "未能完成保存或读回校验，窗口已保留。可重试、导出当前文章恢复包，或返回编辑。";
}
