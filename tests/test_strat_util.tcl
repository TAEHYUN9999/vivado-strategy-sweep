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
