---
description: Sweep Vivado implementation strategies, then analyze WNS/TNS/utilization and report the best.
argument-hint: [--xpr PATH] [--strategies a,b,c] [--jobs N] [--xsa best|all|none] [--dry-run]
allowed-tools: Bash, Read
---

You are driving `vivado-strategy-sweep`. The user wants to build an FPGA design under
several Vivado implementation strategies and find the one with the best timing.

User arguments (may be empty): $ARGUMENTS

## What to do

1. Resolve the script path: `${CLAUDE_PLUGIN_ROOT}/scripts/run.sh`.
2. Determine the `.xpr`:
   - If `--xpr` is in `$ARGUMENTS`, use it.
   - Otherwise ask the user for the project path (or check the current directory for a single `*.xpr`).
3. Run the sweep. Stream output so the user sees progress. Example:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/run.sh" --xpr <PATH> $ARGUMENTS
   ```
   - A full sweep is **long** (synthesis once + one implementation per strategy).
     If the user has not confirmed they want a full multi-hour run, first do a
     `--dry-run` to validate the project and strategy list, show the plan, and
     confirm before launching the real sweep.
   - For a real run, prefer launching it in the **background** and polling, so the
     session stays responsive. Tell the user the output directory.
4. When it finishes, read `<outdir>/summary.csv` and the per-strategy
   `*_timing_summary.rpt` files. Produce a concise analysis:
   - A ranked table: strategy | timing_met | WNS | TNS | hold (WHS/THS) | LUT | FF | BRAM | DSP
   - State the **best strategy** (highest WNS among timing-met runs) and why.
   - Flag any run that failed to meet timing (negative WNS/WHS) or did not complete.
   - Point to the archived `.bit`, `.xsa`, and report files in the output directory.

## Notes
- Strategies are validated inside Vivado against this exact part; an unknown name aborts with the valid list.
- `--xsa best` (default) writes a single hardware handoff (bitstream included) for the winning run.
- Do not invent timing numbers — only report values read from `summary.csv` / the `.rpt` files.

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
- per net path: the proposed constraint + why it is/isn't legitimate
- per logic path: the offending code block quoted + the pipeline diff
  (orig→revised) + a caution that latency changed and FSM/handshake/data-align
  must be re-verified, plus "functional equivalence NOT guaranteed — simulate"
- an apply-order guide (which file to swap, then recompile)

Report which strategies got artifacts and where. Do not apply or rebuild.
