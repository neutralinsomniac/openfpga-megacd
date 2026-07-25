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

##############################################################################
# SDRAM external interface
#
# Part: Alliance Memory AS4C32M16MSA-6BIN  (LPSDR mobile SDRAM, 32M x 16,
# 1.8V, -6 grade = 166MHz @ CL3), per Analogue's openFPGA hardware docs.
#
# Until this block existed the entire dram_* interface was UNCONSTRAINED --
# all 16 dram_dq inputs and all 43 dram_* outputs appeared in the Timing
# Analyzer's "Unconstrained Ports" tables. Every slack number the design has
# ever reported described internal fabric only; the one interface that talks
# to an off-chip part -- the one holding the BIOS, PRG-RAM and word-RAM --
# was never checked.
##############################################################################

# --- datasheet AC parameters (ns) -------------------------------------------
# TODO(verify): Alliance/Mouser/LCSC all bot-block datasheet PDF fetches, so
# these are the standard JEDEC LPSDR -6 / CL3 values, corroborated only by
# Mouser's "5.5ns access time" listing for this part. Confirm against the
# real AC Characteristics table before trusting the margins below.
set tAC  5.5   ;# access time from CLK, CL3 (max)
set tOH  2.5   ;# output data hold from CLK (min)
set tIS  1.5   ;# input setup to CLK
set tIH  0.8   ;# input hold from CLK

# --- board allowance --------------------------------------------------------
# FPGA <-> SDRAM traces are short on the Pocket; this is an estimate.
set tPCB_max 0.2
set tPCB_min 0.0

# --- the clock the SDRAM chip actually sees ---------------------------------
# dram_clk is driven by an ALTDDIO_OUT with datain_h=0 / datain_l=1
# (core/rtl/megacd/sdram.sv:346), i.e. it is clk_ram INVERTED: the chip's
# rising edge lands on clk_ram's falling edge. Modelling it as a real
# generated clock replaces the old blanket "set_false_path -to dram_clk",
# which simply hid the port from analysis.
set ram_clk {ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}

create_generated_clock -name dram_clk_pin \
    -source [get_pins $ram_clk] -invert [get_ports {dram_clk}]

# --- command / address / write data (FPGA -> SDRAM) -------------------------
# Verified passing on the current fit: setup +1.588, hold +3.575.
set dram_out [get_ports {dram_a[*] dram_ba[*] dram_dq[*] dram_dqm[*] \
                         dram_ras_n dram_cas_n dram_we_n dram_cke}]

set_output_delay -clock dram_clk_pin -max [expr {  $tIS + $tPCB_max }] $dram_out
set_output_delay -clock dram_clk_pin -min [expr { -$tIH + $tPCB_min }] $dram_out

# --- read data (SDRAM -> FPGA) ----------------------------------------------
set_input_delay  -clock dram_clk_pin -max [expr {  $tAC + $tPCB_max }] [get_ports {dram_dq[*]}]
set_input_delay  -clock dram_clk_pin -min [expr {  $tOH + $tPCB_min }] [get_ports {dram_dq[*]}]

# STA cannot see DLY_CL -- that is a protocol wait inside the controller's
# FSM, not a clock relationship. Left alone, STA checks "launched by a
# dram_clk_pin edge, captured on the NEXT clk_ram edge", which corresponds
# to the controller sampling the pad at E4 (E0 = the edge that registers the
# CAS command). This multicycle is what tells it otherwise, and the value is
# derived from the controller rather than tuned for a green report:
#
#   * dram_clk_pin edges sit at E(k)+4.656ns (dram_clk is clk_ram inverted).
#     The chip samples CAS at E0+4.656; CL3 puts the launching edge at
#     E0+4.656+3*9.312 = E0+32.592.
#   * do_cas sets dly<=DLY_CL, FSM_CAS latches at E(DLY_CL+1) reading dq_in,
#     which sampled the pad one edge earlier -- so the pad is sampled at
#     E(DLY_CL). With DLY_CL=5 that is E0+46.560.
#   * 46.560 - 32.592 = 13.968ns = the default 4.656 plus one clk_ram
#     period. Hence -setup 2.
#
# Cross-check: STA's default relationship maps exactly onto DLY_CL=4, and at
# DLY_CL=4 it measured -7.515 -- one period short, which is precisely why
# DLY_CL is 5. The two agree independently.
set_multicycle_path -setup 2 -from [get_clocks dram_clk_pin] -to [get_clocks $ram_clk]
set_multicycle_path -hold  1 -from [get_clocks dram_clk_pin] -to [get_clocks $ram_clk]

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