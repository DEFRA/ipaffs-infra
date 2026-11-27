# Deployment hooks

Every script in this directory and its environment subdirectories must be idempotent. Rerunning a successful hook must make no changes and exit successfully. A hook must also be safe to rerun after a partial failure. Check the current state before changing it and skip work that is already complete.

Follow the deployment hook contract in [README.md](README.md). In particular, `DRY_RUN=true` must leave Azure unchanged. An absent resource is a successful outcome for a deletion hook. Report unexpected lookup and deletion failures so the pipeline can stop.
