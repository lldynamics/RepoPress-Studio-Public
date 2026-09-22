# Release Versioning

> Type: current operational guide. See the [documentation source rules](README.md).

[`Packaging/BuildVersion.xcconfig`](../Packaging/BuildVersion.xcconfig) is the only committed source for the app's
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` values.

[`script/build_and_run.sh`](../script/build_and_run.sh) and
[`script/package_direct_release.sh`](../script/package_direct_release.sh) read the
same values. The packaging path copies them into
`CFBundleShortVersionString` and `CFBundleVersion`. Metadata and archive gates
then compare the packaged `Info.plist` with the same file, so a stale or
independently hardcoded value fails the release checks.

The validation rules are implemented by [`script/check_build_version.sh`](../script/check_build_version.sh),
and the selected release checks are defined by [`script/release_checks.json`](../script/release_checks.json)
and run through [`script/check_release_gate.sh`](../script/check_release_gate.sh).

Before producing a Developer ID release or any other formal release candidate:

1. Set the intended public version in `MARKETING_VERSION`.
2. Increase `CURRENT_PROJECT_VERSION` to a positive integer not previously
   uploaded for that marketing version.
3. Run `./script/check_release_gate.sh --check build-version`.
4. Follow the [direct-release procedure](direct-release.md) to produce and
   validate the candidate. The full direct profile requires the signed,
   notarized artifacts to exist; it is not an artifact-free preflight.

This repository is SwiftPM-first and has no Xcode project to auto-increment the
build number. The committed value must therefore be advanced manually or by an
explicit CI release step before each formal release candidate. Local validation
cannot prove that a build number has never been published in the configured
update channel.

The current values are observable without building via
`bash script/check_build_version.sh --print-values`; the command prints the
two values from the authoritative config.
