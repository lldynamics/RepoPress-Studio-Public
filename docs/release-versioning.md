# Release Versioning

`Packaging/BuildVersion.xcconfig` is the only committed source for the app's
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` values.

The SwiftPM packaging script copies these values into
`CFBundleShortVersionString` and `CFBundleVersion`. Metadata and archive gates
then compare the packaged `Info.plist` with the same file, so a stale or
independently hardcoded value fails the release checks.

Before producing a Developer ID release or any other formal release candidate:

1. Set the intended public version in `MARKETING_VERSION`.
2. Increase `CURRENT_PROJECT_VERSION` to a positive integer not previously
   uploaded for that marketing version.
3. Run `./script/check_release_gate.sh --check build-version`.
4. Run `./script/check_release_gate.sh --check swift-release-build` (or the
   complete release gate) from a clean checkout.

This repository is SwiftPM-first and has no Xcode project to auto-increment the
build number. The committed value must therefore be advanced manually or by an
explicit CI release step before each formal release candidate. Local validation
cannot prove that a build number has never been published in the configured
update channel.
