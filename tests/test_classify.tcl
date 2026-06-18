source [file join [file dirname [info script]] .. scripts troubleshoot.tcl]
set fail 0
if {[ts_classify 6.0 4.0 50] ne "logic"} { puts "FAIL: 60% logic should be logic"; set fail 1 }
if {[ts_classify 4.0 6.0 50] ne "net"}   { puts "FAIL: 40% logic should be net";   set fail 1 }
if {[ts_classify 5.0 5.0 50] ne "logic"} { puts "FAIL: exactly 50% is logic (>=)"; set fail 1 }
if {[ts_classify 0.0 0.0 50] ne "net"}   { puts "FAIL: zero delay defaults net";   set fail 1 }
if {$fail} { exit 1 }
puts "PASS test_classify"
