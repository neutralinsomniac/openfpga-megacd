#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { \
    ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
    ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
 } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk }

derive_clock_uncertainty

set_false_path -to [get_ports {dram_clk}]

set_multicycle_path -from {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -to {ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -setup 2
set_multicycle_path -from {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -to {ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -hold 1

# sys->ram direction: the SDRAM controller retimes all request strobes
# through one RAM-clock capture stage (sdram.sv rd_q/wrl_q/wrh_q), so
# grant() fires no earlier than the second RAM edge after a request
# launches — address/data therefore have a full system-clock period to
# cross. Without this the half-period (4.65ns) window was violated by up
# to 2.5ns at 98% ALM utilization (random boot-time graphics corruption).
set_multicycle_path -from {ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -to {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -setup 2
set_multicycle_path -from {ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -to {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk} -hold 1

set_multicycle_path -from {ic|sdram|dout*} -to {ic|system|data*} -setup 2
set_multicycle_path -from {ic|sdram|dout*} -to {ic|system|data*} -hold 1

# The word-RAM port-2 alternate-source selects (BIOS download, PRG dumper,
# debug PRG peek) are quasi-static: each only transitions while the SDRAM
# request path is quiesced (explicit !wr_active / reset handshakes), yet
# they sit combinationally in the SDRAM command cone. Without these
# exceptions they were the entire setup-timing failure on the RAM clock
# (worst slack -2.5ns -> random boot-time graphics corruption).
set_false_path -from [get_registers {*|dump_active*}] -to [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_false_path -from [get_registers {*|dbg_prg_active*}] -to [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_false_path -from [get_registers {*|cart_download_s|*}] -to [get_clocks {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

set_multicycle_path -setup -start -from [get_keepers {*fx68k:*|Ir[*]}] -to [get_keepers {*fx68k:*|microAddr[*]}] 2
set_multicycle_path -hold -start -from [get_keepers {*fx68k:*|Ir[*]}] -to [get_keepers {*fx68k:*|microAddr[*]}] 1
set_multicycle_path -setup -start -from [get_keepers {*fx68k:*|Ir[*]}] -to [get_keepers {*fx68k:*|nanoAddr[*]}] 2
set_multicycle_path -hold -start -from [get_keepers {*fx68k:*|Ir[*]}] -to [get_keepers {*fx68k:*|nanoAddr[*]}] 1
set_multicycle_path -setup -start -from [get_keepers {*|nanoLatch[*]}] -to [get_keepers {*|excUnit|alu|pswCcr[*]}] 2
set_multicycle_path -hold -start -from [get_keepers {*|nanoLatch[*]}] -to [get_keepers {*|excUnit|alu|pswCcr[*]}] 1
set_multicycle_path -setup -start -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|excUnit|alu|pswCcr[*]}] 2
set_multicycle_path -hold -start -from [get_keepers {*|excUnit|alu|oper[*]}] -to [get_keepers {*|excUnit|alu|pswCcr[*]}] 1