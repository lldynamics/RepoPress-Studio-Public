#!/usr/bin/env bash
# Validate the two Linux release artifacts Tauri is expected to produce and
# write a portable checksum manifest for release consumers.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: validate-linux-bundles.sh --bundle-dir DIRECTORY --output-dir DIRECTORY

Requires exactly one .deb and one .AppImage directly below the bundle's deb/
and appimage/ directories. Writes linux-bundle-sha256sums.txt to OUTPUT-DIR.
EOF
}

bundle_dir=""
output_dir=""

while (($# > 0)); do
  case "$1" in
    --bundle-dir)
      bundle_dir="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$bundle_dir" || -z "$output_dir" ]]; then
  printf '%s\n' '--bundle-dir and --output-dir are required.' >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$bundle_dir" ]]; then
  printf 'Bundle directory does not exist: %s\n' "$bundle_dir" >&2
  exit 1
fi

mapfile -d '' -t debs < <(find "$bundle_dir/deb" -maxdepth 1 -type f -name '*.deb' -print0 2>/dev/null | sort -z)
mapfile -d '' -t appimages < <(find "$bundle_dir/appimage" -maxdepth 1 -type f -name '*.AppImage' -print0 2>/dev/null | sort -z)

if ((${#debs[@]} != 1)); then
  printf 'Expected exactly one Debian bundle under %s/deb; found %d.\n' "$bundle_dir" "${#debs[@]}" >&2
  printf '  %s\n' "${debs[@]:-<none>}" >&2
  exit 1
fi

if ((${#appimages[@]} != 1)); then
  printf 'Expected exactly one AppImage bundle under %s/appimage; found %d.\n' "$bundle_dir" "${#appimages[@]}" >&2
  printf '  %s\n' "${appimages[@]:-<none>}" >&2
  exit 1
fi

for artifact in "${debs[@]}" "${appimages[@]}"; do
  if [[ ! -s "$artifact" ]]; then
    printf 'Release artifact is empty: %s\n' "$artifact" >&2
    exit 1
  fi
done

mkdir -p "$output_dir"
manifest="$output_dir/linux-bundle-sha256sums.txt"
{
  printf '# SHA-256 checksums for RepoPress Studio Linux bundles\n'
  printf '# Generated from immutable CI build outputs; paths are relative to the bundle root.\n'
  (cd "$bundle_dir" && sha256sum "${debs[0]#"$bundle_dir"/}" "${appimages[0]#"$bundle_dir"/}")
} >"$manifest"

printf 'Validated Linux release artifacts:\n'
printf '  deb: %s\n' "${debs[0]}"
printf '  AppImage: %s\n' "${appimages[0]}"
printf 'SHA-256 manifest: %s\n' "$manifest"
