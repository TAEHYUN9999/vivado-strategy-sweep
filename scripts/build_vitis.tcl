# =============================================================================
# build_vitis.tcl -- XSCT script: .xsa -> Vitis platform + empty-C app + build
#
# Reproduces the classic Vitis IDE workspace layout:
#   <ws>/vitispp           (platform, standalone on microblaze_0, from .xsa)
#   <ws>/vitisap           (empty C application, sources imported)
#   <ws>/vitisap_system    (system project, auto-created)
#
# Usage:
#   xsct build_vitis.tcl <xsa> <workspace> <src_dir> [plat_name] [app_name] [proc] [os]
#
# After it finishes, open <workspace> in Vitis and program over JTAG.
# =============================================================================

if {[llength $argv] < 3} {
    puts "ERROR: usage: xsct build_vitis.tcl <xsa> <workspace> <src_dir> \[plat\] \[app\] \[proc\] \[os\]"
    exit 1
}

set xsa   [file normalize [lindex $argv 0]]
set ws    [file normalize [lindex $argv 1]]
set src   [file normalize [lindex $argv 2]]
set plat  [expr {[llength $argv] > 3 ? [lindex $argv 3] : "vitispp"}]
set app   [expr {[llength $argv] > 4 ? [lindex $argv 4] : "vitisap"}]
set proc  [expr {[llength $argv] > 5 ? [lindex $argv 5] : "microblaze_0"}]
set os    [expr {[llength $argv] > 6 ? [lindex $argv 6] : "standalone"}]

foreach {n v} [list xsa $xsa ws $ws src $src] {
    puts ">>> $n = $v"
}
puts ">>> platform=$plat  app=$app  proc=$proc  os=$os"

if {![file exists $xsa]} { puts "ERROR: xsa not found: $xsa"; exit 1 }
if {![file isdirectory $src]} { puts "ERROR: src dir not found: $src"; exit 1 }
file mkdir $ws

setws $ws

# ---- platform (PP) --------------------------------------------------------
puts ">>> creating platform $plat from [file tail $xsa] ..."
platform create -name $plat -hw $xsa -proc $proc -os $os -out $ws
platform write
platform active $plat
puts ">>> generating platform (BSP) ..."
platform generate

# ---- inject legacy interrupt VEC_ID aliases -------------------------------
# Vitis 2023.1 BSP no longer auto-generates the old SDK-style
# XPAR_INTC_0_<periph>_VEC_ID names that vitis_src_ver2 uses. The new
# XPAR_AXI_INTC_0_..._INTR names DO exist, so alias old->new (guarded by
# #ifndef so it is harmless if a future BSP ever provides them).
set xpar "$ws/$plat/export/$plat/sw/$plat/${os}_domain/bspinclude/include/xparameters.h"
if {[file exists $xpar]} {
    puts ">>> injecting legacy VEC_ID aliases into [file tail $xpar]"
    set fh [open $xpar a]
    puts $fh "\n/* ---- legacy SDK interrupt VEC_ID aliases (auto-injected by build_vitis.tcl) ---- */"
    foreach {old new} {
        XPAR_INTC_0_UARTLITE_0_VEC_ID XPAR_AXI_INTC_0_AXI_UARTLITE_0_INTERRUPT_INTR
        XPAR_INTC_0_SPI_0_VEC_ID      XPAR_AXI_INTC_0_AXI_QUAD_SPI_0_IP2INTC_IRPT_INTR
        XPAR_INTC_0_GPIO_2_VEC_ID     XPAR_AXI_INTC_0_AXI_GPIO_2_IP2INTC_IRPT_INTR
    } {
        puts $fh "#ifndef $old"
        puts $fh "#define $old $new"
        puts $fh "#endif"
    }
    close $fh
} else {
    puts ">>> WARNING: xparameters.h not found at $xpar (skipping alias inject)"
}

# ---- application (AP): empty C, then import all sources -------------------
puts ">>> creating empty C app $app ..."
app create -name $app -platform $plat -domain ${os}_domain -template {Empty Application(C)}

puts ">>> importing sources from $src ..."
importsources -name $app -path $src

puts ">>> building app $app ..."
app build -name $app

# ---- register the platform in the workspace tree (for the classic Vitis GUI) --
# xsct's `platform create` builds the platform on disk but does NOT add it to the
# Eclipse workspace .projects registry the way `app create` registers apps. A
# workspace built purely by xsct therefore opens in the classic Vitis GUI with an
# EMPTY Project Explorer: the apps reference a platform that is not in the project
# tree, so nothing resolves. Importing the platform in-place registers it (creates
# .metadata/.plugins/org.eclipse.core.resources/.projects/$plat), after which the
# GUI lists platform + apps. The apps are already registered by `app create`, so
# only the platform needs importing.
puts ">>> registering platform $plat in workspace for GUI ..."
importprojects $ws/$plat

puts ">>> DONE: workspace=$ws"
puts ">>>   platform: $ws/$plat"
puts ">>>   app elf : $ws/$app/Debug/$app.elf"
