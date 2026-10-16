export interface RepositoryImage {
  relativePath: string;
  fileName: string;
  byteSize: number;
  mimeType: string;
  width: number | null;
  height: number | null;
  sha256: string;
}

export interface RepositoryImageSnapshot {
  images: RepositoryImage[];
  scannedEntries: number;
  scannedBytes: number;
  omittedFiles: number;
  truncated: boolean;
  warnings: string[];
}

export interface RepositoryImagePreview {
  relativePath: string;
  mimeType: string;
  dataBase64: string;
  sha256: string;
}
