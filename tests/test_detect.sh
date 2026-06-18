#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../scripts/run.sh" --source-only 2>/dev/null || true

fail=0
out="$(detect_violations "$HERE/fixtures/summary_violation.csv")"
echo "$out" | grep -qx "Performance_Bad" || { echo "FAIL: expected Performance_Bad"; fail=1; }
[ "$(echo "$out" | grep -c .)" -eq 1 ] || { echo "FAIL: expected exactly 1 violator"; fail=1; }

if detect_violations "$HERE/fixtures/summary_pass.csv" >/dev/null; then
    echo "FAIL: pass csv should yield no violators (exit 1)"; fail=1
fi
[ "$fail" -eq 0 ] && echo "PASS test_detect" || exit 1
