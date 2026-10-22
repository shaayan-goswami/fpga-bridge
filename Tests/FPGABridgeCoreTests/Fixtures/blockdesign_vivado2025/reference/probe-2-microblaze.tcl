set root [file normalize .fpga-bridge/probe-bd]
cd $root
puts "PROBE vivado=[version -short]"
proc latest {name} { return [lindex [lsort -dictionary [get_ipdefs -all xilinx.com:ip:${name}:*]] end] }
proc step {label script} {
    if {[catch {uplevel 1 $script} msg]} { puts "PROBE FAIL $label: $msg" } else { puts "PROBE OK $label" }
}
open_project $root/proj/proj.xpr
catch { remove_files [get_files mb_system.bd] }
file delete -force $root/proj/proj.srcs/sources_1/bd/mb_system
create_bd_design mb_system
foreach ip {microblaze axi_uartlite axi_gpio clk_wiz proc_sys_reset} { puts "PROBE VLNV $ip [latest $ip]" }
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
set wiz [get_bd_cells -filter {VLNV =~ *clk_wiz*}]
set rst [get_bd_cells -filter {VLNV =~ *proc_sys_reset*}]
puts "PROBE WIZ $wiz RST $rst"
foreach p [get_bd_pins -of $wiz] { puts "PROBE WIZPIN $p [get_property DIR $p] [get_property TYPE $p] [get_property NET $p]" }
step clkport {
    create_bd_port -dir I -type clk -freq_hz 100000000 sys_clock
    connect_bd_net [get_bd_ports sys_clock] [get_bd_pins $wiz/clk_in1]
}
step rstport {
    create_bd_port -dir I -type rst reset
    set_property CONFIG.POLARITY ACTIVE_HIGH [get_bd_ports reset]
    connect_bd_net [get_bd_ports reset] [get_bd_pins $wiz/reset] [get_bd_pins $rst/ext_reset_in]
}
step layout { regenerate_bd_layout }
step validate { validate_bd_design }
foreach s [get_bd_addr_segs -hier] { puts "PROBE SEG $s [get_property OFFSET $s] [get_property RANGE $s]" }
step save { save_bd_design }
step tcl1 { write_bd_tcl -force $root/mb_system.tcl }
puts "PROBE BDFILE [get_files mb_system.bd]"
close_bd_design [current_bd_design]
close_project
puts "PROBE DONE"
