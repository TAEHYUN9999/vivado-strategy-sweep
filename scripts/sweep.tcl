# =============================================================================
# sweep.tcl  --  Vivado implementation-strategy sweep (project mode, batch)
#
# Driven entirely by environment variables exported from run.sh:
#   VB_XPR             absolute path to .xpr
#   VB_STRATEGIES      comma-separated impl strategy names
#   VB_JOBS            -jobs value for launch_runs
#   VB_OUTDIR          output directory (already created)
#   VB_SYNTH_STRATEGY  optional synth_1 strategy ("" = leave as-is)
#   VB_XSA             "best" | "all" | "none"
#   VB_DRYRUN          "1" = validate & print plan only, do not launch
#
# Each strategy gets its OWN impl run (impl_<strategy>) sharing one synthesis,
# so results are directly comparable. Summary written to $VB_OUTDIR/summary.csv
# =============================================================================

proc env_or {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} { return $::env($name) }
    return $default
}

set xpr         [env_or VB_XPR ""]
set strategies  [split [env_or VB_STRATEGIES ""] ","]
set jobs        [env_or VB_JOBS 8]
set outdir      [env_or VB_OUTDIR "./vivado_sweep"]
set synth_strat [env_or VB_SYNTH_STRATEGY ""]
set xsa_mode    [env_or VB_XSA "best"]
set dryrun      [env_or VB_DRYRUN "0"]

if {$xpr eq "" || ![file exists $xpr]} {
    error "VB_XPR not set or file missing: '$xpr'"
}
file mkdir $outdir

puts "==== vivado-strategy-sweep ===="
puts "project    : $xpr"
puts "strategies : $strategies"
puts "jobs       : $jobs"
puts "outdir     : $outdir"
puts "xsa mode   : $xsa_mode"
puts "dry-run    : $dryrun"
puts "==============================="

open_project $xpr

set part [get_property PART [current_project]]
set top  [get_property top  [current_fileset]]
set impl_flow [get_property FLOW [get_runs impl_1]]
puts "part=$part top=$top impl_flow={$impl_flow}"

# ---- validate requested strategies against the tool's own list -------------
set valid_impl [list_property_value strategy [get_runs impl_1]]
set bad {}
foreach s $strategies {
    set s [string trim $s]
    if {[lsearch -exact $valid_impl $s] < 0} { lappend bad $s }
}
if {[llength $bad] > 0} {
    puts "ERROR: unknown impl strategies: $bad"
    puts "Valid impl strategies for this part:"
    foreach s $valid_impl { puts "  - $s" }
    error "Aborting: fix the strategy list."
}

# helper: read a STATS.* property safely (returns "" if absent)
proc stat {run prop} {
    set v [get_property -quiet $prop [get_runs $run]]
    if {$v eq ""} { return "" }
    return $v
}

# helper: pull "Used" column for a named row out of a utilization report
proc util_val {file rowname} {
    if {![file exists $file]} { return "" }
    set fh [open $file r]; set data [read $fh]; close $fh
    set pat "^\\s*\\|\\s*[string map {( \\( ) \\)} $rowname]\\s*\\|"
    foreach line [split $data "\n"] {
        if {[regexp $pat $line]} {
            set cols [split $line "|"]
            return [string trim [lindex $cols 2]]
        }
    }
    return ""
}

# ---- dry run: print the plan and bail ------------------------------------
if {$dryrun eq "1"} {
    puts "\n---- DRY RUN: planned runs (nothing launched) ----"
    foreach s $strategies {
        set s [string trim $s]
        puts "  impl_$s   <- synth_1   strategy=$s"
    }
    puts "  synth strategy override: [expr {$synth_strat eq "" ? {(none)} : $synth_strat}]"
    puts "DRY RUN OK"
    close_project
    return
}

# ---- synthesis once -------------------------------------------------------
if {$synth_strat ne ""} {
    set_property strategy $synth_strat [get_runs synth_1]
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%" || $synth_strat ne ""} {
    puts "\n>>> Running synthesis (synth_1)..."
    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Synthesis FAILED: [get_property STATUS [get_runs synth_1]]"
}
puts ">>> Synthesis complete."

# ---- per-strategy implementation -----------------------------------------
set csv [open "$outdir/summary.csv" w]
puts $csv "strategy,status,timing_met,WNS_ns,TNS_ns,WHS_ns,THS_ns,TPWS_ns,LUT,FF,BRAM,DSP,run_dir"
flush $csv

set results {}   ;# list of {strategy run wns_numeric ok}

foreach s $strategies {
    set s [string trim $s]
    set run "impl_$s"
    puts "\n>>> \[$s\] preparing run $run"

    if {[llength [get_runs -quiet $run]] == 0} {
        create_run $run -parent_run synth_1 -flow $impl_flow -strategy $s
    } else {
        reset_run $run
        set_property strategy $s [get_runs $run]
    }

    puts ">>> \[$s\] launching to write_bitstream (-jobs $jobs)..."
    if {[catch {
        launch_runs $run -to_step write_bitstream -jobs $jobs
        wait_on_run $run
    } err]} {
        puts ">>> \[$s\] launch error: $err"
    }

    set prog   [get_property PROGRESS [get_runs $run]]
    set status [get_property STATUS   [get_runs $run]]
    set rundir [get_property DIRECTORY [get_runs $run]]
    set ok [expr {$prog eq "100%"}]

    set wns [stat $run STATS.WNS]
    set tns [stat $run STATS.TNS]
    set whs [stat $run STATS.WHS]
    set ths [stat $run STATS.THS]
    set tpws [stat $run STATS.TPWS]

    set util "$rundir/${top}_utilization_placed.rpt"
    set lut  [util_val $util "CLB LUTs"]
    set ff   [util_val $util "CLB Registers"]
    set bram [util_val $util "Block RAM Tile"]
    set dsp  [util_val $util "DSPs"]

    set timing_met "UNKNOWN"
    if {$ok} {
        if {$wns ne "" && $whs ne ""} {
            set timing_met [expr {($wns >= 0 && $whs >= 0) ? "PASS" : "FAIL"}]
        }
    } else {
        set timing_met "INCOMPLETE"
    }

    puts $csv "$s,[expr {$ok ? {complete} : {failed}}],$timing_met,$wns,$tns,$whs,$ths,$tpws,$lut,$ff,$bram,$dsp,$rundir"
    flush $csv
    puts ">>> \[$s\] done: progress=$prog WNS=$wns TNS=$tns timing=$timing_met LUT=$lut FF=$ff"

    # archive key artifacts into a per-strategy subfolder ($outdir/<strategy>/)
    set strat_out "$outdir/$s"
    file mkdir $strat_out
    set bit "$rundir/${top}.bit"
    if {[file exists $bit]}  { file copy -force $bit  "$strat_out/${s}.bit" }
    set ltx "$rundir/${top}.ltx"
    if {[file exists $ltx]} { file copy -force $ltx "$strat_out/${s}.ltx" }
    if {[file exists $util]} { file copy -force $util "$strat_out/${s}_utilization.rpt" }
    set tsum "$rundir/${top}_timing_summary_routed.rpt"
    if {[file exists $tsum]} { file copy -force $tsum "$strat_out/${s}_timing_summary.rpt" }

    set wnsnum [expr {$wns eq "" ? -1e9 : $wns}]
    lappend results [list $s $run $wnsnum $ok]
}
close $csv

# ---- pick best (highest WNS among completed runs) -------------------------
set best ""
set best_wns -1e30
foreach r $results {
    lassign $r s run wns ok
    if {$ok && $wns > $best_wns} { set best_wns $wns; set best $run }
}
if {$best ne ""} {
    puts "\n>>> BEST: $best  (WNS=$best_wns ns)"
} else {
    puts "\n>>> No run completed successfully."
}

# ---- .xsa hardware handoff (includes bitstream) ---------------------------
# Writes <outdir>/<strategy>/<strategy>.xsa so each strategy's handoff lives
# alongside its archived bitstream/reports in the same per-strategy folder.
proc make_xsa {run xsa_path} {
    puts ">>> writing XSA for $run ..."
    file mkdir [file dirname $xsa_path]
    open_run $run
    write_hw_platform -fixed -include_bit -force "$xsa_path"
    close_design
    puts ">>> XSA: $xsa_path"
}

if {$xsa_mode eq "best" && $best ne ""} {
    set bs [string range $best 5 end]   ;# strip "impl_" prefix -> strategy name
    make_xsa $best "$outdir/$bs/${bs}.xsa"
} elseif {$xsa_mode eq "all"} {
    foreach r $results {
        lassign $r s run wns ok
        if {$ok} { make_xsa $run "$outdir/$s/${s}.xsa" }
    }
}

puts "\n>>> Summary written to $outdir/summary.csv"
close_project
puts ">>> ALL DONE."
