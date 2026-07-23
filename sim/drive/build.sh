#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
R=../../src/fpga/core
export PATH=/nix/store/5jdp0w7zqpygrmr9kwd6yhdzb29khi1v-verilator-5.048/bin:$PATH
verilator --cc --exe --build -j 8 -O3 \
  --top-module megacd_cdd_drive \
  -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE \
  $R/megacd_cdd_drive.sv tb_drive.cpp -o tb_drive "$@"
