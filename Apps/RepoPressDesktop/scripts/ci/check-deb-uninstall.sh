#!/usr/bin/env bash
# Install-time companion: remove one package and prove its files are gone.
set -euo pipefail
usage() { cat <<'EOF'
Usage: check-deb-uninstall.sh --package-file FILE --diagnostics-dir DIRECTORY
The package must already be installed. User data under HOME is never purged.
EOF
}
package_file=""; diagnostics_dir=""
while (($# > 0)); do
  case "$1" in
    --package-file) package_file="${2:-}"; shift 2 ;;
    --diagnostics-dir) diagnostics_dir="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -z "$package_file" || -z "$diagnostics_dir" ]]; then printf '%s\n' '--package-file and --diagnostics-dir are required.' >&2; exit 2; fi
if [[ ! -f "$package_file" ]]; then printf 'Package does not exist: %s\n' "$package_file" >&2; exit 1; fi
for command in dpkg-deb dpkg-query sudo apt-get; do command -v "$command" >/dev/null || { printf 'Required command is unavailable: %s\n' "$command" >&2; exit 1; }; done
mkdir -p "$diagnostics_dir"
package_name="$(dpkg-deb -f "$package_file" Package)"
package_version="$(dpkg-deb -f "$package_file" Version)"
mapfile -t owned_paths < <(dpkg-query -L "$package_name")
if ((${#owned_paths[@]} == 0)); then printf 'No package-owned paths found for %s.\n' "$package_name" >&2; exit 1; fi
leaf_paths=()
for path in "${owned_paths[@]}"; do
  # dpkg-query lists parent directories without a trailing slash. They are
  # expected to remain after removal and are intentionally not asserted.
  if [[ -L "$path" ]] || { [[ -e "$path" ]] && [[ ! -d "$path" ]]; }; then leaf_paths+=("$path"); fi
done
printf 'Removing %s (%s) and checking %d package-owned paths.\n' "$package_name" "$package_version" "${#owned_paths[@]}" | tee "$diagnostics_dir/uninstall.log"
sudo apt-get remove --yes --no-install-recommends "$package_name" >>"$diagnostics_dir/uninstall.log" 2>&1
remaining=()
for path in "${leaf_paths[@]}"; do
  if [[ -e "$path" || -L "$path" ]]; then remaining+=("$path"); fi
done
if ((${#remaining[@]})); then
  printf 'Package-owned paths remain after uninstall:\n' >&2; printf '  %s\n' "${remaining[@]}" >&2
  printf '%s\n' "${remaining[@]}" >"$diagnostics_dir/remaining-paths.txt"; exit 1
fi
printf 'Debian uninstall check passed for %s.\n' "$package_name"
