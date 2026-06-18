#!/usr/bin/env bash
# =============================================================================
# run.sh -- one-command Vivado implementation-strategy sweep
#
# Runs synthesis once, then implements the design under several strategies,
# collects WNS/TNS/hold/utilization into a CSV, archives each bitstream +
# timing/utilization reports, and writes a .xsa (with bitstream) for the
# best-timing run.
#
# Usage:
#   ./run.sh --xpr /path/to/project.xpr [options]
#
# Options:
#   --xpr PATH              Vivado .xpr project (required unless $VB_XPR set)
#   --strategies "a,b,c"    Comma list of impl strategies
#                           (default: contents of strategies.txt, comments/blank ignored)
#   --jobs N                -jobs for launch_runs        (default: min(8, nproc))
#   --outdir DIR            Output dir                   (default: ./vivado_sweep_<timestamp>)
#   --synth-strategy NAME   Override synth_1 strategy    (default: leave project as-is)
#   --xsa MODE              best | all | none            (default: all)
#   --vitis-src DIR         Build Vitis platform+empty-C app per strategy from
#                           these C sources (-> <strategy>/vitis/, ready for JTAG)
#   --vitis PATH            Path to xsct binary          (default: auto-detect)
#   --dry-run               Validate project + strategies, print plan, launch nothing
#   --vivado PATH           Path to vivado binary        (default: auto-detect)
#   -h | --help
#
# Exit codes: 0 ok, 1 usage/setup error, 2 vivado run failed.
# =============================================================================
set -euo pipefail

# Allow tests to source this file for its functions without executing the sweep.
if [[ "${1:-}" == "--source-only" ]]; then __VB_SOURCE_ONLY=1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TCL="$SCRIPT_DIR/sweep.tcl"
STRAT_FILE="$SCRIPT_DIR/strategies.txt"

# ---- defaults -------------------------------------------------------------
XPR="${VB_XPR:-}"
STRATEGIES=""
JOBS=""
OUTDIR=""
SYNTH_STRATEGY=""
XSA_MODE="all"
DRYRUN="0"
VITIS_SRC=""
VITIS_BIN="${VITIS_BIN:-}"
VIVADO_BIN="${VIVADO_BIN:-}"
TS_ENABLED="1"
TS_MAX_PATHS="10"
TS_LOGIC_PCT="50"

die() { echo "ERROR: $*" >&2; exit 1; }

# detect_violations <summary.csv>: print each strategy with WNS<0 or WHS<0.
# Returns 0 if any printed, 1 otherwise.
detect_violations() {
    local csv="$1" found=1
    [[ -f "$csv" ]] || return 1
    # cols: 1=strategy 2=status 4=WNS_ns 6=WHS_ns
    while IFS=, read -r strat status _met wns _tns whs _rest; do
        [[ "$strat" == "strategy" ]] && continue
        [[ "$status" == "complete" ]] || continue
        awk -v w="$wns" -v h="$whs" 'BEGIN{exit !(w+0<0 || h+0<0)}' || continue
        echo "$strat"; found=0
    done < "$csv"
    return $found
}

# ---- arg parsing ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --xpr)            XPR="$2"; shift 2;;
        --strategies)     STRATEGIES="$2"; shift 2;;
        --jobs)           JOBS="$2"; shift 2;;
        --outdir)         OUTDIR="$2"; shift 2;;
        --synth-strategy) SYNTH_STRATEGY="$2"; shift 2;;
        --xsa)            XSA_MODE="$2"; shift 2;;
        --vitis-src)      VITIS_SRC="$2"; shift 2;;
        --vitis)          VITIS_BIN="$2"; shift 2;;
        --no-troubleshoot) TS_ENABLED="0"; shift;;
        --ts-max-paths)    TS_MAX_PATHS="$2"; shift 2;;
        --ts-logic-pct)    TS_LOGIC_PCT="$2"; shift 2;;
        --dry-run)        DRYRUN="1"; shift;;
        --source-only)     shift;;  # consumed by guard at top
        --vivado)         VIVADO_BIN="$2"; shift 2;;
        -h|--help)        sed -n '2,40p' "$0"; exit 0;;
        *) die "unknown option: $1 (use --help)";;
    esac
done

# Exit early if sourced with --source-only (for testing)
[[ "${__VB_SOURCE_ONLY:-0}" == "1" ]] && { return 0 2>/dev/null; exit 0; }

[[ -n "$XPR" ]] || die "no project given (--xpr PATH or \$VB_XPR)"
[[ -f "$XPR" ]] || die "xpr not found: $XPR"
XPR="$(readlink -f "$XPR")"

# ---- strategy list --------------------------------------------------------
if [[ -z "$STRATEGIES" ]]; then
    [[ -f "$STRAT_FILE" ]] || die "no --strategies and no $STRAT_FILE"
    STRATEGIES="$(grep -vE '^\s*(#|$)' "$STRAT_FILE" | paste -sd, -)"
fi
[[ -n "$STRATEGIES" ]] || die "strategy list is empty"

# ---- jobs -----------------------------------------------------------------
if [[ -z "$JOBS" ]]; then
    NPROC="$(nproc 2>/dev/null || echo 8)"
    JOBS=$(( NPROC < 8 ? NPROC : 8 ))
fi

# ---- outdir ---------------------------------------------------------------
if [[ -z "$OUTDIR" ]]; then
    OUTDIR="$(pwd)/vivado_sweep_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTDIR"
OUTDIR="$(readlink -f "$OUTDIR")"

# ---- locate vivado --------------------------------------------------------
if [[ -z "$VIVADO_BIN" ]]; then
    if command -v vivado >/dev/null 2>&1; then
        VIVADO_BIN="$(command -v vivado)"
    else
        for s in /home/th/tools/xilinx/Vivado/2023.1/settings64.sh \
                 /tools/Xilinx/Vivado/2023.1/settings64.sh \
                 /opt/Xilinx/Vivado/2023.1/settings64.sh; do
            [[ -f "$s" ]] && { # shellcheck disable=SC1090
                source "$s"; break; }
        done
        if command -v vivado >/dev/null 2>&1; then
            VIVADO_BIN="$(command -v vivado)"
        elif [[ -x /home/th/tools/xilinx/Vivado/2023.1/bin/vivado ]]; then
            VIVADO_BIN=/home/th/tools/xilinx/Vivado/2023.1/bin/vivado
        fi
    fi
fi
[[ -n "$VIVADO_BIN" && -x "$VIVADO_BIN" ]] || die "vivado not found (use --vivado PATH)"

# ---- run ------------------------------------------------------------------
export VB_XPR="$XPR"
export VB_STRATEGIES="$STRATEGIES"
export VB_JOBS="$JOBS"
export VB_OUTDIR="$OUTDIR"
export VB_SYNTH_STRATEGY="$SYNTH_STRATEGY"
export VB_XSA="$XSA_MODE"
export VB_DRYRUN="$DRYRUN"

echo "=================================================================="
echo " vivado : $VIVADO_BIN"
echo " xpr    : $XPR"
echo " strat  : $STRATEGIES"
echo " jobs   : $JOBS    xsa: $XSA_MODE    dry-run: $DRYRUN"
echo " outdir : $OUTDIR"
echo "=================================================================="

LOG="$OUTDIR/vivado_sweep.log"
set +e
"$VIVADO_BIN" -mode batch -notrace -source "$TCL" \
    -log "$OUTDIR/vivado.log" -journal "$OUTDIR/vivado.jou" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

if [[ "$rc" -ne 0 ]]; then
    echo "ERROR: vivado exited $rc (see $LOG)" >&2
    exit 2
fi

# ---- render summary -------------------------------------------------------
SUMMARY="$OUTDIR/summary.csv"
if [[ "$DRYRUN" != "1" && -f "$SUMMARY" ]]; then
    echo ""
    echo "================= RESULTS  ($SUMMARY) ================="
    if command -v column >/dev/null 2>&1; then
        column -s, -t "$SUMMARY"
    else
        cat "$SUMMARY"
    fi
    echo "======================================================"
    echo "Artifacts (.bit / .xsa / *.rpt) in: $OUTDIR"
fi

# ---- Vitis: platform + empty-C app build per strategy ---------------------
# Enabled by --vitis-src DIR. For each strategy folder that has a .xsa, build
# <strategy>/vitis/{vitispp platform, vitisap app}.  Open <strategy>/vitis in
# Vitis to program over JTAG.
if [[ "$DRYRUN" != "1" && -n "$VITIS_SRC" ]]; then
    if [[ -z "$VITIS_BIN" ]]; then
        for x in "$(command -v xsct 2>/dev/null)" \
                 /tools/Xilinx/Vitis/2023.1/bin/xsct \
                 /opt/Xilinx/Vitis/2023.1/bin/xsct \
                 /home/th/tools/xilinx/Vitis/2023.1/bin/xsct; do
            [[ -n "$x" && -x "$x" ]] && { VITIS_BIN="$x"; break; }
        done
    fi
    VBUILD="$SCRIPT_DIR/build_vitis.tcl"
    if [[ -z "$VITIS_BIN" || ! -x "$VITIS_BIN" ]]; then
        echo "WARNING: xsct not found, skipping Vitis build (use --vitis PATH)" >&2
    elif [[ ! -d "$VITIS_SRC" ]]; then
        echo "WARNING: --vitis-src '$VITIS_SRC' is not a directory, skipping Vitis" >&2
    elif [[ ! -f "$VBUILD" ]]; then
        echo "WARNING: build_vitis.tcl not found at $VBUILD, skipping Vitis" >&2
    else
        echo ""
        echo "================= VITIS BUILD (src=$VITIS_SRC) ================="
        for d in "$OUTDIR"/*/; do
            s="$(basename "$d")"
            xsa="$d$s.xsa"
            [[ -f "$xsa" ]] || continue
            echo ">>> [$s] Vitis platform + app build ..."
            rm -rf "${d}vitis"
            ( cd "$d" && "$VITIS_BIN" "$VBUILD" "./$s.xsa" "./vitis" "$VITIS_SRC" ) \
                > "${d}vitis_build.log" 2>&1
            if [[ -f "${d}vitis/vitisap/Debug/vitisap.elf" ]]; then
                echo ">>> [$s] OK -> ${d}vitis/vitisap/Debug/vitisap.elf"
            else
                echo ">>> [$s] FAILED (see ${d}vitis_build.log)" >&2
            fi
        done
        echo "==============================================================="
        echo "Open <strategy>/vitis in Vitis to program over JTAG."
    fi
fi

# ---- Timing troubleshoot (per violating strategy) -------------------------
if [[ "$DRYRUN" != "1" && "$TS_ENABLED" == "1" && -f "$SUMMARY" ]]; then
    TSCRIPT="$SCRIPT_DIR/troubleshoot.tcl"
    if violators="$(detect_violations "$SUMMARY")"; then
        echo ""
        echo "================= TIMING TROUBLESHOOT ================="
        while IFS= read -r s; do
            [[ -n "$s" ]] || continue
            rundir="$OUTDIR/$s"
            dcp="$(find "$rundir" -maxdepth 1 -name '*_routed.dcp' 2>/dev/null | head -1)"
            # fall back to the live project run dir if the dcp was not archived
            if [[ -z "$dcp" ]]; then
                src_run="$(awk -F, -v st="$s" '$1==st{print $13}' "$SUMMARY")"
                dcp="$(find "$src_run" -maxdepth 1 -name '*_routed.dcp' 2>/dev/null | head -1)"
            fi
            if [[ -z "$dcp" ]]; then
                echo ">>> [$s] no routed DCP found, skipping" >&2; continue
            fi
            tsout="$rundir/troubleshoot"
            echo ">>> [$s] extracting violations (logic_pct>=$TS_LOGIC_PCT, max_paths=$TS_MAX_PATHS) ..."
            "$VIVADO_BIN" -mode batch -notrace -source "$TSCRIPT" \
                -tclargs "$dcp" "$tsout" "$s" "$TS_MAX_PATHS" "$TS_LOGIC_PCT" \
                > "$tsout.log" 2>&1 || echo ">>> [$s] troubleshoot.tcl error (see $tsout.log)" >&2
            [[ -f "$tsout/violations.json" ]] && echo ">>> [$s] -> $tsout/violations.json"
        done <<< "$violators"
        echo "======================================================"
        echo "Run the vivado-build command's analysis step (or ask Claude) to turn"
        echo "each violations.json into report.md + xdc/ + hdl/ fix artifacts."
    else
        : > "$OUTDIR/TROUBLESHOOT_PASS"
        echo ""
        echo "Timing: all strategies meet WNS/WHS >= 0 — no troubleshoot needed (TROUBLESHOOT_PASS)."
    fi
fi

echo "DONE."
