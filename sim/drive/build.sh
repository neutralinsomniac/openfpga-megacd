#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
R=../../src/fpga/core
# resolve verilator via nix each run: a hardcoded store path dies at the
# next GC (this script silently ran a stale binary for 5 days that way)
nix shell nixpkgs#verilator -c verilator --cc --exe --build -j 8 -O3 \
  --top-module megacd_cdd_drive \
  -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE \
  $R/megacd_cdd_drive.sv tb_drive.cpp -o tb_drive "$@"
