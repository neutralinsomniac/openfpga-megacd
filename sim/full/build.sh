#!/usr/bin/env bash
# Full-system co-sim build: Verilate core_top with converted VHDL + native
# SV/Verilog + sim SDRAM/PLL/RAM prims + C++ testbench.
set -uo pipefail
cd "$(dirname "$0")"
R=../../src/fpga/core

# native SV/Verilog (exclude sdram.sv + mf_pllbase, replaced by sim models)
NATIVE="
  $R/megacd_top.sv $R/megacd_cdd_stub.sv $R/megacd_cdd_drive.sv
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
# REALSD=1: use the real rtl/megacd/sdram.sv controller (renamed sdram_ctrl,
# altddio stripped) + behavioral SDRAM chip, instead of the idealized model
if [ "${REALSD:-0}" = "1" ]; then
  tr -d '\r' < $R/rtl/megacd/sdram.sv | \
  sed -e 's/^module sdram$/module sdram_ctrl/' \
      -e '/^altddio_out/,/^);$/d' \
      -e 's/\tinout  reg \[15:0\] SDRAM_DQ,.*/\toutput reg [15:0] SDRAM_DQ, input [15:0] SDRAM_DQ_IN, output reg SDRAM_DQ_OE,/' \
      -e "s/SDRAM_DQ <= 'Z;/SDRAM_DQ_OE <= 0;/" \
      -e 's/dout0_r <= SDRAM_DQ;/dout0_r <= SDRAM_DQ_IN;/' \
      -e 's/dout <= SDRAM_DQ;/dout <= SDRAM_DQ_IN;/' \
      -e 's/dout1_r <= SDRAM_DQ;/dout1_r <= SDRAM_DQ_IN;/' \
      -e 's/dout2_r <= SDRAM_DQ;/dout2_r <= SDRAM_DQ_IN;/' > sdram_ctrl_gen.v
  SDMOD="sdram_real.v sdram_ctrl_gen.v"
else
  SDMOD="sdram_sim.v"
fi
SIM="$SDMOD pll_sim.v bram_prims.v ram_models.v dcfifo_sim.v"

cp $R/rtl/FX68K/microrom.mem $R/rtl/FX68K/nanorom.mem . 2>/dev/null || true

nix shell nixpkgs#verilator -c verilator --cc --exe --build -j 8 \
  -O3 -CFLAGS "-O2 -march=native ${REALSD:+-DREALSD}" \
  --top-module core_top --no-assert-case \
  -Wno-fatal --no-timing -Wno-BLKANDNBLK -Wno-WIDTH -Wno-CASEINCOMPLETE \
  -Wno-UNOPTFLAT -Wno-MULTIDRIVEN -Wno-LATCH -Wno-COMBDLY -Wno-CASEOVERLAP -Wno-PROCASSWIRE -Wno-IMPLICIT -Wno-BLKSEQ -Wno-SYMRSVDWORD \
  -I$R/rtl/FX68K -I$R/rtl/jt12 -I$R/rtl/jt89 \
  $CONV $SIM $NATIVE $JT $APF tb_full.cpp -o tb_full "$@"
