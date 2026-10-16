import { KnowledgeRestoreHistoryExportPanel } from "./KnowledgeRestoreHistoryExportPanel";
import { KnowledgeRestoreCleanupPanel } from "./KnowledgeRestoreCleanupPanel";
import type { KnowledgeRestoreCleanupGateway } from "../contracts/knowledgeRestoreCleanup";
import { KnowledgeRestoreArchivePanel } from "./KnowledgeRestoreArchivePanel";
import type { KnowledgeRestoreArchiveGateway } from "../contracts/knowledgeRestoreArchive";
import { KnowledgeRestoreInstallPanel } from "./KnowledgeRestoreInstallPanel";
import type { KnowledgeRestoreInstallGateway } from "../contracts/knowledgeRestoreInstall";
import { KnowledgeMergeProjectionPanel } from "./KnowledgeMergeProjectionPanel";
import type { KnowledgeMergeProjectionGateway } from "../contracts/knowledgeMergeProjection";
import { KnowledgeRestoreQualificationPanel } from "./KnowledgeRestoreQualificationPanel";
import type { KnowledgeRestoreQualificationGateway } from "../contracts/knowledgeRestoreQualification";
import { KnowledgeCandidateCheckPanel } from "./KnowledgeCandidateCheckPanel";
import type { KnowledgeCandidateCheckGateway } from "../contracts/knowledgeCandidateCheck";
import { KnowledgePackageStagePanel } from "./KnowledgePackageStagePanel";
import type { KnowledgePackageStageGateway } from "../contracts/knowledgePackageStage";
import { KnowledgePackageCheckPanel } from "./KnowledgePackageCheckPanel";
import type { KnowledgePackageCheckGateway } from "../contracts/knowledgePackageCheck";
import { useMemo } from "react";
import { createRepositoryGateway } from "../platform/repositoryGateway";
import { WorkspaceBackupPreflightPanel } from "./WorkspaceBackupPreflightPanel";
import { WorkspaceConfigBackupPanel } from "./WorkspaceConfigBackupPanel";
import type { WorkspaceConfigBackupGateway } from "../contracts/workspaceConfigBackup";
import { RssSnapshotBackupPanel } from "./RssSnapshotBackupPanel";
import type { RssSnapshotBackupGateway } from "../contracts/rssSnapshotBackup";
import { DraftSnapshotBackupPanel } from "./DraftSnapshotBackupPanel";
import type { DraftSnapshotBackupGateway } from "../contracts/draftSnapshotBackup";
import { KnowledgeIntegrityPanel } from "./KnowledgeIntegrityPanel";
import type { KnowledgeIntegrityGateway } from "../contracts/knowledgeIntegrity";
import { KnowledgeBackupPanel } from "./KnowledgeBackupPanel";
import type { KnowledgeBackupGateway } from "../contracts/knowledgeBackup";

/** Settings owns application-wide scope; no repository switch or implicit inspection. */
export function WorkspaceBackupSettingsSection({ open, enabled, disabled }: { open: boolean; enabled: boolean; disabled: boolean }) {
  const gateway = useMemo(() => createRepositoryGateway(), []);
  return <div className="workspace-backup-settings">
    <WorkspaceBackupPreflightPanel gateway={gateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeIntegrityPanel gateway={gateway as unknown as KnowledgeIntegrityGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeRestoreHistoryExportPanel gateway={gateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeRestoreCleanupPanel gateway={gateway as unknown as KnowledgeRestoreCleanupGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeRestoreArchivePanel gateway={gateway as unknown as KnowledgeRestoreArchiveGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeRestoreInstallPanel gateway={gateway as unknown as KnowledgeRestoreInstallGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeMergeProjectionPanel gateway={gateway as unknown as KnowledgeMergeProjectionGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeRestoreQualificationPanel gateway={gateway as unknown as KnowledgeRestoreQualificationGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeCandidateCheckPanel gateway={gateway as unknown as KnowledgeCandidateCheckGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgePackageStagePanel gateway={gateway as unknown as KnowledgePackageStageGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgePackageCheckPanel gateway={gateway as unknown as KnowledgePackageCheckGateway} enabled={open && enabled} disabled={disabled} />
    <KnowledgeBackupPanel gateway={gateway as unknown as KnowledgeBackupGateway} enabled={open && enabled} disabled={disabled} />
    <WorkspaceConfigBackupPanel gateway={gateway as unknown as WorkspaceConfigBackupGateway} enabled={open && enabled} disabled={disabled} />
    <RssSnapshotBackupPanel gateway={gateway as unknown as RssSnapshotBackupGateway} enabled={open && enabled} disabled={disabled} />
    <DraftSnapshotBackupPanel gateway={gateway as unknown as DraftSnapshotBackupGateway} enabled={open && enabled} disabled={disabled} />
  </div>;
}
