#!/usr/bin/env bash
# Re-convert the MCD VHDL to Verilog for the co-sim, then re-point the
# testbench at the freshly-mangled net names.
#
# Why this exists: yosys renames every internal net to _NNNN_ and the numbers
# SHIFT whenever the VHDL changes, so any edit to ASIC.vhd/MCD.vhd silently
# breaks every tb probe. Run this after touching that VHDL, then build.sh.
#
# It also records which probes are unavailable: this yosys version optimizes
# away several MCD-level nets the CDC trace block used, which is why that
# block is #if 0'd in tb_full.cpp.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../../src/fpga/core/rtl

echo "=== 1/2 yosys-ghdl: MCD VHDL -> mcd.v"
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
write_verilog -noattr mcd.v
" > /dev/null

echo "=== 2/2 re-point tb probes at the new net names"
python3 - <<'PY'
import re
mcd = open('mcd.v').read()
tb  = open('tb_full.cpp').read()
# ASIC-internal probes the tb reads, by their VHDL signal name
want = ['cfm','cfs','sres','sbrq','ret0','ret1','dmna0','dmna1']
new = {}
for sig in want:
    m = re.search(r'assign %s = (_\d+_);' % sig, mcd)
    if m: new[sig] = m.group(1)
    else: print("  WARN: %s not found in mcd.v (optimized away?)" % sig)
# int_pend is a concat: { bits5:2, bit1=INT_PEND(2), bit0 }
m = re.search(r'assign int_pend = \{ (_\d+_), (_\d+_), (_\d+_) \};', mcd)
if m: new['int_pend2'] = m.group(2)
m = re.search(r'assign ien = (_\d+_);', mcd)
if m: new['ien'] = m.group(1)

# tb marks each probe with a trailing comment: /*sig:NAME*/
n = 0
def sub(mo):
    global n
    sig = mo.group(2)
    if sig in new:
        n += 1
        return 'asic__DOT__%s/*sig:%s*/' % (new[sig], sig)
    return mo.group(0)
tb2 = re.sub(r'asic__DOT__(_\d+_)/\*sig:(\w+)\*/', sub, tb)
open('tb_full.cpp','w').write(tb2)
print("  re-pointed %d probes: %s" % (n, ', '.join('%s=%s' % kv for kv in sorted(new.items()))))
PY
echo "done -- now run ./build.sh"
