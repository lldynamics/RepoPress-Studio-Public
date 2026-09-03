export interface CapabilitySnapshot {
  localEdit: boolean; markdownPreview: boolean; gitStatus: boolean; siteRuntime: boolean;
  gitCommit: boolean; gitPush: boolean; gitFetch: boolean; remoteAuth: boolean;
}
export interface RepositorySessionSnapshot {
  sessionId: string; rootPath: string; displayName: string; siteKind: string;
  contentRoot: string | null; isGitRepository: boolean; warnings: string[];
}
export interface MarkdownFileEntry { relativePath: string; displayName: string; directory: string; byteSize: number; }
export interface DocumentSnapshot {
  documentId: string; relativePath: string; text: string; encoding: string;
  lineEnding: "none" | "lf" | "crlf" | "mixed"; byteSize: number; baselineSha256: string;
  revision: number; writable: boolean; readOnlyReason: string | null;
}
export interface SaveDocumentRequest { sessionId: string; documentId: string; text: string; expectedSha256: string; }
export type SaveDocumentResult = DocumentSnapshot;
export interface GitChangedFile { status: string; relativePath: string; sourcePath: string | null; }
export interface GitStatusSnapshot {
  available: boolean; branch: string | null; upstream: string | null; ahead: number; behind: number;
  detached: boolean; changedFiles: GitChangedFile[]; warnings: string[];
}
export interface GatewayError { code: string; message: string; }
export interface RepositoryGateway {
  getCapabilities(): Promise<CapabilitySnapshot>;
  openRepository(path: string): Promise<RepositorySessionSnapshot>;
  listMarkdownFiles(sessionId: string): Promise<MarkdownFileEntry[]>;
  openDocument(sessionId: string, relativePath: string): Promise<DocumentSnapshot>;
  saveDocument(request: SaveDocumentRequest): Promise<SaveDocumentResult>;
  gitStatus(sessionId: string): Promise<GitStatusSnapshot>;
}
