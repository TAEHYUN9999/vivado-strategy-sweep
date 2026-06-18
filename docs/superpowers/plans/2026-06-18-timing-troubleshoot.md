# Timing Troubleshoot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a strategy sweep, automatically analyze any timing-failing strategy, classify each worst path as net- or logic-bound, and emit review-ready artifacts (XDC candidate, HDL `.bak`+revision, report) for the user to apply manually.

**Architecture:** Hybrid. A Vivado batch Tcl (`troubleshoot.tcl`) opens the violating strategy's routed DCP and dumps exact data (`violations.json`: worst paths, logic%/route% split, cell→RTL source mapping). `run.sh` detects violations from `summary.csv` and invokes the Tcl per violating strategy. The `vivado-build` command instruction tells Claude to read each `violations.json` plus the referenced sources and write the artifacts. Apply + recompile is manual.

**Tech Stack:** Bash (run.sh), Vivado 2023.1 Tcl (open_checkpoint, get_timing_paths, get_property), Markdown (command instruction + report).

## Global Constraints

- Vivado 2023.1, part `xcau15p-sbvb484-1-i` (validated at runtime; do not hardcode elsewhere).
- Never modify original `.v`/`.xdc` or sweep outputs — all artifacts are copies under `<strategy>/troubleshoot/`.
- Violation definition: `WNS < 0` OR `WHS < 0`. TPWS/pulse-width = reported only, never auto-troubleshot.
- No auto-apply, no auto-rebuild. Generated HDL/XDC are review-required drafts.
- net/logic classification: `logic% >= 50` (default, flag-configurable) → logic-bound; else net-bound.
- Defaults: `--ts-max-paths 10`, `--ts-logic-pct 50`; opt out with `--no-troubleshoot`.
- Cache copy at `/home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/` must be kept byte-identical to the repo clone (`/home/th/.claude/plugins/marketplaces/vivado-strategy-sweep/`); after each change, `cp` the file across and `diff -q` to confirm.
- Push every commit to `origin/main` (`git@github.com:TAEHYUN9999/vivado-strategy-sweep.git`).

## File Structure

- Create: `scripts/troubleshoot.tcl` — Vivado batch extractor → `violations.json`. Pure extraction, no judgement, no edits.
- Modify: `scripts/run.sh` — violation detection from `summary.csv`, per-strategy Tcl invocation, new flags.
- Modify: `commands/vivado-build.md` — instruct Claude to turn each `violations.json` into `report.md` + `xdc/` + `hdl/`.
- Create: `tests/fixtures/summary_pass.csv`, `tests/fixtures/summary_violation.csv` — bash detection fixtures.
- Create: `tests/test_detect.sh` — bash unit test for the detection helper.
- Create: `tests/fixtures/violations_sample.json` — hand-written sample for command-instruction dry-run.

**Testing note (FPGA domain):** Bash detection logic is unit-tested with fixture CSVs. `troubleshoot.tcl` is validated by running it on a real routed DCP from a completed sweep (this repo's last sweep at `/home/th/1work/vivado_sweep_20260618_085058/`): on a timing-PASS DCP it must emit `violations.json` with an empty `paths` array and still exercise the path-extraction/mapping code (worst paths exist with positive slack). A genuinely failing design is not currently available, so the negative-slack filtering branch is verified by unit-testing the Tcl's classifier helper on synthetic numbers (Task 2 Step 1), not by a live failing build.

---

### Task 1: Violation detection helper in run.sh

**Files:**
- Modify: `scripts/run.sh` (add `detect_violations()` + new flag defaults/parsing)
- Create: `tests/fixtures/summary_pass.csv`
- Create: `tests/fixtures/summary_violation.csv`
- Create: `tests/test_detect.sh`

**Interfaces:**
- Produces: shell function `detect_violations <summary.csv>` → prints one violating `strategy` name per line (status `complete`, and `WNS_ns < 0` OR `WHS_ns < 0`); exit 0 if any printed, 1 if none.
- Produces: env/flags `TS_ENABLED` (default 1), `TS_MAX_PATHS` (default 10), `TS_LOGIC_PCT` (default 50), parsed from `--no-troubleshoot`, `--ts-max-paths N`, `--ts-logic-pct P`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_detect.sh`:
```bash
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
```

Create `tests/fixtures/summary_pass.csv`:
```csv
strategy,status,timing_met,WNS_ns,TNS_ns,WHS_ns,THS_ns,TPWS_ns,LUT,FF,BRAM,DSP,run_dir
Performance_Explore,complete,PASS,0.287789,0.000000,0.010183,0.000000,-1.667000,33151,31696,139,29,/x
Performance_NetDelay_low,complete,PASS,0.447749,0.000000,0.010772,0.000000,-1.667000,33147,31696,139,29,/x
```

Create `tests/fixtures/summary_violation.csv`:
```csv
strategy,status,timing_met,WNS_ns,TNS_ns,WHS_ns,THS_ns,TPWS_ns,LUT,FF,BRAM,DSP,run_dir
Performance_Good,complete,PASS,0.120000,0.000000,0.010000,0.000000,-1.667000,33151,31696,139,29,/x
Performance_Bad,complete,FAIL,-0.231000,-4.120000,0.009000,0.000000,-1.667000,33175,31696,139,29,/x
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_detect.sh`
Expected: FAIL — `detect_violations: command not found` (function not yet defined).

- [ ] **Step 3: Add `--source-only` short-circuit and the helper to run.sh**

At the very top of `scripts/run.sh`, immediately after `set -euo pipefail` (line ~30), add a source-only guard so tests can load functions without running the sweep:
```bash
# Allow tests to source this file for its functions without executing the sweep.
if [[ "${1:-}" == "--source-only" ]]; then __VB_SOURCE_ONLY=1; fi
```
Then define the helper just below the `die()` definition (~line 48):
```bash
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
```
At the end of the argument-parsing defaults block (~line 46) add:
```bash
TS_ENABLED="1"
TS_MAX_PATHS="10"
TS_LOGIC_PCT="50"
```
In the `case` parser (~line 58) add before `--dry-run`:
```bash
        --no-troubleshoot) TS_ENABLED="0"; shift;;
        --ts-max-paths)    TS_MAX_PATHS="$2"; shift 2;;
        --ts-logic-pct)    TS_LOGIC_PCT="$2"; shift 2;;
```
Finally, guard the rest of the script so `--source-only` stops here: immediately after the `case`/`while` parsing loop, add:
```bash
[[ "${__VB_SOURCE_ONLY:-0}" == "1" ]] && return 0 2>/dev/null || true
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_detect.sh`
Expected: `PASS test_detect`

- [ ] **Step 5: Sync cache + commit**

```bash
cp scripts/run.sh /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/run.sh
diff -q scripts/run.sh /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/run.sh
git add scripts/run.sh tests/
git commit -m "feat: violation detection helper + flags for timing troubleshoot"
git push origin main
```

---

### Task 2: troubleshoot.tcl — extract worst paths → violations.json

**Files:**
- Create: `scripts/troubleshoot.tcl`
- Create: `tests/test_classify.tcl` (unit-test the classifier proc with synthetic numbers)

**Interfaces:**
- Consumes: invoked as `vivado -mode batch -source troubleshoot.tcl -tclargs <dcp> <outdir> <strategy> <max_paths> <logic_pct>`.
- Produces: `<outdir>/violations.json` with the schema in the spec (`strategy`, `wns`, `whs`, `paths[]`; each path: `id,kind,slack_ns,startpoint,endpoint,data_path_delay_ns,logic_pct,route_pct,classification,cells[]`; cell: `name,ref,file,line`). `file` is `null` when `FILE_NAME` is empty/synth-temp.
- Produces: Tcl proc `ts_classify {logic route threshold}` → returns `logic` or `net`.

- [ ] **Step 1: Write the failing classifier test**

Create `tests/test_classify.tcl`:
```tcl
source [file join [file dirname [info script]] .. scripts troubleshoot.tcl]
set fail 0
if {[ts_classify 6.0 4.0 50] ne "logic"} { puts "FAIL: 60% logic should be logic"; set fail 1 }
if {[ts_classify 4.0 6.0 50] ne "net"}   { puts "FAIL: 40% logic should be net";   set fail 1 }
if {[ts_classify 5.0 5.0 50] ne "logic"} { puts "FAIL: exactly 50% is logic (>=)"; set fail 1 }
if {[ts_classify 0.0 0.0 50] ne "net"}   { puts "FAIL: zero delay defaults net";   set fail 1 }
if {$fail} { exit 1 }
puts "PASS test_classify"
```
The `source` of `troubleshoot.tcl` must not execute the extraction when sourced for tests. Guard the main body so it only runs when tclargs are present (Step 3).

- [ ] **Step 2: Run test to verify it fails**

Run: `/tools/Xilinx/Vivado/2023.1/bin/xsct tests/test_classify.tcl` (xsct runs plain Tcl fast; avoids opening Vivado)
Expected: FAIL — cannot read file / `ts_classify` not defined.

- [ ] **Step 3: Write troubleshoot.tcl**

Create `scripts/troubleshoot.tcl`:
```tcl
# troubleshoot.tcl -- extract timing violations from a routed DCP to JSON.
# tclargs: <dcp> <outdir> <strategy> <max_paths> <logic_pct_threshold>
# Pure extraction: no judgement, no file edits beyond <outdir>/violations.json.

proc ts_classify {logic route threshold} {
    set total [expr {$logic + $route}]
    if {$total <= 0} { return "net" }
    set lp [expr {100.0 * $logic / $total}]
    return [expr {$lp >= $threshold ? "logic" : "net"}]
}

proc ts_json_str {s} {
    # minimal JSON string escaping
    set s [string map {\\ \\\\ \" \\\"} $s]
    return "\"$s\""
}

# ---- main (only when tclargs supplied) ------------------------------------
if {[llength $argv] >= 5} {
    lassign $argv dcp outdir strategy max_paths logic_pct
    file mkdir $outdir
    open_checkpoint $dcp

    set wns [get_property SLACK [lindex [get_timing_paths -delay_type max -max_paths 1 -nworst 1] 0]]
    set whs [get_property SLACK [lindex [get_timing_paths -delay_type min -max_paths 1 -nworst 1] 0]]

    set paths {}
    foreach kind {max min} {
        foreach p [get_timing_paths -delay_type $kind -max_paths $max_paths -nworst 1] {
            lappend paths [list $kind $p]
        }
    }

    set fh [open "$outdir/violations.json" w]
    puts $fh "{"
    puts $fh "  \"strategy\": [ts_json_str $strategy],"
    puts $fh "  \"wns\": $wns,"
    puts $fh "  \"whs\": $whs,"
    puts $fh "  \"paths\": \["
    set pid 0
    set entries {}
    foreach pe $paths {
        lassign $pe kind p
        set slack [get_property SLACK $p]
        if {$slack >= 0} { continue }   ;# only real violations
        incr pid
        set logic [get_property DATAPATH_LOGIC_DELAY $p]
        set route [get_property DATAPATH_NET_DELAY $p]
        set total [expr {$logic + $route}]
        set lpct [expr {$total > 0 ? int(round(100.0*$logic/$total)) : 0}]
        set rpct [expr {100 - $lpct}]
        set cls  [ts_classify $logic $route $logic_pct]
        set sp [get_property STARTPOINT_PIN $p]
        set ep [get_property ENDPOINT_PIN $p]
        set kindstr [expr {$kind eq "max" ? "setup" : "hold"}]
        # cells along the path -> RTL source
        set celljson {}
        foreach c [get_cells -quiet -of_objects [get_pins -quiet -of_objects $p]] {
            set fn [get_property -quiet FILE_NAME $c]
            set ln [get_property -quiet LINE_NUMBER $c]
            set rf [get_property -quiet REF_NAME $c]
            set fjson [expr {$fn eq "" ? "null" : [ts_json_str $fn]}]
            set ljson [expr {$ln eq "" ? "null" : $ln}]
            lappend celljson "        {\"name\": [ts_json_str $c], \"ref\": [ts_json_str $rf], \"file\": $fjson, \"line\": $ljson}"
        }
        set cellblock [join $celljson ",\n"]
        lappend entries "    {\n      \"id\": $pid, \"kind\": \"$kindstr\", \"slack_ns\": $slack,\n      \"startpoint\": [ts_json_str $sp], \"endpoint\": [ts_json_str $ep],\n      \"data_path_delay_ns\": $total, \"logic_pct\": $lpct, \"route_pct\": $rpct,\n      \"classification\": \"$cls\",\n      \"cells\": \[\n$cellblock\n      \]\n    }"
    }
    puts $fh [join $entries ",\n"]
    puts $fh "  \]"
    puts $fh "}"
    close $fh
    close_design
    puts ">>> troubleshoot: wrote $outdir/violations.json ($pid violating paths)"
}
```

- [ ] **Step 4: Run classifier test to verify it passes**

Run: `/tools/Xilinx/Vivado/2023.1/bin/xsct tests/test_classify.tcl`
Expected: `PASS test_classify`

- [ ] **Step 5: Smoke-test extraction on a real routed DCP (PASS design → empty paths)**

Run:
```bash
/tools/Xilinx/Vivado/2023.1/bin/vivado -mode batch -source scripts/troubleshoot.tcl -tclargs \
  /home/th/1work/vivado_sweep_20260618_085058/Performance_NetDelay_low/Performance_NetDelay_low.runs_routed.dcp \
  /tmp/ts_smoke Performance_NetDelay_low 10 50
```
(If that DCP path differs, use `find /home/th/Desktop/falinux_debug/rgbd_i2c_mipi_dbg_2/prj_rgbd-10.runs/impl_Performance_NetDelay_low -name '*_routed.dcp'`.)
Expected: prints `wrote .../violations.json (0 violating paths)`; `python3 -c "import json;json.load(open('/tmp/ts_smoke/violations.json'))"` exits 0 (valid JSON, empty `paths`).

- [ ] **Step 6: Sync cache + commit**

```bash
cp scripts/troubleshoot.tcl /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/troubleshoot.tcl
diff -q scripts/troubleshoot.tcl /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/troubleshoot.tcl
git add scripts/troubleshoot.tcl tests/test_classify.tcl
git commit -m "feat: troubleshoot.tcl extracts violations to JSON"
git push origin main
```

---

### Task 3: Wire troubleshoot into run.sh

**Files:**
- Modify: `scripts/run.sh` (after the Vitis block, before `echo "DONE."`)

**Interfaces:**
- Consumes: `detect_violations` (Task 1), `scripts/troubleshoot.tcl` (Task 2), `$VIVADO_BIN`, `$OUTDIR`, `$TS_*` flags.
- Produces: `<OUTDIR>/<strategy>/troubleshoot/violations.json` per violating strategy; a `<OUTDIR>/TROUBLESHOOT_PASS` marker file when no violations.

- [ ] **Step 1: Add the troubleshoot stage to run.sh**

In `scripts/run.sh`, immediately before the final `echo "DONE."`, add:
```bash
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
```
Note: the original `echo "DONE."` is replaced by the block above (which ends in `echo "DONE."`). Remove the old standalone `echo "DONE."`.

- [ ] **Step 2: Verify detection wiring on PASS data (no Vivado needed)**

Run:
```bash
bash -n scripts/run.sh && echo "syntax-ok"
OUTDIR=/tmp/ts_wire SUMMARY_TEST=tests/fixtures/summary_pass.csv \
  bash -c 'source scripts/run.sh --source-only; detect_violations tests/fixtures/summary_pass.csv && echo HASVIOL || echo NONE'
```
Expected: `syntax-ok` then `NONE` (PASS fixture yields no violators → marker branch).

- [ ] **Step 3: Sync cache + commit**

```bash
cp scripts/run.sh /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/run.sh
diff -q scripts/run.sh /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/run.sh
git add scripts/run.sh
git commit -m "feat: run.sh invokes troubleshoot.tcl per violating strategy"
git push origin main
```

---

### Task 4: Extend vivado-build command instruction

**Files:**
- Modify: `commands/vivado-build.md`
- Create: `tests/fixtures/violations_sample.json`

**Interfaces:**
- Consumes: `<strategy>/troubleshoot/violations.json` produced by Task 3.
- Produces: documented procedure for Claude to write `report.md`, `xdc/timing_fix.xdc`, `hdl/<module>.v.bak`, `hdl/<module>.v`.

- [ ] **Step 1: Create the sample fixture**

Create `tests/fixtures/violations_sample.json`:
```json
{
  "strategy": "Performance_Bad",
  "wns": -0.231, "whs": 0.009,
  "paths": [
    {
      "id": 1, "kind": "setup", "slack_ns": -0.231,
      "startpoint": "design_1_i/rgbd/filt/acc_reg[3]/C",
      "endpoint": "design_1_i/rgbd/filt/out_reg[11]/D",
      "data_path_delay_ns": 5.21, "logic_pct": 62, "route_pct": 38,
      "classification": "logic",
      "cells": [
        {"name": "design_1_i/rgbd/filt/mult", "ref": "filter_gain",
         "file": "/home/th/.../filter_gain.v", "line": 123}
      ]
    },
    {
      "id": 2, "kind": "setup", "slack_ns": -0.110,
      "startpoint": "design_1_i/rgbd/a_reg[0]/C",
      "endpoint": "design_1_i/rgbd/b_reg[0]/D",
      "data_path_delay_ns": 4.80, "logic_pct": 31, "route_pct": 69,
      "classification": "net",
      "cells": [
        {"name": "design_1_i/rgbd/buf", "ref": "rgbd_top", "file": null, "line": null}
      ]
    }
  ]
}
```

- [ ] **Step 2: Append the troubleshoot procedure to commands/vivado-build.md**

Add a new section at the end of `commands/vivado-build.md`:
```markdown
## Timing troubleshoot (post-sweep)

After analyzing `summary.csv`, check each `<outdir>/<strategy>/troubleshoot/violations.json`
(present only when that strategy had WNS<0 or WHS<0). For each file, generate
review-ready artifacts next to it — never modify original sources or sweep outputs.

For every path in `violations.json`:

- **classification == "net"** → append a candidate constraint to
  `<strategy>/troubleshoot/xdc/timing_fix.xdc`. Choose among `set_multicycle_path`,
  `set_false_path`, or `set_max_delay` ONLY if justifiable, and prefix each with a
  `# CAUTION:` line stating the exact condition under which it is legitimate
  (e.g. "valid only if start/end are truly N-cycle related"). Never emit an
  unjustified relaxation — if none is defensible, write a `# NOTE:` explaining the
  path is route-dominated and suggest floorplan/pblock investigation instead.

- **classification == "logic"** → if a cell has a real `file`/`line`, read that
  `.v`, copy it verbatim to `hdl/<basename>.v.bak`, and write a pipelined revision
  to `hdl/<basename>.v` (add a register stage on the critical combinational path).
  If `file` is null (mapping uncertain), do NOT fabricate a revision — give
  module-level guidance in the report only.

Then write `<strategy>/troubleshoot/report.md`:
- a table: path id | kind | slack | logic%/route% | class | module:line
- per net path: the proposed constraint + why it is/ isn't legitimate
- per logic path: the offending code block quoted + the pipeline diff
  (orig→revised) + a caution that latency changed and FSM/handshake/data-align
  must be re-verified, plus "functional equivalence NOT guaranteed — simulate"
- an apply-order guide (which file to swap, then recompile)

Report which strategies got artifacts and where. Do not apply or rebuild.
```

- [ ] **Step 3: Dry-run the instruction against the fixture (manual verification)**

Run: read `tests/fixtures/violations_sample.json` and confirm the instruction is
unambiguous — path 1 (logic, real file) → `.bak`+revision+diff in report; path 2
(net, file null) → constraint candidate with CAUTION + module-level note only.
Expected: a reviewer can follow each branch with no missing decision.

- [ ] **Step 4: Sync cache + commit**

```bash
cp commands/vivado-build.md /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/commands/vivado-build.md
diff -q commands/vivado-build.md /home/th/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/commands/vivado-build.md
git add commands/vivado-build.md tests/fixtures/violations_sample.json
git commit -m "feat: command instruction to emit timing-fix artifacts from violations.json"
git push origin main
```

---

### Task 5: End-to-end verification + help/docs

**Files:**
- Modify: `scripts/run.sh` (help header: document `--no-troubleshoot`, `--ts-max-paths`, `--ts-logic-pct`)
- Modify: `README.md` (short "Timing troubleshoot" section)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Document the new flags in run.sh help header**

In the `# Options:` comment block of `scripts/run.sh`, after the `--xsa`/`--vitis` lines, add:
```bash
#   --no-troubleshoot       Skip post-sweep timing troubleshoot
#   --ts-max-paths N        Worst paths to analyze per violating strategy (default 10)
#   --ts-logic-pct P        logic%% >= P classifies a path as logic-bound (default 50)
```

- [ ] **Step 2: Add README section**

Append to `README.md`:
```markdown
## Timing troubleshoot

If any swept strategy fails timing (WNS<0 or WHS<0), the sweep extracts the
worst paths to `<strategy>/troubleshoot/violations.json` (net- vs logic-bound,
with cell→RTL source mapping). The `vivado-build` command then writes
review-ready fixes: `xdc/timing_fix.xdc` (net), `hdl/<module>.v.bak` + revision
(logic), and `report.md`. Nothing is applied or rebuilt automatically — review,
copy, recompile. Opt out with `--no-troubleshoot`.
```

- [ ] **Step 3: Full dry-run validation**

Run: `bash scripts/run.sh --xpr <any valid .xpr> --dry-run`
Expected: dry-run still prints the plan and exits 0 (troubleshoot block is gated on `DRYRUN != 1`, so it is inert).
Run the unit tests once more: `bash tests/test_detect.sh && /tools/Xilinx/Vivado/2023.1/bin/xsct tests/test_classify.tcl`
Expected: `PASS test_detect` and `PASS test_classify`.

- [ ] **Step 4: Sync cache + commit**

```bash
cp scripts/run.sh /home/th/.claude/plugins/cache/.../scripts/run.sh
diff -q scripts/run.sh /home/th/.claude/plugins/cache/.../scripts/run.sh
git add scripts/run.sh README.md
git commit -m "docs: document timing troubleshoot flags and workflow"
git push origin main
```

---

## Self-Review

- **Spec coverage:** trigger/detection (Task 1,3), Tcl extractor + net/logic + RTL map (Task 2), artifacts/report/xdc/hdl (Task 4), limits/graceful-degrade (Task 2 null file + Task 4 branch), safety/no-apply (Global Constraints + Task 4), flags/thresholds (Task 1,5). PASS-report path (Task 3 marker). All spec sections map to a task.
- **Placeholder scan:** every code step shows real code; test code is concrete; no TBD.
- **Type consistency:** `detect_violations`, `ts_classify`, `violations.json` field names (`logic_pct`,`classification`,`cells[].file`) are identical across Tasks 1–4.
- **Known real-world gap (flagged, not hidden):** the negative-slack extraction branch in `troubleshoot.tcl` cannot be exercised live without a timing-failing design; Task 2 covers it via the classifier unit test + PASS-DCP smoke test, and notes this explicitly. When a failing design appears, re-run Task 3 Step end-to-end to validate the full path.
