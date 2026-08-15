# Optional bundled Codex runtime

RepoPress can use either a system-installed `codex` executable or an optional runtime bundled
inside the signed app. No third-party executable is committed to this repository.

For a direct-distribution build, provide both reviewed inputs:

```sh
REPOPRESS_CODEX_RUNTIME_PATH=/absolute/path/to/codex \
REPOPRESS_CODEX_LICENSE_PATH=/absolute/path/to/Codex-LICENSE.txt \
./script/build_and_run.sh --direct --package-only
```

The build validates that both files exist, copies them to the app bundle, signs the runtime with
the same identity as RepoPress, and verifies the final bundle seal. Release maintainers remain
responsible for selecting the correct architecture, verifying the upstream checksum and license,
and running notarization on the completed direct-distribution artifact.

App Store builds reject this option because spawning a bundled command-line runtime is not part of
the App Store sandbox distribution path.
