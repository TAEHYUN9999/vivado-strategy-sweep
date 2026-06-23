---
description: Sweep Vivado implementation strategies, then analyze WNS/TNS/utilization and report the best.
argument-hint: [project-dir-or-.xpr] [--no-vitis] [--no-prep-ip] [--dry-run]
allowed-tools: Bash, Read
---

You are driving `vivado-strategy-sweep`. The user wants to build an FPGA design under
several Vivado implementation strategies and find the one with the best timing.

User arguments (may be empty): $ARGUMENTS

## What to do

1. Resolve the script path: `${CLAUDE_PLUGIN_ROOT}/scripts/run.sh`.

2. **Resolve the project `.xpr`** from `$ARGUMENTS` (a directory or a `.xpr`):
   - If it is a `.xpr` file, use it directly.
   - If it is a directory, find the real project `.xpr`, excluding IP-internal
     ones:
     ```bash
     find "<DIR>" -name '*.xpr' \
       -not -path '*/.ipdefs/*' -not -path '*/.gen/*' \
       -not -path '*/.srcs/*'   -not -path '*/.ip_user_files/*' \
       -not -path '*/.runs/*'
     ```
     One match → use it (tell the user which). Several → ask the user to pick.
     None → ask the user for the path.
   - If `$ARGUMENTS` has no path, ask the user (or use a single `*.xpr` in CWD).

3. **Immediately show the strategy checklist.** Read the active (uncommented,
   non-blank) lines of `${CLAUDE_PLUGIN_ROOT}/scripts/strategies.txt`. Present
   them as a SINGLE multi-select prompt. The checkbox widget caps at 4 options
   per group, so split into groups of ≤4 shown together (for the default 8
   entries: group 1/2 = the first four `Performance_*`, group 2/2 = the
   remaining three `Performance_*` plus `Vivado Implementation Defaults`). The
   user may check any across both groups; the **union** is the selection.
   Checking everything = full sweep. Do not ask anything else first.

4. **Run the flow** for the selected strategies. IP prep and Vitis are ON by
   default — no extra flags needed:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/run.sh" --xpr <XPR> --strategies "<comma-joined selection>"
   ```
   - A real run is **long** (synthesis once + one implementation per strategy,
     each then built in Vitis). If the user has not confirmed a long run, first
     do `--dry-run` to validate the project + strategy list and show the plan
     (it prints `IP prep: ON` and the planned `impl_<token>` runs), then confirm.
   - For the real run, prefer launching in the **background** and polling so the
     session stays responsive. Tell the user the output directory.

5. When it finishes, read `<outdir>/summary.csv` and the per-strategy
   `*_timing_summary.rpt` files. Produce a concise analysis:
   - A ranked table: strategy | timing_met | WNS | TNS | hold (WHS/THS) | LUT | FF | BRAM | DSP
   - State the **best strategy** (highest WNS among timing-met runs) and why.
   - Flag any run that failed to meet timing (negative WNS/WHS) or did not complete.
   - Point to each strategy's `<outdir>/<token>/`: `.bit`, `.ltx`, `.xsa`, and —
     for timing-PASS strategies — the Vitis `download.bit` (bitstream + firmware,
     ready to program over JTAG).

## Notes
- Strategies are validated inside Vivado against this exact part; an unknown name aborts with the valid list.
- `--xsa all` (default) writes a hardware handoff (bitstream included) per completed strategy.
- IP prep (Refresh IP Catalog + Generate Output Products) and the Vitis build run by default; use `--no-prep-ip` / `--no-vitis` to skip.
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
