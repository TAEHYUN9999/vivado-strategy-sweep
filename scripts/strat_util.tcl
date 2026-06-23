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
