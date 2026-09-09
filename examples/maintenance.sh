#!/usr/bin/env bash
# Invoke only for a deliberate maintenance job. ORACLE_HOME/ORACLE_SID must exist.
set -euo pipefail
umask 077
[[ $# -eq 2 ]] || { echo 'Usage: maintenance.sh CONFIG NEW_PLAN_DIRECTORY' >&2; exit 2; }
tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
bash "$tool_dir/redoctl.sh" plan --config "$1" --output "$2"
# Failure terminates the job. A failed apply retains its attempted marker and
# logs; inspect it and explicitly resume that same plan.
bash "$tool_dir/redoctl.sh" apply --plan "$2"
