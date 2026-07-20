#!/usr/bin/env bash
# M2 co-simulation build: convert the MegaCD VHDL subsystem to Verilog via
# yosys-ghdl, then Verilate it together with the native fx68k (SystemVerilog),
# the CDDA FIFO (Verilog), behavioral RAM models, and the C++ testbench.
#
# Usage: nix develop ..#  (or run under a shell with nix)  then ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../../src/fpga/core/rtl

echo "=== 1/2 yosys-ghdl: MCD VHDL -> Verilog"
YOSYS=$(nix build --impure --no-link --print-out-paths \
  --expr 'let p = import <nixpkgs> {}; in p.yosys.withPlugins [ p.yosys-ghdl ]')/bin/yosys
"$YOSYS" -m ghdl -p "
ghdl --std=08 -fsynopsys -frelaxed \
  bram_sim.vhd codes_stub.vhd $ROOT/megacd/CEGen.vhd \
  $ROOT/mcd/ASIC_PKG.vhd $ROOT/mcd/ASIC.vhd $ROOT/mcd/CDC.vhd \
  $ROOT/mcd/PCM.vhd $ROOT/mcd/CDDA.vhd $ROOT/mcd/MC68K.vhd $ROOT/mcd/MCD.vhd -e MCD
blackbox fx68k CDDA_FIFO dpram_* dpram_dif_* spram_*
hierarchy -top MCD
proc
write_verilog -noattr mcd_yosys.v
"

echo "=== 2/2 verilator build"
cp $ROOT/FX68K/microrom.mem $ROOT/FX68K/nanorom.mem .
nix shell nixpkgs#verilator -c verilator --cc --exe --build -j 4 \
  --top-module MCD --no-assert-case \
  -Wno-fatal --no-timing -Wno-BLKANDNBLK -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
  -I$ROOT/FX68K \
  mcd_yosys.v ram_models.v \
  $ROOT/FX68K/fx68k.sv $ROOT/FX68K/fx68kAlu.sv $ROOT/FX68K/uaddrPla.sv \
  $ROOT/mcd/CDDA_FIFO.v \
  tb_mcd.cpp -o tb_mcd

echo "=== done: sim/m2/obj_dir/tb_mcd"
echo "run: ./obj_dir/tb_mcd --rom <bios.bin> [--prg <prgram-dump.bin>] --cycles N"
