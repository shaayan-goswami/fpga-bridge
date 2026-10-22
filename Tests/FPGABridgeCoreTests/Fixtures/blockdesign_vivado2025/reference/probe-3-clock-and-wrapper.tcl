set root [file normalize .fpga-bridge/probe-bd]
cd $root
proc step {label script} {
    if {[catch {uplevel 1 $script} msg]} { puts "PROBE FAIL $label: $msg" } else { puts "PROBE OK $label" }
}
open_project $root/proj/proj.xpr
open_bd_design [get_files mb_system.bd]
step se { set_property -dict [list CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin}] [get_bd_cells clk_wiz_1] }
step clk { connect_bd_net [get_bd_ports sys_clock] [get_bd_pins clk_wiz_1/clk_in1] }
step layout { regenerate_bd_layout }
step validate { validate_bd_design }
foreach s [get_bd_addr_segs -hier] { puts "PROBE SEG $s [get_property OFFSET $s] [get_property RANGE $s]" }
step save { save_bd_design }
step tcl1 { write_bd_tcl -force $root/mb_system.tcl }
step wrapper { make_wrapper -files [get_files mb_system.bd] -top }
puts "PROBE WRAPPER [glob -nocomplain $root/proj/proj.gen/sources_1/bd/mb_system/hdl/*]"
close_bd_design [current_bd_design]
close_project
puts "PROBE DONE"
