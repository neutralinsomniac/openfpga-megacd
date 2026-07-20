#!/usr/bin/env bash
# Full-system co-sim build: Verilate core_top with converted VHDL + native
# SV/Verilog + sim SDRAM/PLL/RAM prims + C++ testbench.
set -uo pipefail
cd "$(dirname "$0")"
R=../../src/fpga/core

# native SV/Verilog (exclude sdram.sv + mf_pllbase, replaced by sim models)
NATIVE="
  $R/megacd_top.sv $R/megacd_cdd_stub.sv
  $R/data_loader.sv $R/data_unloader.sv $R/core_bridge_cmd.v
  $R/sound_i2s.sv $R/sync_fifo.sv
  $R/rtl/cheatcodes.sv $R/rtl/cofi.sv $R/rtl/EEPROM_STM95.sv $R/rtl/lightgun.sv
  $R/rtl/megacd/GEN/gen.sv $R/rtl/megacd/GEN/gen_io.sv
  $R/rtl/megacd/GEN/multitap.sv $R/rtl/megacd/GEN/teamplayer.sv
  $R/rtl/megacd/GEN/fourway.v $R/rtl/megacd/GEN/genesis_lpf.v $R/rtl/megacd/GEN/audio_iir_filter.v
  $R/rtl/mcd/CDDA_FIFO.v
  $R/rtl/FX68K/fx68k.sv $R/rtl/FX68K/fx68kAlu.sv $R/rtl/FX68K/uaddrPla.sv
"
JT="$(ls $R/rtl/jt12/*.v $R/rtl/jt12/mixer/*.v $R/rtl/jt12/dac/*.v $R/rtl/jt12/adpcm/*.v $R/rtl/jt89/*.v 2>/dev/null)"
APF="$R/../apf/common.v mf_datatable_sim.v"
CONV="vdp.v t80.v cart.v mcd.v"
SIM="sdram_sim.v pll_sim.v bram_prims.v ram_models.v dcfifo_sim.v"

cp $R/rtl/FX68K/microrom.mem $R/rtl/FX68K/nanorom.mem . 2>/dev/null || true

nix shell nixpkgs#verilator -c verilator --cc --exe --build -j 4 \
  --top-module core_top --no-assert-case \
  -Wno-fatal --no-timing -Wno-BLKANDNBLK -Wno-WIDTH -Wno-CASEINCOMPLETE \
  -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-LATCH -Wno-COMBDLY -Wno-CASEOVERLAP -Wno-PROCASSWIRE -Wno-IMPLICIT -Wno-BLKSEQ -Wno-SYMRSVDWORD \
  -I$R/rtl/FX68K -I$R/rtl/jt12 -I$R/rtl/jt89 \
  $CONV $SIM $NATIVE $JT $APF tb_full.cpp -o tb_full "$@"
