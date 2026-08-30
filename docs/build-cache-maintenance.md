# Local build-cache maintenance

RepoPress keeps dependency caches and performance evidence by default. Local
SwiftPM products, downloaded artifacts, dependency checkouts, benchmarks, and
Instruments traces are never selected for automatic cleanup.

Inventory the current `.build` directory:

```bash
python3 script/manage_build_cache.py
```

Select exact reproducible outputs in dry-run mode first:

```bash
python3 script/manage_build_cache.py \
  --remove coverage \
  --remove swift-test-shards
```

Only add `--apply` after checking the JSON paths and byte counts. The script
rejects symlinks, paths outside this repository's `.build` directory, SwiftPM
dependency caches, build products, and performance evidence. Removing a
selected directory discards its local diagnostics and forces that gate to
rebuild them; it does not modify source files.
