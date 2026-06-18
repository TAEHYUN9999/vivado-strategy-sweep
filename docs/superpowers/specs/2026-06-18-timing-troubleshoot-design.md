# Timing Troubleshoot — Design

**Date:** 2026-06-18
**Plugin:** vivado-strategy-sweep
**Status:** Approved (brainstorming) → ready for implementation plan

## 1. Goal

After the strategy sweep, if any strategy fails timing (`WNS < 0` OR
`WHS < 0`), automatically analyze the worst paths, classify each as
**net-delay-bound** or **logic-delay-bound**, and produce *review-ready
artifacts* the user applies manually:

- net-bound → an XDC constraint candidate file
- logic-bound → the offending `.v` backed up + a pipelined revision
- a human-readable troubleshooting **report**

The plugin **never applies fixes or re-builds**. Apply + recompile is the
user's manual step. This is an assistant, not an auto-repair loop.

## 2. Automation level (decided)

- Analysis + artifact generation (XDC candidate, HDL `.bak` + revision,
  report) = **automatic**
- Apply + recompile = **manual** (user reviews, copies files, re-runs)

## 3. Trigger (decided)

Integrated into the existing `run.sh` sweep. After `summary.csv` is
written:

- If no strategy has `WNS < 0` or `WHS < 0` → write a one-line **PASS**
  report, do nothing else.
- Else, for each violating strategy → run the troubleshoot flow.

`TPWS` / pulse-width violations are **reported only**, not auto-troubleshot
(they are clock/constraint-definition issues, not fixable by path edits).

## 4. Architecture (Approach A: hybrid)

```
run.sh sweep → summary.csv → detect violating strategies (WNS<0 || WHS<0)
   │  none → PASS report, stop
   ▼
[Vivado Tcl] troubleshoot.tcl  (per violating strategy)
   ├─ open <strategy> routed DCP
   ├─ report_timing -max_paths N  (worst setup + hold)
   ├─ per path: Data Path Delay "logic A% / route B%" → classify net/logic
   ├─ per path cells: get_property {FILE_NAME LINE_NUMBER REF_NAME} → RTL map
   └─ dump <strategy>/troubleshoot/violations.json
   ▼
[Claude] (inside vivado-build command flow)
   reads violations.json + referenced .v / .xdc, then:
   ├─ net-bound  → xdc/timing_fix.xdc  (candidate constraints + CAUTION notes)
   ├─ logic-bound→ hdl/<module>.v.bak + hdl/<module>.v  (pipelined revision)
   └─ report.md  (the human-facing summary)
   ▼
user: review report → manually apply → recompile
```

**Division of labour:** Vivado produces exact timing + source-mapping data
(it alone can). Claude does the RTL judgement, code revision, and report
(a script cannot). This rides on the existing flow where the command
already analyzes `summary.csv`.

### net vs logic classification

From `report_timing`: `Data Path Delay: x.xxx ns (logic A%, route B%)`.
- `logic% >= THRESHOLD` (default 50) → **logic-bound → HDL**
- else → **net-bound → XDC**

`THRESHOLD` and `-max_paths` (default 10) are configurable via flags.

## 5. Components

### 5.1 `scripts/troubleshoot.tcl` (new, Vivado batch)
Inputs: routed DCP path (or run dir), out dir, max_paths, logic threshold.
Outputs: `violations.json`. Pure extraction — no judgement, no file edits.

`violations.json` schema:
```json
{
  "strategy": "Performance_X",
  "wns": -0.123, "whs": 0.011,
  "paths": [
    {
      "id": 1, "kind": "setup", "slack_ns": -0.123,
      "startpoint": "...", "endpoint": "...",
      "data_path_delay_ns": 5.21, "logic_pct": 62, "route_pct": 38,
      "classification": "logic",
      "cells": [
        {"name": "design_1_i/.../mult_reg[7]",
         "ref": "filter_gain", "file": "/abs/path/filter_gain.v", "line": 123}
      ]
    }
  ]
}
```
If `FILE_NAME` is empty / a synth temp (optimization merged the cell),
emit `"file": null` and let the consumer degrade to module-level guidance.

### 5.2 `run.sh` integration
After the summary block (and after the optional Vitis block), a
`--troubleshoot` path (default ON when a violation exists) invokes
`troubleshoot.tcl` per violating strategy and writes `violations.json`.
New flags: `--ts-max-paths N` (default 10), `--ts-logic-pct P` (default 50),
`--no-troubleshoot` (opt out).

### 5.3 `vivado-build` command instruction (extend)
The command's post-sweep step gains: "if any `violations.json` exists, for
each, read it + referenced sources and generate `report.md`, `xdc/`,
`hdl/` artifacts per the rules below."

## 6. Artifacts (per violating strategy)

```
Performance_X/troubleshoot/
├── violations.json     # Tcl dump
├── report.md           # human-facing summary
├── xdc/timing_fix.xdc  # net-bound constraint candidates (CAUTION notes)
└── hdl/
    ├── <module>.v.bak  # original backup
    └── <module>.v      # pipelined revision
```

`report.md` contents:
- violation summary table: path | start/end | slack | logic%/route% |
  class | module:line
- net-bound: proposed XDC + why it is (or isn't) legitimate
  (multicycle / false_path / max_delay candidate; warn that a wrong
  constraint hides a real violation)
- logic-bound: offending code block quoted → pipeline diff (orig→revised)
  + latency-change caution (FSM/handshake impact must be checked)
- apply order guide (which file to swap → recompile)

`timing_fix.xdc` is a **separate file** (never overwrites project XDC); each
constraint prefixed with `# CAUTION:` stating its validity condition.

HDL revision lives **inside** `troubleshoot/hdl/` (never touches the real
source tree); user copies it out after review.

## 7. Limits, error handling, safety

1. **RTL remap failure** — if `FILE_NAME` is empty/synth-temp, report
   "source mapping uncertain, module-level only" and give guidance instead
   of an HDL revision (graceful degrade).
2. **HDL revision = review-required draft** — pipeline registers change
   latency; report always warns "functional equivalence NOT guaranteed,
   simulate/review required." No auto-apply, no auto-rebuild.
3. **XDC = hide-risk warning** — `false_path`/`multicycle` can mask real
   violations; every proposal states its validity condition. No
   unjustified relaxation.
4. **Trigger boundary** — violation = `WNS<0 || WHS<0`. TPWS/pulse-width =
   reported only.
5. **Safety** — original `.v`/`.xdc` and sweep outputs are never modified;
   all artifacts are copies under `troubleshoot/`.

## 8. Out of scope (YAGNI)

- Auto-apply / auto-rebuild loop
- External Python analyzer or separate LLM API
- Pulse-width / clock-definition fixes
- Multi-strategy cross comparison of fixes
