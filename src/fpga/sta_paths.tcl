project_open ap_core -revision megacd
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 20 -detail path_only -file output_files/setup_paths.rpt
report_timing -hold -npaths 8 -detail path_only -file output_files/hold_paths.rpt
project_close
