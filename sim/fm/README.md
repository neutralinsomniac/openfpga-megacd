# FM accuracy bench: jt12 vs Nuked-OPN2

Replays a YM2612 register-write stream into both the Verilated `jt12`
used by this core and nukeykt's die-netlist-derived `ym3438.c` (the C
twin of Nuked-MD-FPGA's ym3438, vendored in GPGX at
`~/src/Genesis-Plus-GX/core/sound/ym3438.c`), then diffs the two audio
streams. Purpose: find jt12 accuracy bugs with silicon ground truth.

## Build

    ./build.sh          # verilates rtl/jt12 + links GPGX ym3438.c -> obj_dir/tb_fm

## Real-game stimulus

Capture a write log with the GPGX headless runner (see the
`gpgx-headless-ground-truth` memory; `FMLOG=1` makes the patched
`core/sound/sound.c` emit `F/R/Z/E` lines on stderr):

    SYSDIR=... FMLOG=1 ./runner genesis_plus_gx_libretro.so game.cue 5400 400 2>fmlog.txt
    ./obj_dir/tb_fm fmlog.txt out 3.0 [--asic]
    nix-shell -p python3Packages.numpy --run "python3 analyze.py out --wav"

`--asic` runs both models as YM3438 (no DAC ladder) to separate DAC-shape
differences from envelope/phase logic. Default mode is discrete YM2612
with ladder, matching `core_top.sv` (`LADDER(~cs_fm_chip)`).

## Per-feature battery

    ./run_tests.sh <workdir> [--asic]

`gen_tests.py` synthesizes one write log per feature (envelope rates,
SSG-EG modes, LFO AM/PM, algorithms/feedback, detune/MUL, ch3 special,
CSM, DAC, key-on slot combos, fnum latch sharing); `compare_test.py`
reports sustained envelope error in dB and pitch mismatches per test.
Gain is calibrated once from the `reference` test so absolute level bugs
are not masked.

## Timing model

One bench tick = YM input clock (MCLK/7); jt12 runs `cen=1` at that
clock (equivalent to gen.sv's MCLK + 1-of-7 cen, 7x faster to simulate).
Both models advance one internal cycle per 6 ticks; writes land on the
same tick in both, reconstructed from the log's per-frame `E` markers.

## Findings and fixes (2026-07-31)

Fixed (validated against the die model with this bench):

- SSG-EG hold-at-silence: envelope now snaps to 0x3FF + release once it
  crosses 0x200 outside the hold-up modes, and key-off writes back the
  inverted level (jt12_eg_ctrl/jt12_eg_pure `ssg_off`/`ssg_wb`). Was a
  constant -48 dB residual tone (eg parked at 0x200) in hold modes 1/7,
  now silicon-exact. Battery ssg test: 62.4% -> 50.9% bad bins, 195 dB ->
  37.7 dB max err (residual = repeat-phase drift below). Note: the Lunar
  capture does NOT exercise this (its 0x9x writes are mostly 0x07 = SSG
  disabled; the few enabled ones are modes 5/6) - jt12 output on that
  capture is bit-identical pre/post this fix.
- Ladder offsets (jt12_acc.v, per-channel accumulators): +7/0/-6 ->
  silicon's +4/-3 panned-in, +/-4 sign leak panned-out. BIOS jingle
  ladder-mode err 31.3% -> 8.2%; in-game 22.6% -> 15.2% global (audible
  band 21.3% -> 11.8%), median window 4.25% -> 1.03%, p95 2.9%.

Known remaining (minor):

- SSG repeat-rate drift ~0.6% (38.05 vs 38.29 ms at DR=18); blows up for
  ultrasonic SSG repeat carriers (25.2 kHz vs 18-22 kHz on Lunar's
  mode-6 instrument at t=73-77s - the dominant remaining in-game
  divergence, 44.7% in that section vs 12.5% elsewhere). Audible-band
  components of that instrument match within ~5%.
- CSM: first auto key-on after enable missed; steady 0.73 dB offset.
- ch3 special mode ~1 dB; shared-fnum-latch corner ~1.1 dB.
- Intra-sample DAC latch skew (channel values latch mid-sample on the
  die; jt12 latches once per sample).
