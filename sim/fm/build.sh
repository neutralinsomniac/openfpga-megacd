#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
R=../../src/fpga/core/rtl/jt12
GPGX=~/src/Genesis-Plus-GX/core/sound
export PATH=/nix/store/5jdp0w7zqpygrmr9kwd6yhdzb29khi1v-verilator-5.048/bin:$PATH

# GPGX's ym3438.c needs its INLINE macro and pulls shared.h only for that
gcc -c -O2 -o obj_ym3438.o "$GPGX/ym3438.c" -DINLINE="static inline" -DHAVE_YM3438_CORE -I"$GPGX" || exit 1

verilator --cc --exe --build -j 8 -O3 \
  --top-module jt12 \
  -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-UNUSEDSIGNAL -Wno-CASEINCOMPLETE \
  -y "$R" -y "$R/adpcm" -y "$R/mixer" -y "$R/dac" \
  "$R/jt12.v" tb_fm.cpp "$(pwd)/obj_ym3438.o" \
  -CFLAGS "-I$GPGX -I$(pwd)" \
  -o tb_fm "$@"
