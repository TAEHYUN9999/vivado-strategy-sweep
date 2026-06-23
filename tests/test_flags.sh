#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/../scripts/run.sh"
STRAT="$HERE/../scripts/strategies.txt"
fail=0

# defaults: IP prep on, Vitis auto
( source "$RUN" --source-only
  [[ "${PREP_IP:-}" == "1" ]]    || { echo "FAIL: PREP_IP default should be 1"; exit 1; }
  [[ "${VITIS_SRC:-}" == "auto" ]] || { echo "FAIL: VITIS_SRC default should be auto"; exit 1; }
) || fail=1

# --no-prep-ip
( source "$RUN" --source-only --no-prep-ip
  [[ "${PREP_IP:-}" == "0" ]] || { echo "FAIL: --no-prep-ip should set PREP_IP=0"; exit 1; }
) || fail=1

# --no-vitis
( source "$RUN" --source-only --no-vitis
  [[ "${VITIS_SRC-x}" == "" ]] || { echo "FAIL: --no-vitis should clear VITIS_SRC"; exit 1; }
) || fail=1

# baseline strategy present in strategies.txt
grep -qx "Vivado Implementation Defaults" "$STRAT" \
    || { echo "FAIL: 'Vivado Implementation Defaults' missing from strategies.txt"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS test_flags" || exit 1
