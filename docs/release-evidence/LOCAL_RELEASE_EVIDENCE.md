# Local Release Evidence Bundle

This file documents how to generate local release evidence. Generated snapshots are local historical artifacts, not proof that the current tree still passes release gates.

- Generate a timestamped snapshot: `script/export_release_evidence_bundle.sh`
- Default output directory: `docs/release-evidence/snapshots/`
- Generate at a custom path: `script/export_release_evidence_bundle.sh --output <path>`

The snapshot directory is intentionally ignored by Git. Generated bundles include every local gate command and its exit code; failed gates remain visible instead of being replaced by stale pass text.
