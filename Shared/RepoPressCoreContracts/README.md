# RepoPress shared contracts and Core

This repository is the versioned, language-neutral contract for the first
RepoPress shared-core milestone.  The contract is deliberately small and
deterministic so that Swift, C#, and other readers can share the same golden
fixtures without sharing UI or persistence code.

Within the RepoPress Studio repository this module lives at
`Shared/RepoPressCoreContracts/`. Run the commands below from that directory.
The subtree is distributed under the repository's Mozilla Public License 2.0;
standalone publication requires its own reviewed license and release metadata.

## Scope

M1 covers three capabilities:

- `repository-endpoint`: validate an HTTPS repository API base URL and build a
  request URL while preserving self-hosted base paths.
- `front-matter-document`: render YAML or TOML front matter, or assemble it
  with a Markdown body.
- `publish-conflict-diff`: produce stable line-level remote/local conflict
  lines with a bounded LCS implementation and a coarse fallback.

Each fixture is a JSON object with `id`, `capability`, `validity`,
`description`, `input`, and `expected`.  The fixture manifest is versioned with
`formatVersion: 1` and `minimumReaderVersion: 1`; each entry records the
fixture-relative path and its SHA-256 digest.

M1 does not include an App, UI, platform bridges, credentials, authentication
tokens, network transport, database schema, or persistence.  Those concerns
remain platform-specific and must not be inferred from these contracts.

## Canonical JSON

Contract and fixture JSON is UTF-8 without a BOM, uses LF line endings, two
spaces of indentation, `ensure_ascii=false`, Unicode-code-point `sort_keys`
ordering, and exactly one final LF.  Canonical serialization is a byte-level
gate; JSON object order is otherwise not a semantic signal.  Strings are not
implicitly Unicode-normalized.

The schema `$id` values are stable URNs under
`urn:repopress:contracts:v1:`.  All schemas use JSON Schema Draft 2020-12 and
declare an explicit `additionalProperties` policy for every object.

## Validation

The contract gate and fixture-hygiene checks are runnable from the repository
root:

```sh
# Syntax-check every schema.
find contracts/schemas/v1 -name '*.json' -print0 \
  | xargs -0 -n1 python3 -m json.tool

# Install the resolver used by the schema gate (once per environment).
python3 -m pip install -r requirements-contracts.txt

# Run the repository tests and gates.
python3 -m unittest discover -s tests -v
python3 scripts/validate_contracts.py
python3 scripts/check_fixture_hygiene.py

```

## Swift Core (M2 boundary)

`swift/` contains the Foundation-only `RepoPressCore` package. It is a
deterministic consumer of the M1 contracts, not a replacement for either app's
UI, persistence, credentials, or platform models. iOS and macOS integrations
must use app-owned adapters; keep `ArticleDraft`, `SiteProfile`, Keychain, and
database responsibilities in their existing application layers.

Run the boundary and Swift package checks from the repository root:

```sh
python3 scripts/check_swift_core_boundaries.py
swift test --package-path swift
```

The macOS CI job also cross-builds the package for an iOS Simulator SDK with an
independent SwiftPM scratch directory. This is source/build evidence only; it is
not signing, App Store, deployment, or Apple approval evidence.

For adoption, use a local package path first, verify both app adapters, then
move to an exact version tag only after the shared commit and tag exist. The
adapter boundary, minimum consumer checks, and rollback procedure are documented
in [docs/swift-core-adoption.md](docs/swift-core-adoption.md).

## .NET Core (M3 boundary)

`dotnet/src/RepoPress.Core` and its contract harness under
`dotnet/tests/RepoPress.Core.ContractTests` both target `net10.0`, the
same-generation LTS baseline as the new Windows App. Neither project declares
an explicit PackageReference or third-party NuGet dependency. Windows UI,
Git/process integration, Credential Manager, DPAPI, filesystem, and network
transport remain consumer-adapter responsibilities.

Run the C# boundary and harness checks from the repository root:

```sh
python3 scripts/check_dotnet_core_boundaries.py
dotnet build dotnet/tests/RepoPress.Core.ContractTests/RepoPress.Core.ContractTests.csproj -c Release
dotnet run --project dotnet/tests/RepoPress.Core.ContractTests/RepoPress.Core.ContractTests.csproj \
  -c Release --no-build
```

The Windows CI job uses a local `ProjectReference` during development. Move to an
approved package feed and exact version only after a reviewed commit exists, then
verify the minimum consumers. No feed URL, package version, signing, Windows App,
or deployment state is implied here. See
[docs/dotnet-core-adoption.md](docs/dotnet-core-adoption.md) for the adapter and
rollback workflow.
