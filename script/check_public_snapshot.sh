#!/usr/bin/env bash
set -euo pipefail

ROOT_INPUT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -d "$ROOT_INPUT" ]] || {
  echo "public snapshot gate: directory is missing: $ROOT_INPUT" >&2
  exit 1
}
ROOT_DIR="$(cd "$ROOT_INPUT" && pwd -P)"

command -v rg >/dev/null 2>&1 || {
  echo "public snapshot gate: ripgrep (rg) is required" >&2
  exit 1
}
command -v shasum >/dev/null 2>&1 || {
  echo "public snapshot gate: shasum is required" >&2
  exit 1
}

fail() {
  echo "public snapshot gate: $*" >&2
  exit 1
}

relative_path() {
  local file_name="$1"
  printf '%s' "${file_name#"$ROOT_DIR"/}"
}

reference_from_hit() {
  local hit="$1"
  local matched_file="${hit%%:*}"
  local remainder="${hit#*:}"
  local line_number="${remainder%%:*}"
  printf '%s:%s' "$(relative_path "$matched_file")" "$line_number"
}

required_paths=(
  .gitignore
  .github/CODEOWNERS
  .github/dependabot.yml
  .github/workflows/quality.yml
  CONTRIBUTING.md
  LICENSE
  Package.resolved
  Package.swift
  README.md
  SECURITY.md
  TRADEMARKS.md
  package-lock.json
  package.json
  BrowserExtension
  Packaging/ThirdPartyNotices
  Sources
  Tests
  script/check_public_snapshot.sh
  script/public-scan-fixture-allowlist.txt
)

for path in "${required_paths[@]}"; do
  [[ -e "$ROOT_DIR/$path" ]] || fail "required public file is missing: $path"
done

expected_license_sha256="3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04"
actual_license_sha256="$(shasum -a 256 "$ROOT_DIR/LICENSE" | awk '{print $1}')"
[[ "$actual_license_sha256" == "$expected_license_sha256" ]] \
  || fail "LICENSE must be the unmodified Mozilla Public License 2.0 text"
rg -Fq 'RepoPress is open-source software under the Mozilla Public License 2.0 (`MPL-2.0`).' \
  "$ROOT_DIR/README.md" \
  || fail "README.md must identify MPL-2.0 as the project license"
rg -Fq '`TRADEMARKS.md`' "$ROOT_DIR/README.md" \
  || fail "README.md must link the trademark policy"
rg -Fq '"license": "MPL-2.0"' "$ROOT_DIR/package.json" \
  || fail "package.json must declare MPL-2.0"

forbidden_paths=(
  APP_STORE_CHECKLIST.md
  README.public.md
  BrowserExtension/release-ledger.json
  docs/app-store
  docs/app-store-screenshots
  docs/browser-extension-store-assets
  docs/release-evidence
  dist
  audit
  output
  script/export_public_snapshot.sh
  script/test_public_snapshot_export.sh
  script/public-repository
)

for path in "${forbidden_paths[@]}"; do
  [[ ! -e "$ROOT_DIR/$path" ]] || fail "private or generated path is present: $path"
done

blocked_directories=()
while IFS= read -r -d '' directory; do
  blocked_directories+=("$(relative_path "$directory")")
done < <(
  find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type d \
    \( -name '.build' -o -name '.swiftpm' -o -name '.codex' -o -name '.vscode' \
       -o -name 'DerivedData' -o -name 'node_modules' -o -name 'dist' \
       -o -name 'audit' -o -name 'output' \) -print0
)
if [[ "${#blocked_directories[@]}" -gt 0 ]]; then
  printf 'public snapshot gate: generated or private directory found:\n' >&2
  printf '  - %s\n' "${blocked_directories[@]}" >&2
  exit 1
fi

symlinks=()
while IFS= read -r -d '' link; do
  symlinks+=("$(relative_path "$link")")
done < <(find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type l -print0)
if [[ "${#symlinks[@]}" -gt 0 ]]; then
  printf 'public snapshot gate: symbolic links are not allowed:\n' >&2
  printf '  - %s\n' "${symlinks[@]}" >&2
  exit 1
fi

workflow_files=()
while IFS= read -r workflow; do
  [[ -n "$workflow" ]] && workflow_files+=("$(relative_path "$workflow")")
done < <(find "$ROOT_DIR/.github/workflows" -type f -print | LC_ALL=C sort)

if [[ "${#workflow_files[@]}" -ne 1 || "${workflow_files[0]}" != ".github/workflows/quality.yml" ]]; then
  fail "only the public quality workflow may be exported"
fi

if git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  historical_private_paths=()
  for private_path in \
    APP_STORE_CHECKLIST.md \
    README.public.md \
    BrowserExtension/release-ledger.json \
    docs/app-store \
    docs/app-store-screenshots \
    docs/browser-extension-store-assets \
    docs/release-evidence; do
    if [[ -n "$(git -C "$ROOT_DIR" rev-list --objects --all -- "$private_path" 2>/dev/null)" ]]; then
      historical_private_paths+=("$private_path")
    fi
  done
  if [[ "${#historical_private_paths[@]}" -gt 0 ]]; then
    printf 'public snapshot gate: private path is reachable from Git history:\n' >&2
    printf '  - %s\n' "${historical_private_paths[@]}" >&2
    exit 1
  fi
fi

blocked_files=()
while IFS= read -r -d '' file; do
  blocked_files+=("$(relative_path "$file")")
done < <(
  find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type f \
    \( -name '.DS_Store' -o -name '._*' -o -name '.env' -o -name '.env.*' \
       -o -name '*.credentials' -o -name '*.pem' -o -name '*.key' -o -name '*.p8' \
       -o -name '*.p12' -o -name '*.mobileprovision' -o -name '*.provisionprofile' \
       -o -name '*.jks' -o -name '*.keystore' -o -name '*.sqlite' -o -name '*.sqlite3' \
       -o -name '*.db' -o -name '*.log' -o -name '*.dump' -o -name '*.har' \
       -o -name '*.xcarchive' -o -name '*.dmg' -o -name '*.zip' -o -name '*.xpi' \) \
    -print0
)
if [[ "${#blocked_files[@]}" -gt 0 ]]; then
  printf 'public snapshot gate: blocked file type found:\n' >&2
  printf '  - %s\n' "${blocked_files[@]}" >&2
  exit 1
fi

unexpected_images=()
while IFS= read -r -d '' file; do
  relative="$(relative_path "$file")"
  case "$relative" in
    BrowserExtension/shared/icons/*.png|Sources/PersonalSitePublisherMac/Resources/AppIcon.icns)
      ;;
    *)
      unexpected_images+=("$relative")
      ;;
  esac
done < <(
  find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' \
       -o -iname '*.heic' -o -iname '*.tiff' -o -iname '*.webp' -o -iname '*.icns' \) \
    -print0
)
if [[ "${#unexpected_images[@]}" -gt 0 ]]; then
  printf 'public snapshot gate: unreviewed image found outside the extension icon allowlist:\n' >&2
  printf '  - %s\n' "${unexpected_images[@]}" >&2
  exit 1
fi

scan_allowlist="$ROOT_DIR/script/public-scan-fixture-allowlist.txt"
unsafe_content_refs=()
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  matched_file="${hit%%:*}"
  remainder="${hit#*:}"
  line_number="${remainder%%:*}"
  relative="$(relative_path "$matched_file")"
  line_text="$(sed -n "${line_number}p" "$matched_file")"
  line_hash="$(printf '%s' "$line_text" | shasum -a 256 | awk '{print $1}')"
  if grep -Fqx "$relative|$line_hash" "$scan_allowlist"; then
    continue
  fi
  unsafe_content_refs+=("$relative:$line_number")
done < <(
  LC_ALL=C rg -n --hidden -g '!.git/**' \
    -e '/Users/[A-Za-z0-9._-]+/' \
    -e 'file:///Users/[A-Za-z0-9._-]+/' \
    -e '/Volumes/[A-Za-z0-9._ -]+/' \
    -e 'file:///Volumes/[A-Za-z0-9._ -]+/' \
    -e 'github_pat_[A-Za-z0-9_]{20,}' \
    -e 'ghp_[A-Za-z0-9]{20,}' \
    -e 'glpat-[A-Za-z0-9_-]{20,}' \
    -e 'sk-[A-Za-z0-9_-]{20,}' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'AIza[0-9A-Za-z_-]{35}' \
    -e 'xox[baprs]-[0-9A-Za-z-]{20,}' \
    -e 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' \
    -e 'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]{20,}' \
    -e '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' \
    "$ROOT_DIR" || true
)
if [[ "${#unsafe_content_refs[@]}" -gt 0 ]]; then
  printf 'public snapshot gate: private path or credential-like content found:\n' >&2
  printf '  - %s\n' "${unsafe_content_refs[@]}" >&2
  exit 1
fi

credential_url_hits=()
while IFS= read -r hit; do
  [[ -n "$hit" ]] && credential_url_hits+=("$(reference_from_hit "$hit")")
done < <(
  LC_ALL=C rg -n \
    -e 'https?://[^/@[:space:]]+:[^/@[:space:]]+@' \
    "$ROOT_DIR/Sources" "$ROOT_DIR/BrowserExtension" "$ROOT_DIR/Packaging" || true
)
if [[ "${#credential_url_hits[@]}" -gt 0 ]]; then
  printf 'public snapshot gate: credential-bearing URL found in product source:\n' >&2
  printf '  - %s\n' "${credential_url_hits[@]}" >&2
  exit 1
fi

echo "public snapshot gate: public source boundary passed"
