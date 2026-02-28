#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX_CSV="${ROOT_DIR}/qa/mcp_tool_acceptance_matrix.csv"
RUN_LOG_CSV="${ROOT_DIR}/qa/mcp_tool_run_log.csv"

python3 "${ROOT_DIR}/scripts/mcp_long_runner.py" \
  --matrix "${MATRIX_CSV}" \
  --run-log "${RUN_LOG_CSV}" \
  --round 1 \
  --loop
