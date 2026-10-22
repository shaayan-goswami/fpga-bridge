# Block design format probe. Everything stays under .fpga-bridge/probe-bd/.
set root [file normalize .fpga-bridge/probe-bd]
file mkdir $root
cd $root
puts "PROBE root=$root vivado=[version -short]"
proc latest {name} {
    set defs [lsort [get_ipdefs -all xilinx.com:ip:${name}:*]]
    return [lindex $defs end]
}
proc step {label script} {
    if {[catch {uplevel 1 $script} msg]} { puts "PROBE FAIL $label: $msg" } else { puts "PROBE OK $label" }
}

create_project -force proj $root/proj -part xc7a35tcpg236-1
set_property target_language Verilog [current_project]

# ---- 1. MicroBlaze + AXI UART Lite + GPIO, with automation ----
create_bd_design mb_system
foreach ip {microblaze axi_uartlite axi_gpio clk_wiz} { puts "PROBE VLNV $ip [latest $ip]" }
step mb  { create_bd_cell -type ip -vlnv [latest microblaze] microblaze_0 }
step mbauto { apply_bd_automation -rule xilinx.com:bd_rule:microblaze -config { axi_intc {0} axi_periph {Enabled} cache {None} clk {New Clocking Wizard} cores {1} debug_module {Debug Only} ecc {None} local_mem {8KB} preset {None} } [get_bd_cells microblaze_0] }
step uart { create_bd_cell -type ip -vlnv [latest axi_uartlite] axi_uartlite_0 }
step uartcfg { set_property -dict [list CONFIG.C_BAUDRATE {115200}] [get_bd_cells axi_uartlite_0] }
step gpio { create_bd_cell -type ip -vlnv [latest axi_gpio] axi_gpio_0 }
step gpiocfg { set_property -dict [list CONFIG.C_GPIO_WIDTH {4} CONFIG.C_ALL_OUTPUTS {1}] [get_bd_cells axi_gpio_0] }
step uartauto { apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/microblaze_0 (Periph)} Slave {/axi_uartlite_0/S_AXI} ddr_seg {Auto} intc_ip {New AXI Interconnect} master_apm {0}} [get_bd_intf_pins axi_uartlite_0/S_AXI] }
step gpioauto { apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} Master {/microblaze_0 (Periph)} Slave {/axi_gpio_0/S_AXI} ddr_seg {Auto} intc_ip {Auto} master_apm {0}} [get_bd_intf_pins axi_gpio_0/S_AXI] }
step uartext { make_bd_intf_pins_external [get_bd_intf_pins axi_uartlite_0/UART] }
step gpioext { make_bd_intf_pins_external [get_bd_intf_pins axi_gpio_0/GPIO] }
foreach c [get_bd_cells -hier] { puts "PROBE CELL $c [get_property VLNV $c] [get_property TYPE $c]" }
foreach p [get_bd_pins -of [get_bd_cells clk_wiz*]] { puts "PROBE CLKPIN $p [get_property DIR $p] [get_property TYPE $p]" }
# Clock and reset in from outside, as a board without a preset needs.
step clkext { make_bd_pins_external [get_bd_pins -of [get_bd_cells clk_wiz*] -filter {NAME == clk_in1}] }
step rstwiz { make_bd_pins_external [get_bd_pins -of [get_bd_cells clk_wiz*] -filter {NAME == reset || NAME == resetn}] }
step rstsys { connect_bd_net [get_bd_pins -of [get_bd_ports -filter {TYPE == rst}] ] [get_bd_pins rst_clk_wiz_1_100M/ext_reset_in] }
step layout { regenerate_bd_layout }
step validate { validate_bd_design }
foreach s [get_bd_addr_segs -of [get_bd_addr_spaces -of [get_bd_cells microblaze_0]]] { puts "PROBE SEG $s [get_property OFFSET $s] [get_property RANGE $s]" }
step save { save_bd_design }
step tcl1 { write_bd_tcl -force $root/mb_system.tcl }
puts "PROBE BDFILE [get_files mb_system.bd]"
close_bd_design [current_bd_design]

# ---- 2. Hand-wired: external ports, plain nets, a constant, a concat, a hierarchy, an RTL module ----
set f [open $root/blink.v w]
puts $f "module blink #(parameter WIDTH = 24) (input clk, input rst, output [3:0] led);\n  reg \[WIDTH-1:0\] count;\n  always @(posedge clk) if (rst) count <= 0; else count <= count + 1;\n  assign led = count\[WIDTH-1 -: 4\];\nendmodule"
close $f
add_files -norecurse $root/blink.v
update_compile_order -fileset sources_1
create_bd_design wired
step ports {
    create_bd_port -dir I -type clk -freq_hz 100000000 sys_clk
    create_bd_port -dir I -type rst sys_rst
    create_bd_port -dir O -from 3 -to 0 led
    create_bd_port -dir I -from 1 -to 0 sw
    create_bd_port -dir O ready
}
step cells {
    create_bd_cell -type ip -vlnv [latest util_vector_logic] inv_0
    set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells inv_0]
    create_bd_cell -type ip -vlnv [latest xlconstant] one
    create_bd_cell -type ip -vlnv [latest xlconcat] concat_0
    set_property -dict [list CONFIG.NUM_PORTS {2}] [get_bd_cells concat_0]
}
step hier {
    create_bd_cell -type hier sync
    create_bd_pin -dir I sync/clk
    create_bd_pin -dir I -from 1 -to 0 sync/d
    create_bd_pin -dir O -from 1 -to 0 sync/q
    create_bd_cell -type ip -vlnv [latest util_vector_logic] sync/and_0
    set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {2}] [get_bd_cells sync/and_0]
    connect_bd_net [get_bd_pins sync/d] [get_bd_pins sync/and_0/Op1] [get_bd_pins sync/and_0/Op2]
    connect_bd_net [get_bd_pins sync/and_0/Res] [get_bd_pins sync/q]
}
step modref { create_bd_cell -type module -reference blink blink_0 }
step nets {
    connect_bd_net [get_bd_ports sys_rst] [get_bd_pins inv_0/Op1]
    connect_bd_net [get_bd_ports sys_clk] [get_bd_pins sync/clk] [get_bd_pins blink_0/clk]
    connect_bd_net [get_bd_ports sw] [get_bd_pins sync/d]
    connect_bd_net [get_bd_pins sync/q] [get_bd_pins concat_0/In0]
    connect_bd_net [get_bd_pins one/dout] [get_bd_pins concat_0/In1] [get_bd_ports ready]
    connect_bd_net [get_bd_pins blink_0/led] [get_bd_ports led]
}
step rst2 { connect_bd_net [get_bd_ports sys_rst] [get_bd_pins blink_0/rst] }
step layout2 { regenerate_bd_layout }
step validate2 { validate_bd_design }
step save2 { save_bd_design }
step tcl2 { write_bd_tcl -force $root/wired.tcl }
puts "PROBE BDFILE [get_files wired.bd]"
close_bd_design [current_bd_design]
close_project
puts "PROBE DONE"
