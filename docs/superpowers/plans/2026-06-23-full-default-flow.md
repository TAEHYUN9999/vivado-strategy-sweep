# Full Default Flow + Interactive Strategy Pick — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `/vivado-strategy-sweep:vivado-build <DIR>` immediately show a checkbox strategy menu, then for each picked strategy run the full GUI-equivalent flow by default (Refresh IP Catalog → Generate Output Products → synth → impl → .bit/.ltx/.xsa → Vitis).

**Architecture:** IP prep is added as a proc inside `sweep.tcl`, run once after `open_project` before synthesis, gated by `VB_PREP_IP`. Strategy names may now contain spaces (the new `Vivado Implementation Defaults` baseline), so run/folder/CSV/XSA names are derived from a sanitized token (`vb_safe_token`) in a new sourceable helper, while the real name is passed to `set_property strategy`. `run.sh` flips Vitis to default-on (`auto`) and adds `--no-prep-ip`/`--no-vitis`. The interactive dir→xpr resolution and 4+4 checkbox prompt live in `commands/vivado-build.md` (executed by Claude).

**Tech Stack:** Bash (`run.sh`), Vivado 2023.1 Tcl (`sweep.tcl`, `strat_util.tcl`), Markdown (command + README). Tests: bash `--source-only` sourcing + `xsct`/`tclsh` pure-Tcl helper tests.

## Global Constraints

- **Cache mirror rule:** after editing anything under `scripts/`, copy to `~/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/` and verify byte-identical with `diff -q`. README/commands are NOT mirrored.
- **Backward compatibility:** for space-free strategy names, `vb_safe_token` is identity, so existing behavior (run names, folders, CSV, XSA) must be byte-for-byte unchanged.
- **Never modify** original project sources or sweep outputs; the tool only reads/builds.
- **Vivado/Vitis 2023.1.** `xsct` at `/tools/Xilinx/Vitis/2023.1/bin/xsct` (Vitis, not Vivado).
- **Repo convention:** this plugin is developed directly on `main` (documented in project memory). Commit locally per task; do **not** push unless the user asks.
- **Version stays `0.1.0`** (no bump).

---

### Task 1: `vb_safe_token` helper + test

**Files:**
- Create: `scripts/strat_util.tcl`
- Test: `tests/test_strat_util.tcl`

**Interfaces:**
- Produces: `proc vb_safe_token {s}` → returns the trimmed strategy name with every char outside `[A-Za-z0-9_.-]` replaced by `_`. Space-free input returns unchanged.

- [ ] **Step 1: Write the failing test**

Create `tests/test_strat_util.tcl`:
```tcl
source [file join [file dirname [info script]] .. scripts strat_util.tcl]
set fail 0
if {[vb_safe_token "Performance_Explore"] ne "Performance_Explore"} {
    puts "FAIL: space-free name must be unchanged"; set fail 1
}
if {[vb_safe_token "Vivado Implementation Defaults"] ne "Vivado_Implementation_Defaults"} {
    puts "FAIL: spaces must become underscores"; set fail 1
}
if {[vb_safe_token "  Performance_NetDelay_low  "] ne "Performance_NetDelay_low"} {
    puts "FAIL: must trim surrounding whitespace"; set fail 1
}
if {[vb_safe_token "a/b:c"] ne "a_b_c"} {
    puts "FAIL: slashes/colons must become underscores"; set fail 1
}
if {$fail} { exit 1 }
puts "PASS test_strat_util"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `tclsh tests/test_strat_util.tcl` (or `/tools/Xilinx/Vitis/2023.1/bin/xsct tests/test_strat_util.tcl`)
Expected: FAIL — `couldn't read file ".../scripts/strat_util.tcl"` (file does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `scripts/strat_util.tcl`:
```tcl
# =============================================================================
# strat_util.tcl -- helpers shared by sweep.tcl. Pure Tcl, no Vivado state, so
# it can be sourced standalone by unit tests (tclsh / xsct).
# =============================================================================

# Map a strategy name to a filesystem- and run-name-safe token: trim, then
# replace any char outside [A-Za-z0-9_.-] with "_". Space-free names pass through
# unchanged (keeps existing run/folder/CSV/XSA names byte-identical).
proc vb_safe_token {s} {
    return [regsub -all {[^A-Za-z0-9_.-]} [string trim $s] "_"]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `tclsh tests/test_strat_util.tcl`
Expected: `PASS test_strat_util`

- [ ] **Step 5: Commit**

```bash
git add scripts/strat_util.tcl tests/test_strat_util.tcl
git commit -m "feat: vb_safe_token helper for space-containing strategy names"
```

---

### Task 2: `sweep.tcl` — IP prep + safe-token wiring

**Files:**
- Modify: `scripts/sweep.tcl`

**Interfaces:**
- Consumes: `vb_safe_token` (Task 1); env `VB_PREP_IP` ("1" default, "0" = skip).
- Produces: per-strategy run `impl_<tok>`, folder `<outdir>/<tok>/`, CSV col 1 = `<tok>`, XSA `<outdir>/<tok>/<tok>.xsa`, where `tok = vb_safe_token(strategy)`. Real strategy name still passed to `create_run -strategy` / `set_property strategy`.

- [ ] **Step 1: Source the helper and read the new env flag**

In `scripts/sweep.tcl`, after the header block (line 16, the closing `# ===...`) and before `proc env_or`, insert:
```tcl
source [file join [file dirname [info script]] strat_util.tcl]
```
Then, in the env-reads block, after `set dryrun [env_or VB_DRYRUN "0"]` (line 30), add:
```tcl
set prep_ip     [env_or VB_PREP_IP "1"]
```

- [ ] **Step 2: Add the IP-prep plan line to dry-run output**

In the dry-run block, immediately before `close_project` / `return` (after the `synth strategy override:` puts, line 95), insert:
```tcl
    puts "  IP prep: [expr {$prep_ip eq "1" ? {ON (update_ip_catalog -rebuild + upgrade_ip + generate_target)} : {OFF (--no-prep-ip)}}]"
```

- [ ] **Step 3: Add the IP-prep proc + call before synthesis**

Between the end of the dry-run block (line 99 `}`) and `# ---- synthesis once ----` (line 101), insert:
```tcl
# ---- IP prep: Refresh IP Catalog + Generate Output Products ---------------
# Mirrors the GUI "Refresh IP Catalog" then "Generate Output Products". Runs
# once before synthesis. upgrade_ip no-ops up-to-date IPs; generate_target skips
# products already current, so this is cheap when nothing changed.
proc prep_ip_outputs {} {
    puts "\n>>> IP prep: Refresh IP Catalog (update_ip_catalog -rebuild)"
    update_ip_catalog -rebuild
    set ips [get_ips -quiet]
    if {[llength $ips] > 0} {
        puts ">>> IP prep: upgrade_ip (up-to-date IPs no-op automatically)"
        upgrade_ip $ips
        puts ">>> IP prep: generate_target all \[get_ips\]"
        generate_target all $ips
    } else {
        puts ">>> IP prep: no managed IPs found."
    }
    set bds [get_files -quiet *.bd]
    if {[llength $bds] > 0} {
        puts ">>> IP prep: generate_target all (block designs: $bds)"
        generate_target all $bds
    }
    puts ">>> IP prep complete."
}
if {$prep_ip eq "1"} {
    if {[catch {prep_ip_outputs} err]} {
        error "IP prep FAILED (aborting before synthesis): $err"
    }
} else {
    puts ">>> IP prep skipped (--no-prep-ip)."
}

```

- [ ] **Step 4: Derive the safe token in the per-strategy loop**

In the `foreach s $strategies` loop, the line is:
```tcl
    set s [string trim $s]
    set run "impl_$s"
```
Replace those two lines with:
```tcl
    set s [string trim $s]
    set tok [vb_safe_token $s]
    set run "impl_$tok"
```

- [ ] **Step 5: Use the token for CSV, folder, and archive names**

(a) CSV row — change the leading field from `$s` to `$tok`:
```tcl
    puts $csv "$tok,[expr {$ok ? {complete} : {failed}}],$timing_met,$wns,$tns,$whs,$ths,$tpws,$lut,$ff,$bram,$dsp,$rundir"
```

(b) Per-strategy output folder and archived basenames — replace the archive block:
```tcl
    set strat_out "$outdir/$s"
    file mkdir $strat_out
    set bit "$rundir/${top}.bit"
    if {[file exists $bit]}  { file copy -force $bit  "$strat_out/${s}.bit" }
    set ltx "$rundir/${top}.ltx"
    if {[file exists $ltx]} { file copy -force $ltx "$strat_out/${s}.ltx" }
    if {[file exists $util]} { file copy -force $util "$strat_out/${s}_utilization.rpt" }
    set tsum "$rundir/${top}_timing_summary_routed.rpt"
    if {[file exists $tsum]} { file copy -force $tsum "$strat_out/${s}_timing_summary.rpt" }
```
with (only the destination names change to `$tok`; the Vivado-produced source names keep `$top`):
```tcl
    set strat_out "$outdir/$tok"
    file mkdir $strat_out
    set bit "$rundir/${top}.bit"
    if {[file exists $bit]}  { file copy -force $bit  "$strat_out/${tok}.bit" }
    set ltx "$rundir/${top}.ltx"
    if {[file exists $ltx]} { file copy -force $ltx "$strat_out/${tok}.ltx" }
    if {[file exists $util]} { file copy -force $util "$strat_out/${tok}_utilization.rpt" }
    set tsum "$rundir/${top}_timing_summary_routed.rpt"
    if {[file exists $tsum]} { file copy -force $tsum "$strat_out/${tok}_timing_summary.rpt" }
```

(c) Results list — store the token (used by the XSA "all" branch). Change:
```tcl
    lappend results [list $s $run $wnsnum $ok]
```
to:
```tcl
    lappend results [list $tok $run $wnsnum $ok]
```
(The XSA "best" branch already derives the token via `string range $best 5 end` on the `impl_<tok>` run name, and the "all" branch uses the list's first field — now `$tok` — so `"$outdir/$s/${s}.xsa"` there resolves to the token folder. No change needed in `make_xsa` or the XSA block.)

- [ ] **Step 6: Parse-smoke-test the script**

Run: `tclsh scripts/sweep.tcl 2>&1 | head -3`
Expected: it parses past all proc defs and the `source strat_util.tcl`, reaching the env check and printing the banner then erroring with `VB_XPR not set or file missing: ''` (proves the file parses and the helper sources cleanly). If `tclsh` is unavailable, use `/tools/Xilinx/Vitis/2023.1/bin/xsct scripts/sweep.tcl`.

- [ ] **Step 7: Commit**

```bash
git add scripts/sweep.tcl
git commit -m "feat: IP prep (refresh catalog + generate output products) + space-safe naming in sweep.tcl"
```

---

### Task 3: `run.sh` — default-on Vitis, `--no-prep-ip`/`--no-vitis`, baseline strategy + tests

**Files:**
- Modify: `scripts/run.sh`
- Modify: `scripts/strategies.txt`
- Test: `tests/test_flags.sh`

**Interfaces:**
- Consumes: env/flags only.
- Produces: exports `VB_PREP_IP`; `VITIS_SRC` defaults to `auto`; flags `--no-prep-ip`, `--no-vitis`. `strategies.txt` gains `Vivado Implementation Defaults`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_flags.sh`:
```bash
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
  [[ "${VITIS_SRC:-x}" == "" ]] || { echo "FAIL: --no-vitis should clear VITIS_SRC"; exit 1; }
) || fail=1

# baseline strategy present in strategies.txt
grep -qx "Vivado Implementation Defaults" "$STRAT" \
    || { echo "FAIL: 'Vivado Implementation Defaults' missing from strategies.txt"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS test_flags" || exit 1
```
Make it executable: `chmod +x tests/test_flags.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_flags.sh`
Expected: FAIL — `VITIS_SRC default should be auto` (currently `""`) and the baseline grep fails.

- [ ] **Step 3: Add the baseline strategy**

In `scripts/strategies.txt`, after the `Performance_ExtraTimingOpt` line and before the blank line / `# Useful when...` comment, add:
```
Vivado Implementation Defaults
```

- [ ] **Step 4: Flip Vitis default-on and add PREP_IP default**

In `scripts/run.sh`, change line 53:
```bash
VITIS_SRC=""
```
to:
```bash
VITIS_SRC="auto"
```
And after line 52 (`DRYRUN="0"`), add:
```bash
PREP_IP="1"
```

- [ ] **Step 5: Add the two flags to arg parsing**

In the `while` arg loop, after the `--vitis-src` / `--vitis` cases (line 88), add:
```bash
        --no-vitis)        VITIS_SRC=""; shift;;
        --no-prep-ip)      PREP_IP="0"; shift;;
```

- [ ] **Step 6: Export the env and update the plan echo**

After `export VB_DRYRUN="$DRYRUN"` (line 176), add:
```bash
export VB_PREP_IP="$PREP_IP"
```
Then in the plan echo block, after the `jobs` line (line 182), add:
```bash
echo " prep   : ip=$([[ "$PREP_IP" == "1" ]] && echo on || echo off)    vitis=${VITIS_SRC:-off}"
```

- [ ] **Step 7: Update the `--help` header text**

In the header comment, update the `--vitis-src` line (line 23-24) to note the new default and add the two new flags right after the `--vitis` line (line 25):
```bash
#   --vitis-src DIR|auto    Build Vitis platform+app for each TIMING-PASS strategy
#                           (default: auto -> finds firmware under project dir; JTAG)
#   --no-vitis              Disable the Vitis build (only .bit/.ltx/.xsa)
#   --no-prep-ip            Skip IP prep (Refresh IP Catalog + Generate Output Products)
#   --vitis PATH            Path to xsct binary          (default: auto-detect)
```
And widen the help print range so the new lines show: change line 95
```bash
        -h|--help)        sed -n '2,40p' "$0"; exit 0;;
```
to:
```bash
        -h|--help)        sed -n '2,44p' "$0"; exit 0;;
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `bash tests/test_flags.sh && bash tests/test_detect.sh`
Expected: `PASS test_flags` then `PASS test_detect` (the existing test must still pass — confirms no regression in sourcing).

- [ ] **Step 9: Commit**

```bash
git add scripts/run.sh scripts/strategies.txt tests/test_flags.sh
git commit -m "feat: Vitis default-on, --no-vitis/--no-prep-ip flags, baseline strategy"
```

---

### Task 4: `commands/vivado-build.md` — interactive dir→xpr + 4+4 checkbox flow

**Files:**
- Modify: `commands/vivado-build.md`

**Interfaces:**
- Consumes: `run.sh` flags/defaults from Task 3; `strategies.txt` (menu source).
- Produces: the slash-command behavior (Claude resolves the project, prompts, runs).

- [ ] **Step 1: Replace the "What to do" section**

Replace lines 12–33 (the `## What to do` section, from `## What to do` through the bullet ending `...report files in the output directory.`) with:
```markdown
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
```

- [ ] **Step 2: Update the argument hint and Notes**

Change the front-matter `argument-hint` (line 3) to:
```markdown
argument-hint: [project-dir-or-.xpr] [--no-vitis] [--no-prep-ip] [--dry-run]
```
In the `## Notes` section, change the `--xsa best` note (line 37) to reflect the real default and add a prep note:
```markdown
- `--xsa all` (default) writes a hardware handoff (bitstream included) per completed strategy.
- IP prep (Refresh IP Catalog + Generate Output Products) and the Vitis build run by default; use `--no-prep-ip` / `--no-vitis` to skip.
```

- [ ] **Step 3: Verify the file still reads coherently**

Run: `sed -n '1,45p' commands/vivado-build.md`
Expected: front-matter intact, single `## What to do` with the 5 numbered steps, troubleshoot section (below, unchanged) still present.

- [ ] **Step 4: Commit**

```bash
git add commands/vivado-build.md
git commit -m "feat: interactive dir->xpr resolution + immediate 4+4 checkbox strategy prompt"
```

---

### Task 5: `README.md` — document defaults-on flow + flags

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the README to locate the options table and flow section**

Run: `grep -nE 'no-prep-ip|vitis-src|no-vitis|strategies\.txt|## |Implementation Defaults|--xsa' README.md`
Read the surrounding lines of the options table and the "step order"/usage section.

- [ ] **Step 2: Add the two flags to the options table**

In the options table, add rows (match the table's existing column format):
```markdown
| `--no-prep-ip` | Skip IP prep (Refresh IP Catalog + Generate Output Products). Default: prep ON. |
| `--no-vitis`   | Skip the Vitis platform/app/.elf/download.bit build. Default: Vitis ON (`auto`). |
```
And update the existing `--vitis-src` row to state the default is now `auto` (was opt-in).

- [ ] **Step 3: Document the interactive flow + baseline strategy**

Under the usage/quick-start section, add:
```markdown
### Interactive use (slash command)

Run `/vivado-strategy-sweep:vivado-build <project-dir-or-.xpr>`. The command
resolves the project `.xpr` (a directory is searched, excluding IP-internal
`.xpr` under `.ipdefs/`, `.gen/`, `.srcs/`, `.ip_user_files/`, `.runs/`), then
immediately shows a checkbox menu of the strategies in `scripts/strategies.txt`
(including the `Vivado Implementation Defaults` baseline). Pick any subset; each
selected strategy runs the full flow by default:

**Refresh IP Catalog → upgrade_ip → Generate Output Products → Synthesis →
Implementation → .bit/.ltx/.xsa → Vitis (platform + app + .elf + download.bit,
for timing-PASS strategies).**

Use `--no-prep-ip` or `--no-vitis` to drop either stage. Strategy names with
spaces (e.g. the baseline) are stored under a sanitized token
(`Vivado_Implementation_Defaults`) for run/folder/CSV/XSA names.
```

- [ ] **Step 4: Verify and commit**

Run: `grep -nE 'no-prep-ip|no-vitis|Vivado Implementation Defaults' README.md`
Expected: the new rows/section appear.
```bash
git add README.md
git commit -m "docs: README for default-on IP prep + Vitis, interactive checkbox flow"
```

---

### Task 6: Cache mirror sync + full verification

**Files:**
- Mirror: `scripts/{sweep.tcl,run.sh,strategies.txt,strat_util.tcl}` → cache

- [ ] **Step 1: Copy scripts to the cache mirror**

```bash
CACHE=~/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts
cp scripts/sweep.tcl scripts/run.sh scripts/strategies.txt scripts/strat_util.tcl "$CACHE"/
```
(Note: `strat_util.tcl` is NEW and is sourced by `sweep.tcl` at runtime, so the cache execution copy MUST include it.)

- [ ] **Step 2: Verify byte-identical**

```bash
for f in sweep.tcl run.sh strategies.txt strat_util.tcl; do
    diff -q "scripts/$f" "$CACHE/$f" || echo "MISMATCH: $f"
done
```
Expected: no output (all identical).

- [ ] **Step 3: Run the whole test suite**

```bash
bash tests/test_detect.sh
bash tests/test_flags.sh
tclsh tests/test_strat_util.tcl   # or: /tools/Xilinx/Vitis/2023.1/bin/xsct tests/test_strat_util.tcl
/tools/Xilinx/Vitis/2023.1/bin/xsct tests/test_classify.tcl
tclsh scripts/sweep.tcl 2>&1 | grep -q "VB_XPR not set" && echo "PARSE OK sweep.tcl"
```
Expected: `PASS test_detect`, `PASS test_flags`, `PASS test_strat_util`, `PASS test_classify`, `PARSE OK sweep.tcl`.

- [ ] **Step 4: Commit (mirror is untracked/ignored — usually nothing to add)**

The cache dir is outside the repo, so this is typically a no-op for git. If `git status` shows anything unexpected under `scripts/`, review before committing. Otherwise the task is complete with the prior commits.

```bash
git status --short
git log --oneline -6
```

---

## Self-Review

**Spec coverage:**
- IP prep default-on + steps (refresh/upgrade/generate, IPs + BDs) → Task 2 (Steps 1,3). ✔
- IP prep failure aborts before synth → Task 2 Step 3 (`catch`→`error`). ✔
- `--no-prep-ip` → Task 3 Steps 5–6; default ON → Step 4. ✔
- Vitis default-on (`auto`) + `--no-vitis`, not-found warn+skip (existing logic untouched) → Task 3 Steps 4–5. ✔
- Interactive immediate 4+4 checkbox, union, dir→xpr exclude IP-internal → Task 4. ✔
- Baseline `Vivado Implementation Defaults` in menu → Task 3 Step 3 + Task 4. ✔
- Space-safe naming (token for run/folder/CSV/XSA; real name to set_property; identity for space-free) → Task 1 + Task 2 Steps 4–5; backward-compat asserted by test_strat_util + unchanged-name code paths. ✔
- Dry-run shows IP prep ON/OFF → Task 2 Step 2. ✔
- Cache mirror incl. new strat_util.tcl → Task 6. ✔
- Docs (command + README) → Tasks 4, 5. ✔

**Placeholder scan:** No TBD/TODO; every code step shows full content; README rows quoted exactly (Task 5 reads the file first to place them, which is necessary since the table format is in-repo). ✔

**Type/name consistency:** `vb_safe_token` used identically in Tasks 1–2; token variable `tok`; env `VB_PREP_IP`/var `PREP_IP`; folder/CSV/run all use `tok`; XSA "best" derives token from `impl_<tok>` run name and "all" from results' first field (`tok`) — consistent. ✔

## Execution Handoff

(Reported to user after saving.)
