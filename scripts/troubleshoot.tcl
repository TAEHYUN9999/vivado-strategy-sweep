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
        foreach c [lsort -unique [get_cells -quiet -of_objects [get_pins -quiet -of_objects $p]]] {
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
    if {[llength $entries] > 0} {
        puts $fh [join $entries ",\n"]
    }
    puts $fh "  \]"
    puts $fh "}"
    close $fh
    close_design
    puts ">>> troubleshoot: wrote $outdir/violations.json ($pid violating paths)"
}
