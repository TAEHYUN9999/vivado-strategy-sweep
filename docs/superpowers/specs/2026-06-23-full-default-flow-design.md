# Full default flow + interactive strategy pick — Design

**Date:** 2026-06-23
**Status:** Approved (pending spec review)
**Component:** `commands/vivado-build.md`, `scripts/sweep.tcl`, `scripts/run.sh`,
`scripts/strategies.txt`, docs

## Problem / Goal

The user wants `/vivado-strategy-sweep:vivado-build <DIR>` to drive the **entire**
GUI flow with no extra flags:

1. Run the command with just a project path (a directory).
2. The command **asks which strategies** to run (multi-select) from the existing
   list, plus a new baseline entry.
3. For each chosen strategy, automatically run the full flow:
   **Refresh IP Catalog → Generate Output Products → Synthesis → Implementation
   → .bit/.ltx/.xsa → Vitis (platform + app + .elf + download.bit).**

Today: IP prep is missing, Vitis is opt-in (`--vitis-src`), the project must be
given as an exact `.xpr` file via `--xpr`, and there is no interactive strategy
prompt or baseline strategy.

## Decisions (from brainstorming)

- **IP prep:** default ON, `--no-prep-ip` to skip. Steps: `update_ip_catalog
  -rebuild` → `upgrade_ip` → `generate_target all` (IPs **and** block designs).
  On failure: abort before synthesis.
- **Vitis:** default ON via `auto` firmware discovery, `--no-vitis` to skip.
  Firmware not found → warn + skip Vitis (still produce .bit/.ltx). Existing
  PASS-gating and `download.bit` generation unchanged.
- **Strategy pick:** the slash command asks the user; **multiple selection
  allowed** (each runs end-to-end). Baseline added: **`Vivado Implementation
  Defaults`** ("origin").
- **Path arg:** accept a **directory**; resolve to the project `.xpr` (recursive,
  excluding IP-internal `.xpr` under `.ipdefs/`, `.srcs/`, `.gen/`,
  `.ip_user_files/`). A bare `.xpr` path still works.

## Reference resolution for the user's example

`include_rgb_isp/` → real project
`…/prj_rgbd-20_1223_mixed_only_isp_bare_hsin/prj_rgbd-10.xpr`
(the `.ipdefs/.../axis_stream_mon.xpr` is IP-internal and excluded). Firmware is
`…/prj_rgbd-20_.../isp_logic_fixed/src/main.c`, found by `--vitis-src auto`'s
`find -maxdepth 4 -name main.c` fallback.

## Interaction model (the slash command)

`commands/vivado-build.md` instructs Claude to:

1. **Resolve the project.** If the argument is a directory, find candidate
   `.xpr` files excluding IP-internal dirs. If exactly one → use it (state which).
   If several → ask the user. If it is already a `.xpr` → use directly.
2. **Build the strategy menu** from `scripts/strategies.txt` (active, uncommented
   lines), which now includes the `Vivado Implementation Defaults` baseline.
3. **Ask the user** which strategies to run (multi-select; "all" allowed).
4. **Run** `run.sh --xpr <resolved.xpr> --strategies "<comma-joined>"` with the
   new defaults (IP prep ON, Vitis ON/auto). Surface the summary + per-strategy
   output folders + whether Vitis built.

Non-interactive use (`run.sh --xpr ... [--strategies ...]`) still works; omitting
`--strategies` sweeps the full `strategies.txt`.

## Changes

### 1. `scripts/strategies.txt`
Add one active entry for the baseline:
```
Vivado Implementation Defaults
```
(Names may now contain spaces — see naming rule below. `strategies.txt` is read
line-by-line; each whole line is one strategy.)

### 2. `scripts/sweep.tcl`

**(a) IP prep** — new env + proc, called after `open_project`/validation and
before synthesis:
```tcl
set prep_ip [env_or VB_PREP_IP "1"]

proc prep_ip_outputs {} {
    puts "\n>>> IP prep: Refresh IP Catalog (update_ip_catalog -rebuild)"
    update_ip_catalog -rebuild
    set ips [get_ips -quiet]
    if {[llength $ips] > 0} {
        puts ">>> IP prep: upgrade_ip (up-to-date IPs no-op automatically)"
        upgrade_ip $ips
        puts ">>> IP prep: generate_target all \[get_ips\]"
        generate_target all $ips
    } else { puts ">>> IP prep: no managed IPs found." }
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
} else { puts ">>> IP prep skipped (--no-prep-ip)." }
```
Dry-run: print an `IP prep: ON/OFF` plan line, execute nothing.

**(b) Strategy names with spaces** — decouple run/folder/CSV naming from the
strategy string. For each strategy `$s` compute a safe token:
```tcl
set tok [regsub -all {[^A-Za-z0-9_.-]} $s "_"]   ;# "Vivado Implementation Defaults" -> "Vivado_Implementation_Defaults"
```
Use `$tok` for: run name `impl_$tok`, per-strategy folder `$outdir/$tok`,
archived file basenames, `summary.csv` column 1, and the `.xsa` name. Use the
real `$s` only for `create_run -strategy $s` / `set_property strategy $s`.
`make_xsa` derives the folder from `$tok` (not by stripping a prefix). For
space-free names `tok == s`, so existing behavior is byte-for-byte unchanged.
`summary.csv` keeps a stable machine key (`tok`) in col 1, matching the folder
names that `run.sh`'s Vitis loop iterates — no `run.sh` mapping change needed.

### 3. `scripts/run.sh`
- `PREP_IP=1` default; `--no-prep-ip` → `0`; `export VB_PREP_IP`.
- **Vitis default ON:** `VITIS_SRC="auto"` default (was `""`); `--no-vitis`
  clears it. Auto-discovery and PASS-gating unchanged; not-found → warn + skip.
- Ensure `strategies.txt` is read so each whole line (possibly with spaces)
  becomes one comma-joined strategy; pass through `VB_STRATEGIES`.
- Plan echo shows `IP prep : on|off` and `Vitis : auto|<dir>|off`.
- Update `--help`/usage for `--no-prep-ip`, `--no-vitis`, and dir-or-xpr arg.

### 4. `commands/vivado-build.md`
Rewrite to define the interactive flow above (resolve dir→xpr, build menu from
`strategies.txt`, multi-select prompt, run with defaults, report results).

### 5. Docs (`README.md`)
Document: dir-or-xpr argument, interactive strategy prompt, the
`Vivado Implementation Defaults` baseline, defaults-on for IP prep + Vitis, and
the `--no-prep-ip` / `--no-vitis` escape hatches; update the options table and
step-order description.

### 6. Cache mirror sync
After editing `scripts/sweep.tcl`, `scripts/run.sh`, `scripts/strategies.txt`,
copy to the cache mirror and `diff -q` byte-identical:
```
cp scripts/{sweep.tcl,run.sh,strategies.txt} \
   ~/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/
```
(README/commands are not mirrored.)

## Edge cases / notes

- `upgrade_ip` no-ops up-to-date IPs; `generate_target` skips current products —
  so "always on" is cheap when nothing changed.
- `Vivado Implementation Defaults` is validated at runtime against
  `list_property_value strategy [get_runs impl_1]`; if the exact string differs
  for a part, sweep prints the valid list and aborts (graceful).
- A baseline that fails timing is skipped by the existing Vitis PASS-gate — bit/
  ltx still produced; Vitis simply not built for it.
- `--reuse-synth` + IP prep: prep may regenerate IP but reuse still keeps a 100%
  `synth_1`. Unusual combo (reuse = "RTL unchanged"); default re-synthesizes, so
  not a concern in the default path. Documented, not guarded.
- IP-prep / generate failure aborts the sweep (non-zero), matching existing
  synth-failure behavior.

## Testing

- **Dry-run:** `--dry-run` shows `IP prep : on`, `Vitis : auto`, and the planned
  `impl_<tok>` runs (incl. `impl_Vivado_Implementation_Defaults`); nothing
  launched. `--no-prep-ip --no-vitis --dry-run` shows both off.
- **Unit (existing):** `run.sh --source-only` still loads; bash flag-parse tests
  pass with the new flags.
- **Naming:** confirm `Vivado Implementation Defaults` → folder/run/csv token
  `Vivado_Implementation_Defaults`, while `set_property strategy` receives the
  real spaced name (assert in dry-run output / a tcl helper test).
- **Live (user-run):** real run on the user's project after repackaging an IP —
  confirm new IP is built and Vitis artifacts (.elf, download.bit) appear for
  PASS strategies. Hardware verification by the user.

## Out of scope

- No change to the troubleshoot feature or the strategy set beyond adding the
  baseline.
- No detection of *which* IP changed — prep runs the full refresh/generate every
  time (or is skipped wholesale via `--no-prep-ip`).
