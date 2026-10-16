import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open } from "@tauri-apps/plugin-dialog";
import type { SaveRecoveryDraftRequest } from "../contracts/repository";

export interface EditorExitPlan { planId: string; exportPath: string | null }
export interface EditorExitGateway {
  prepare(draft: SaveRecoveryDraftRequest | null, exportDirectory: string | null): Promise<EditorExitPlan>;
  complete(planId: string): Promise<void>;
  selectExportDirectory(): Promise<string | null>;
}

// These narrow commands intentionally bypass the normal activity gate. Only the
// close controller calls them while holding an exclusive freeze lease.
export const editorExitGateway: EditorExitGateway = {
  prepare: (draft, exportDirectory) => invoke("prepare_editor_exit", { draft, exportDirectory }),
  complete: (planId) => invoke("complete_editor_exit", { planId }),
  selectExportDirectory: async () => {
    const path = await open({ directory: true, multiple: false, title: "选择当前文章恢复包的保存目录" });
    return typeof path === "string" ? path : null;
  },
};
export const listenForEditorClose = (handler: () => void) => listen("repopress://close-requested", handler);
