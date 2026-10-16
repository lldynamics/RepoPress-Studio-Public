import type { DocumentSnapshot, RepositoryGateway } from "../../contracts/repository";

export type RepositoryTarget = { kind: "path"; path: string } | { kind: "profile"; profileId: string };

/** Prepare a fresh session and its files without replacing the visible editor.
 * Every asynchronous boundary rechecks the caller's request/editor identity. */
export async function prepareRepositorySwitch(
  gateway: RepositoryGateway,
  target: RepositoryTarget,
  documentPath: string | null,
  isCurrent: () => boolean,
) {
  if (!isCurrent()) return null;
  const repository = await (target.kind === "profile"
    ? gateway.openSiteProfile(target.profileId)
    : gateway.openRepository(target.path));
  if (!isCurrent()) return null;
  const files = await gateway.listMarkdownFiles(repository.sessionId);
  if (!isCurrent()) return null;
  let document: DocumentSnapshot | null = null;
  let restoreFailed = false;
  if (documentPath) {
    try { document = await gateway.openDocument(repository.sessionId, documentPath); }
    catch { restoreFailed = true; }
    if (!isCurrent()) return null;
  }
  return { repository, files, document, restoreFailed };
}
