# Local build-cache maintenance

RepoPress keeps dependency caches and performance evidence by default. Local
SwiftPM products, downloaded artifacts, dependency checkouts, benchmarks, and
Instruments traces are never selected for automatic cleanup.

Inventory the current `.build` directory together with the Tauri desktop
prototype's reproducible `node_modules`, frontend `dist`, and Rust `target`
outputs:

```bash
python3 script/manage_build_cache.py
```

Select exact reproducible outputs in dry-run mode first:

```bash
python3 script/manage_build_cache.py \
  --remove coverage \
  --remove swift-test-shards \
  --remove tauri-dist
```

Only add `--apply` after checking the JSON paths and byte counts. The script
rejects symlinks, paths outside this repository, SwiftPM dependency caches,
unclassified build products, and performance evidence. The additional exact
Tauri selectors are `tauri-node-modules`, `tauri-dist`, and
`tauri-rust-target`. Removing a selected directory discards reproducible local
outputs and forces the corresponding toolchain to rebuild them; it does not
modify source files.
