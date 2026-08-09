# .NET Core adoption (M3)

`dotnet/src/RepoPress.Core` and the
`dotnet/tests/RepoPress.Core.ContractTests` project both target `net10.0`, the
same-generation LTS baseline as the new Windows App. The Core contains
deterministic contract behavior only; both projects declare no explicit
PackageReference or third-party NuGet dependency. The harness is a local
verification tool, not a Windows application or a deployment artifact.

## Adapter boundary

Windows-specific concerns remain in the consumer adapter. Do not move these into
the shared Core target:

- WPF/WinUI controls, dispatchers, and application lifetime
- Git process/CLI integration
- Windows Credential Manager, DPAPI, and other secret storage
- Windows filesystem policy and user-profile paths
- Network clients, HTTP transport, retries, and service authentication

The Core package may use deterministic BCL types such as `System`, generic
collections, and text/value helpers. The boundary gate rejects platform UI,
registry, filesystem, HTTP, process, credential, and profile-path dependencies.

## Dependency sequence

1. **Local `ProjectReference` first.** During development, reference the checked
   out `RepoPress.Core` project from the consumer adapter. Run the harness and
   the adapter's focused tests against the M1 fixtures; keep the reference local
   while the API is changing.
2. **Review and commit.** Review the Core, fixtures, and adapter together, then
   create the normal shared repository commit. A local build is not proof of a
   published package.
3. **Select the approved package feed/version.** After the reviewed commit is
   available, replace the local reference with the release owner's approved
   package feed and exact package version. This document intentionally does not
   invent a feed URL, package ID, or version.
4. **Verify consumers.** Restore/build the Windows consumer, run its adapter and
   contract tests, and rerun the shared boundary gate. Only after the commit and
   package version exist is formal consumer adoption evidence available.

## Verification commands

From the repository root:

```sh
python3 -m unittest discover -s tests -v
python3 scripts/check_dotnet_core_boundaries.py
python3 scripts/validate_contracts.py
python3 scripts/check_fixture_hygiene.py
dotnet build dotnet/tests/RepoPress.Core.ContractTests/RepoPress.Core.ContractTests.csproj -c Release
dotnet run --project dotnet/tests/RepoPress.Core.ContractTests/RepoPress.Core.ContractTests.csproj \
  -c Release --no-build
```

These commands provide source, contract, and harness evidence. They do not prove
Windows UI behavior, signing, installer state, credentials, network deployment,
or Store certification.

## Rollback

If a consumer regression appears:

1. Stop the consumer rollout and preserve the failing contract case and adapter
   diagnostic.
2. Point the consumer back to the last known-good `ProjectReference` checkout or
   approved package version; do not weaken the contract or boundary gate.
3. Rerun the harness, boundary gate, and affected Windows adapter tests.
4. Revert the adapter dependency change in a reviewable commit while preserving
   Windows UI, Git, Credential Manager, DPAPI, filesystem, and network behavior.
5. Investigate the Core/adapter pair on a new branch, then repeat local
   `ProjectReference` verification before proposing a new commit and package
   version.

Formal package-feed/version dependencies and minimum-consumer verification must
wait for a reviewed commit and an actual approved package version; an uncommitted
local build is not release evidence.
