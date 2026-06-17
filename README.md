# vivado-strategy-sweep

One command to sweep **Vivado implementation strategies**, compare timing, and
package the winner.

It runs synthesis **once**, then implements your design under several strategies
(each in its own `impl_<strategy>` run so results are comparable), and for every
strategy it collects:

- **Timing**: WNS / TNS / WHS / THS / TPWS and a PASS/FAIL verdict
- **Utilization**: CLB LUTs, CLB Registers, Block RAM, DSPs
- **Artifacts**: the `.bit` bitstream + the routed timing & utilization reports

Finally it writes a **`.xsa`** hardware handoff (bitstream included) for the
best-timing run — ready for Vitis.

Works two ways:

1. **Plain shell** — `./scripts/run.sh ...` (no Claude needed)
2. **Claude Code slash command** — `/vivado-build ...` (runs the script, then
   reads the results and writes a ranked analysis for you)

Tested with **Vivado 2023.1** on **Ubuntu 22.04**.

---

## Quick start (shell)

```bash
# Validate the project + strategy list without launching anything (~1 min):
./scripts/run.sh --xpr /path/to/project.xpr --dry-run

# Full sweep (long: synthesis once + one implementation per strategy):
./scripts/run.sh --xpr /path/to/project.xpr

# Custom strategies, jobs, and an XSA per strategy:
./scripts/run.sh --xpr /path/to/project.xpr \
    --strategies "Performance_Explore,Performance_ExtraTimingOpt" \
    --jobs 8 --xsa all
```

Results land in `vivado_sweep_<timestamp>/`:

```
summary.csv                     # the comparison table
impl_<strategy>.bit             # bitstream per strategy
impl_<strategy>_timing_summary.rpt
impl_<strategy>_utilization.rpt
impl_<best>.xsa                 # hardware handoff (bitstream included)
vivado.log / vivado.jou         # full Vivado batch logs
```

### Options

| Option | Default | Meaning |
|--------|---------|---------|
| `--xpr PATH` | `$VB_XPR` | Vivado project (required) |
| `--strategies "a,b,c"` | `scripts/strategies.txt` | Strategies to sweep |
| `--jobs N` | `min(8, nproc)` | `-jobs` for `launch_runs` |
| `--outdir DIR` | `./vivado_sweep_<ts>` | Output directory |
| `--synth-strategy NAME` | (unchanged) | Override `synth_1` strategy |
| `--xsa best\|all\|none` | `best` | Which runs get a `.xsa` |
| `--dry-run` | off | Validate + print plan, launch nothing |
| `--vivado PATH` | auto-detect | Path to the `vivado` binary |

Edit the default strategy set in [`scripts/strategies.txt`](scripts/strategies.txt).
Unknown strategy names are rejected (validated against your exact part) with the
full list of valid ones printed.

---

## Quick start (Claude Code plugin)

Install as a plugin, then in any session:

```
/vivado-build --xpr /path/to/project.xpr --dry-run
/vivado-build --xpr /path/to/project.xpr
```

The command runs `run.sh`, then reads `summary.csv` and the timing reports and
gives you a ranked, human-readable comparison plus the best strategy.

### Install

Clone into your Claude Code plugins location, or add this repo as a plugin
marketplace/source per the Claude Code plugin docs. The plugin manifest is in
[`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) and the command in
[`commands/vivado-build.md`](commands/vivado-build.md).

---

## How the sweep works (Tcl)

Per strategy the engine does the equivalent of:

```tcl
create_run impl_<strategy> -parent_run synth_1 -flow <flow> -strategy <strategy>
launch_runs impl_<strategy> -to_step write_bitstream -jobs <N>
wait_on_run impl_<strategy>            ;# blocks until done (required in batch)
```

then reads `STATS.WNS/TNS/WHS/THS` from the run, parses the utilization report,
and copies out the bitstream and reports. The best run (highest WNS among
timing-met runs) gets:

```tcl
open_run impl_<best>
write_hw_platform -fixed -include_bit -force impl_<best>.xsa
```

See [`scripts/sweep.tcl`](scripts/sweep.tcl).

---

## Notes & caveats

- A sweep is inherently long — it's N full implementations. Trim
  `strategies.txt` for quick iterations.
- `launch_runs` is non-blocking; this tool always `wait_on_run`s so batch mode
  doesn't exit early.
- `.xsa` generation assumes a Vitis-targetable design (e.g. a block design /
  MicroBlaze). Use `--xsa none` for pure-PL designs that don't need a handoff.
- Hold (`WHS`/`THS`) is reported alongside setup so a strategy that fixes setup
  but breaks hold is visible.

## License

MIT — see [LICENSE](LICENSE).
