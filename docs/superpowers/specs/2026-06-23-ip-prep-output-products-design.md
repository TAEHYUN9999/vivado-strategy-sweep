# IP Prep (Refresh IP Catalog + Generate Output Products) — Design

**Date:** 2026-06-23
**Status:** Approved (pending spec review)
**Component:** `scripts/sweep.tcl`, `scripts/run.sh`, docs

## Problem

The sweep currently does `open_project → (re)synthesize synth_1 → per-strategy
implementation` (`scripts/sweep.tcl:46`–`140`). It does **not** replicate the
manual GUI steps the user performs after modifying a project:

1. **Refresh IP Catalog**
2. **Generate Output Products**
3. Run Synthesis / Implementation

`launch_runs synth_1` auto-generates *out-of-date* output products, but it does
**not** run `update_ip_catalog` (Refresh IP Catalog). When the user re-packages
an IP in the repo (their actual workflow — repackaging the `rgbd_top` IP), the
project will not pick up the new IP unless the catalog is refreshed explicitly.
The result: the sweep can build against a stale IP.

## Goal

Replicate the GUI "Refresh IP Catalog → Generate Output Products" steps inside
the sweep, automatically, before synthesis — so a re-packaged IP is always
picked up.

## Decisions (from brainstorming)

- **When:** Always on by default. Escape hatch `--no-prep-ip` to skip (for fast
  re-runs where no IP changed).
- **Scope:** `update_ip_catalog -rebuild` → `upgrade_ip` (no-ops up-to-date IPs)
  → `generate_target all` for both IPs (`get_ips`) and block designs
  (`get_files *.bd`). The project uses a block design
  (`design_1_i/microblaze_0`), so `.bd` handling is required.
- **On failure:** Abort before synthesis. A broken/stale IP would fail synthesis
  anyway; failing early surfaces the real cause.

## Approach (chosen: A)

Add the IP prep step **inside** `sweep.tcl` as a proc, called once right after
`open_project` and before the synthesis block. This keeps everything in the
existing single batch session (project opened/closed once), consistent with the
current architecture.

(Rejected: **B** — separate `prep_ip.tcl` in its own vivado batch: opens the
project twice, two vivado invocations, slower. **C** — `update_ip_catalog` only,
rely on `launch_runs` auto-gen: skips `upgrade_ip` and explicit generate, no GUI
parity.)

## Changes

### 1. `scripts/sweep.tcl`

New env read near the other `env_or` calls:

```tcl
set prep_ip [env_or VB_PREP_IP "1"]   ;# "1" = run IP prep (default), "0" = skip
```

New proc (placed before the synthesis block, ~line 100):

```tcl
proc prep_ip_outputs {} {
    puts "\n>>> IP prep: Refresh IP Catalog (update_ip_catalog -rebuild)"
    update_ip_catalog -rebuild
    set ips [get_ips -quiet]
    if {[llength $ips] > 0} {
        puts ">>> IP prep: upgrade_ip (up-to-date IPs no-op automatically)"
        upgrade_ip $ips
        puts ">>> IP prep: generate_target all \[get_ips\] ($ips)"
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
```

Call site, after `open_project`/validation and **before** the synthesis block:

```tcl
if {$prep_ip eq "1"} {
    if {[catch {prep_ip_outputs} err]} {
        error "IP prep FAILED (aborting before synthesis): $err"
    }
} else {
    puts ">>> IP prep skipped (--no-prep-ip)."
}
```

Dry-run: in the existing `if {$dryrun eq "1"}` block, print a one-line plan entry
(e.g. `IP prep: [expr {$prep_ip eq "1" ? "ON (refresh catalog + upgrade + generate)" : "OFF"}]`)
and do **not** execute prep.

### 2. `scripts/run.sh`

- Default `PREP_IP=1`.
- New flag `--no-prep-ip` → `PREP_IP=0`.
- `export VB_PREP_IP="$PREP_IP"` alongside the other `VB_*` exports.
- Show `IP prep : on|off` in the plan echo.
- Document `--no-prep-ip` in the `--help`/usage header.

### 3. Docs

- `commands/vivado-build.md`: note the IP prep step (default on) and `--no-prep-ip`.
- `README.md`: add `--no-prep-ip` to the options table; document the new step
  order (Refresh IP Catalog → upgrade_ip → Generate Output Products → synth →
  impl) and that it replicates the GUI flow for re-packaged IPs.

### 4. Cache mirror sync

Per the repo rule, after editing `scripts/sweep.tcl` and `scripts/run.sh`, copy
them to the cache mirror and verify byte-identical:

```
cp scripts/sweep.tcl scripts/run.sh \
   ~/.claude/plugins/cache/vivado-strategy-sweep/vivado-strategy-sweep/0.1.0/scripts/
diff -q scripts/sweep.tcl  <cache>/sweep.tcl
diff -q scripts/run.sh     <cache>/run.sh
```

(README/commands are not part of the cache mirror — scripts only.)

## Edge cases / notes

- `upgrade_ip` on an up-to-date IP is effectively a no-op, so passing all
  `get_ips` is safe whether or not the repackage bumped the version.
- `generate_target all` skips products that are already current, so "always on"
  is cheap when nothing changed.
- `--reuse-synth` + IP prep: prep may regenerate IP, but `--reuse-synth` will
  still reuse a 100% `synth_1`. This combination is unusual (reuse is for "RTL
  unchanged" fast re-runs); default behavior re-synthesizes, so this is not a
  concern in the default path. Documented, not guarded.
- Failure aborts the whole sweep (exit non-zero from the tcl `error`), matching
  existing synth-failure behavior.

## Testing

- **Dry-run:** `run.sh ... --dry-run` shows `IP prep : on`; `--no-prep-ip
  --dry-run` shows `off`. Nothing launched.
- **Unit (existing):** `run.sh --source-only` still loads without running; bash
  flag-parse tests unaffected.
- **Live (user-run):** a real sweep against the user's project after repackaging
  an IP — confirm the new IP version is built (manual verification on hardware).

## Out of scope

- No change to the strategy list, Vitis build, troubleshoot, or download.bit
  logic.
- No automatic detection of *which* IP was repackaged — prep runs the full
  refresh/generate every time (or is skipped wholesale via `--no-prep-ip`).
