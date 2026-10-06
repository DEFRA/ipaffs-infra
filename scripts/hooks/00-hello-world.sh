#!/usr/bin/env bash
# Smoke test for the RunHooks stage: proves hooks are discovered and run.
set -euo pipefail

echo "Hello world from ${ENVIRONMENT} (DryRun=${DRY_RUN})"
