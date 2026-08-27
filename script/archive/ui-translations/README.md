# UI translation fragment archive

These incremental dictionaries were merged into
`script/ui_localization_translations.json` on 2026-08-27.

The localization synchronizer reads the root-level master dictionary plus any
new root-level `ui_*translations*.json` increments. Run
`python3 script/sync_ui_localizations.py --merge-reviewed-translations` to
merge and archive a later batch. Archived files are retained only for review
history and are not loaded at runtime.
