#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /private/tmp/mac-editor-swift-release.XXXXXX)"
BIN_DIR="$TMP_DIR/bin"
ARGS_FILE="$TMP_DIR/args"
ENV_FILE="$TMP_DIR/env"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "swift release build gate test: $*" >&2
  exit 1
}

mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/swift" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '<call>\n%s\n' "$@" >>"$RELEASE_BUILD_ARGS_FILE"
printf '%s\n' "$HOME" "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH" \
  >"$RELEASE_BUILD_ENV_FILE"
if [[ " $* " == *" --show-bin-path "* ]]; then
  printf '%s\n' "$RELEASE_BUILD_STUB_BIN_DIR"
  exit 0
fi
mkdir -p "$RELEASE_BUILD_STUB_BIN_DIR"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RELEASE_BUILD_STUB_BIN_DIR/PersonalSitePublisherMac"
chmod +x "$RELEASE_BUILD_STUB_BIN_DIR/PersonalSitePublisherMac"
exit "${RELEASE_BUILD_STUB_EXIT:-0}"
STUB
chmod +x "$BIN_DIR/swift"

: >"$ARGS_FILE"
RELEASE_BUILD_ARGS_FILE="$ARGS_FILE" \
RELEASE_BUILD_ENV_FILE="$ENV_FILE" \
RELEASE_BUILD_STUB_BIN_DIR="$TMP_DIR/.build/arm64-apple-macosx/release" \
PATH="$BIN_DIR:$PATH" \
SWIFT_BUILD_HOME="$TMP_DIR/swift-home" \
  bash "$ROOT_DIR/script/check_swift_release_build.sh" >/dev/null

grep -Fxq "build" "$ARGS_FILE" || fail "gate did not run swift build"
grep -Fxq "release" "$ARGS_FILE" || fail "gate omitted release configuration"
grep -Fxq -- "--disable-sandbox" "$ARGS_FILE" || fail "gate omitted --disable-sandbox"
grep -Fxq "PersonalSitePublisherMac" "$ARGS_FILE" || fail "gate omitted the app product"
if grep -Fq "KnowledgeNativeMessagingHost" "$ARGS_FILE"; then
  fail "gate still builds the deleted Native Messaging host"
fi
grep -Fxq -- "--show-bin-path" "$ARGS_FILE" \
  || fail "gate did not verify the Release binary directory"
grep -Fq "$TMP_DIR/swift-home" "$ENV_FILE" \
  || fail "gate did not isolate Swift build caches"

if RELEASE_BUILD_ARGS_FILE="$ARGS_FILE" \
  RELEASE_BUILD_ENV_FILE="$ENV_FILE" \
  RELEASE_BUILD_STUB_BIN_DIR="$TMP_DIR/.build/arm64-apple-macosx/release" \
  RELEASE_BUILD_STUB_EXIT=19 \
  PATH="$BIN_DIR:$PATH" \
  SWIFT_BUILD_HOME="$TMP_DIR/swift-home-failure" \
  bash "$ROOT_DIR/script/check_swift_release_build.sh" >/dev/null 2>&1; then
  fail "gate accepted a failing Release build"
fi

for path in \
  "$ROOT_DIR/Package.swift" \
  "$ROOT_DIR/script/build_and_run.sh" \
  "$ROOT_DIR/script/release_checks.json"; do
  if grep -Eq 'KnowledgeNativeMessagingHost|DIRECT_DISTRIBUTION_BUILD|package_direct_release' "$path"; then
    fail "${path#$ROOT_DIR/} still exposes a deleted distribution path"
  fi
done

for gate in check_app_store_metadata.sh check_app_store_archive_readiness.sh; do
  grep -Fq 'build_and_run.sh" --package-only --app-store' "$ROOT_DIR/script/$gate" \
    || fail "$gate does not force a fresh App Store Release package"
done

app_store_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile app-store --list)"
grep -q $'^archive-readiness-strict\tstrict\t' <<<"$app_store_checks" \
  || fail "App Store profile omitted strict archive readiness"
if grep -Eq '^(chrome-extension-store-readiness|direct-release-notarization-readiness)\t' \
  <<<"$app_store_checks"; then
  fail "App Store profile included another distribution channel"
fi

chrome_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile chrome --list)"
grep -q $'^chrome-extension-store-readiness\tstrict\t' <<<"$chrome_checks" \
  || fail "Chrome profile omitted Chrome Web Store readiness"

for removed_profile in direct edge firefox; do
  if bash "$ROOT_DIR/script/check_release_gate.sh" \
    --profile "$removed_profile" --list >/dev/null 2>&1; then
    fail "removed $removed_profile channel still has a release profile"
  fi
done

all_profile_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --profile all --list)"
strict_alias_checks="$(bash "$ROOT_DIR/script/check_release_gate.sh" --strict --list)"
[[ "$all_profile_checks" == "$strict_alias_checks" ]] \
  || fail "--strict is no longer an exact compatibility alias for --profile all"

echo "swift release build gate test: passed"
