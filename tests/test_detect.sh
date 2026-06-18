#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../scripts/run.sh" --source-only 2>/dev/null || true

fail=0
out="$(detect_violations "$HERE/fixtures/summary_violation.csv")"
echo "$out" | grep -qx "Performance_Bad" || { echo "FAIL: expected Performance_Bad"; fail=1; }
echo "$out" | grep -qx "Performance_HoldViolation" || { echo "FAIL: expected Performance_HoldViolation"; fail=1; }
echo "$out" | grep -qx "Performance_Incomplete" && { echo "FAIL: incomplete run must be filtered"; fail=1; } || true
[ "$(echo "$out" | grep -c .)" -eq 2 ] || { echo "FAIL: expected exactly 2 violators"; fail=1; }

if detect_violations "$HERE/fixtures/summary_pass.csv" >/dev/null; then
    echo "FAIL: pass csv should yield no violators (exit 1)"; fail=1
fi
[ "$fail" -eq 0 ] && echo "PASS test_detect" || exit 1
