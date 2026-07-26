# Full-system co-simulation (in progress)

Goal: Verilate the entire megacd core so the real MAIN 68000 (CD-player
code) drives the sub via real commands, faithfully reproducing the
CD-player freeze for in-sim debugging.

## Running it (READ THIS FIRST)

    ./obj_dir/tb_full +bios=bios_scd2.hex --cd "/path/to/game.cue" --cycles 40000000

`+bios=` is NOT optional and there is no warning if you forget it. Without
it the sim SDRAM has no BIOS image, the main 68000 executes empty memory,
and everything still *looks* alive -- frames render, VBL advances, the
mstate histogram fills in, the address bus wanders plausibly. Every number
you collect is meaningless. An entire profiling session was lost to this.

Use `bios_scd2.hex`. It is byte-identical to us_scd2_9306.bin, the BIOS the
core actually runs on hardware (verified: 65536/65536 words). `bios_us.hex`
is an older US BIOS that additionally demands an export machine --

    0007BA  MOVE.B $A10001,D0     ; version register
    0007C0  ANDI.B #$C0,D0
    0007C4  CMPI.B #$80,D0        ; bit7=1 export, bit6=0 NTSC
    0007C8  BNE.S  $07CC          ; mismatch -> error, then BRA.S * at $07FA

-- and the core drives .EXPORT(|region_req), where region_req is only ever
assigned from a CARTRIDGE header (hdr_u/hdr_e/hdr_j). On a CD boot no cart
loads, so it stays 0 = domestic and that BIOS hangs at $07FA forever. Not a
core bug; hardware runs the scd2 BIOS, which has no such check.

Also note the "MAIN EXCEPTION VECTOR FETCH" message is a heuristic that
fires on the first address-bus value in 0x08..0xFF after 1M cycles. The
BIOS copying its vector table into work RAM ($48..$72 then $FFFD0x) trips
it during a perfectly healthy boot. Confirm against the main PC before
believing it.

## Toolchain (proven)
yosys -m ghdl converts VHDL -> Verilog; Verilator builds it with the
native SV/Verilog. See sim/m2/ for the working MCD-only sub-BIOS sim.

## Conversion status
- bram_sim.vhd: all RAM primitives (spram, dpram, dpram_dif, mlab,
  DualPortRAM, obj_cache) — behavioral, no altera_mf. DONE.
- VDP converts: `ghdl --std=08 -fsynopsys -frelaxed --latches
  bram_sim.vhd vdp_common.vhd vdp.vhd -e vdp` -> vdp.v (7 modules). DONE.
- MCD hierarchy converts (see sim/m2/build.sh). DONE.
- TODO: convert T80pa (Z80), CART, CEGen the same way (each -e <top>).

## Remaining integration work
1. RAM models: yosys mangles RAM module names per generic; either provide
   matching Verilog models (as sim/m2/ram_models.v) for every shape used
   across VDP/T80/CART/MCD, or solve the write_verilog $mem clk_enable
   assert to emit them inline.
2. Replace core/rtl/megacd/sdram.sv with a behavioral sim SDRAM (3-port
   word interface, preloadable memory) — load BIOS at word $780000.
3. Stub mf_pllbase -> passthrough clocks (clk_sys, clk_ram=2x).
4. C++ tb (extend sim/m2/tb_mcd.cpp approach): tie off video/audio/cart/
   controller pins on core_top, drive reset_n, run, trace both CPU PCs.
5. Native SV/V to feed Verilator: megacd_top.sv, gen.sv, gen_io.sv,
   multitap/teamplayer.sv, fourway/genesis_lpf/audio_iir.v, fx68k,
   jt12/*, jt89/*, CDDA_FIFO.v, sound_i2s, data_(un)loader, cofi,
   lightgun, sync_fifo, core_bridge_cmd, EEPROM_STM95, cheatcodes.

## Verilator assembly status (near-complete)
The ENTIRE core Verilates (all converted VHDL + native SV/V + jt12/jt89 +
sim SDRAM/PLL/RAM/dcfifo) except ONE systematic issue:

**Port-case mismatch.** yosys lowercases VHDL port names (VRAM_we ->
vram_we), but gen.sv/megacd_top.sv instantiate the converted modules with
the original mixed case. MCD's top ports survived uppercase (it was the -e
top); VDP and T80pa did not. FIX: add thin Verilog wrapper modules
`vdp`/`T80pa` (and verify CART) that expose the mixed-case port names the SV
expects and wire them to the lowercase converted `vdp`/`t80pa` — OR
post-process the converted .v to restore case from the VHDL entity decls.
After that, iterate any remaining PINNOTFOUND/WIDTH runtime issues, then
flesh out tb_full.cpp (preload SDRAM via sdram_sim $readmemh with BIOS at
word $780000, drive clk_74a at clk_ram rate, hold reset_n, trace both PCs).

Fixed so far: joystick trailing commas (megacd_top.sv), dcfifo params,
dcfifo/sdram/pll/bram sim models.

## Boot status: main CPU stalls at $FF00FA
Full system boots; main 68000 runs the real BIOS from work RAM but its
address bus FREEZES at exactly $FF00FA (static, not a loop) ~= a bus access
stalled waiting for DTACK, or a halt/missing-interrupt. Prime suspects:
(1) behavioral sim SDRAM (sdram_sim.v) busy/RDY handshake on the work-RAM
port (port 1) — verify it matches core/rtl/megacd/sdram.sv timing exactly;
(2) missing VDP vblank interrupt to the main (check VDP CE_PIX/VBL and the
main's VINT wiring in sim). Debug: mark the sim SDRAM mem + gen RAM_RDY/
DTACK signals public, watch them at the stall; disassemble the copied-to-
RAM routine at $FF00FA (work RAM = SDRAM word $400000 + (VA[15:1])).

## $FF00FA diagnosis (root cause narrowed)
Main 68000 executes a STOP and waits for an interrupt (static PC, bus idle,
mstate=IDLE, CPU still clocked). The VDP RUNS (CE_PIX climbs, VBL recurs
each frame 1->2->3) but VINT never asserts because IE0 (VDP reg1 bit5,
vblank-interrupt enable) stays 0. So the main STOPs forever waiting for a
vblank IRQ that can't fire. NEXT: determine why IE0=0 —
(a) trace whether the main ever writes VDP reg $01 with bit5 (mark the VDP
    register-write path public; a yosys-conversion fidelity bug in the VDP
    control-port write would explain register writes not landing), or
(b) the main is waiting on a different interrupt/event before it would set
    IE0 (disassemble the STOP site: main work RAM $FF00FA = SDRAM word
    $400000+($00FA>>1); dump that SDRAM word range to disassemble).
Public signals available: gen.mstate, gen.M68K_MBUS_DTACK_N,
gen.M68K_CLKENp, gen.M68K_VINT, vdp.ie0, vdp.vint_tg68_pending,
core_top.ce_pix, core_top.vblank_sys, dbg_m68k_a, dbg_s68k_a.

## Refinement: $FF00FA is the address bus, not the STOP PC
Work RAM at $FF00FA is all zeros, so dbg_m68k_a (= raw M68K_A address bus)
is holding the last address driven before STOP, not the STOP instruction
site. To pin the real cause, next session should: (a) capture the true PC
at STOP (e.g. tap the fx68k PC / last-fetched-instruction, or watch AS_N
falling edges and record the fetch address), and (b) trace VDP control-port
writes to reg $01 — count them and check bit5. If the main never writes
reg1 bit5, it's stalled before VDP-IRQ-enable (a different, earlier cause);
if it writes but IE0 stays 0, the converted VDP control-port write path is
the bug. sdram mem is now public (core_top.sdram.mem) for RAM dumps; note
work RAM = SDRAM word $400000+(VA[15:1]).

## FIXED: BIOS byte order (2026-07-20)
The BIOS must be loaded big-endian (NOT byte-swapped) into sim SDRAM. The
earlier swap corrupted the main reset vector ($426 -> $2604) and the main
ran into data and hung. Generate bios.hex as: @780000 then per word
"%02x%02x" % (d[i], d[i+1]). With this, the main boots, runs the init loop
(~$498), and jumps to work-RAM execution ($FF3714+). Boot now PROGRESSES.

## Boot progress after byte-order fix
Main now: init loop (~$498) -> work-RAM exec ($FF3714) -> VINT enabled and
FIRING (vblank IRQ works) -> now waits at $AF0:
  00AF0: move.w (a6),d3     ; a6=$C00004 VDP control/status
  00AF2: btst #1,d3         ; bit1 = IN_DMA (DMA in progress)
  00AF6: bne  $AF0          ; loop while DMA busy
It set up + triggered a VDP DMA fill ($AE0-$AEC) and waits for IN_DMA to
clear, but the converted VDP's IN_DMA never clears -> hang. NEXT: debug the
VDP DMA state machine in the conversion (IN_DMA / DMA fill completion; check
if the --latches conversion or a slot-timing signal broke DMA). Mark the
VDP DMA-active + DMA-length signals public and watch them. Sub still in
reset (main hasn't reached SRES release yet).

## VDP fill-DMA stuck (in_dma=1, dma_fill=1 permanently)
Main boots fully and hangs at $AF0 polling VDP status bit1 because a VRAM
FILL DMA never completes (confirmed: in_dma=1 fill=1 vbus=0 copy=0 forever).
The fill state machine (vdp.vhd DMA_FILL_INIT/START/WR/WR2/NEXT/LOOP)
advances only when SLOT_EN=1 (whole DMA dispatch gated by `if SLOT_EN='1'`
~line 3037) and each VRAM write completes (DT_VRAM_SEL toggle handshake).
NEXT: mark DMAC (the dma_t state enum), SLOT_EN, DT_VRAM_SEL/DT_VRAM_ACK
public in vdp.v; find the exact stuck sub-state. Suspects: SLOT_EN not
pulsing (its enable/CE broke in the yosys/--latches conversion), or the
converted VDP VRAM dpram access handshake (DT_VRAM_SEL) not completing.
VRAM_SPEED is 0 in sim (gen.sv `.VRAM_SPEED(1)` is commented out) so the
FILL_WR VRAM_SPEED/FIFO_EN gate is satisfied — not the cause.

## Fill-DMA stuck at DMA_FILL_START — root: FIFO not draining
Probed: dmac=2 (DMA_FILL_START), slot_en_edges=245K (SLOT_EN FINE, ruled
out), but FIFO_EMPTY=0 and DMAF_SET_REQ=1 permanently. DMA_FILL_START
advances only on `FIFO_EMPTY=1 and DTC=DTC_IDLE and DMAF_SET_REQ=0`. So the
VDP command/data FIFO never drains and the fill-data request never clears.
The DT (data-transfer) engine drains the FIFO to VRAM during slots; earlier
VDP writes DID drain (VINT setup worked), so it's now wedged. NEXT: mark DTC
(the data-transfer-controller state), FIFO_EMPTY inputs, and DMAF_SET_REQ's
clear logic public; find why the FIFO stopped draining / DMAF_SET_REQ won't
clear. Prime suspect: DMAF_SET_REQ clear path or the DT engine's FIFO-read
gating in the converted VDP. Public probes now include vdp.dmac/slot_en/
dt_vram_sel/fifo_empty/dmaf_set_req/in_dma/dma_fill.

## SINGLE ROOT: VDP FIFO_EMPTY never asserts (DT engine not draining)
Both blockers (fill can't leave FILL_START; DMAF_SET_REQ can't clear @line
3238) gate on FIFO_EMPTY=1. It's stuck at 0 -> the VDP command/data FIFO
never drains. The FIFO drains via the DTC (data-transfer controller) engine
writing FIFO entries to VRAM during slots. Earlier VDP writes DID drain
(VINT setup worked) so it's a state-dependent wedge — likely a deadlock or
a converted-VDP bug in the DTC/FIFO-read path during DMA setup. NEXT: mark
DTC state + FIFO read/write pointers (fifo_rd_pos/fifo_wr_pos/fifo_queue)
public; find why DTC stopped draining the FIFO. This is the one signal to
fix to advance the full-system boot past the SEGA-logo DMA.

## FULLY TRACED: VDP FIFO won't drain (converted-VDP fidelity bug)
Chain: main boots -> waits VDP DMA-busy -> fill stuck DMA_FILL_START ->
needs FIFO_EMPTY -> FIFO never empty. Probed at hang: DTC=IDLE(0),
fifo_queue=4 (FULL), fifo_partial=1 (stuck), fifo_en=0, SLOT_EN pulsing.
Drain (DTC_IDLE->FIFO_RD @vdp.vhd:3053) needs FIFO_DELAY(rd_pos)=0;
FIFO_DELAY decrements on SLOT_EN (2913-2916) which pulses, yet drain never
fires and FIFO_PARTIAL (cleared only on FIFO_EN, 3049) is stuck. => the
yosys --latches SYNTHESIS of the VDP mis-handled the FIFO_DELAY array
per-element decrement and/or FIFO_PARTIAL/FIFO_EN timing (lossy gate-level
conversion; VDP needed --latches = a red flag).

FIX DIRECTIONS (next session):
1. BEST: simulate the VDP as real VHDL instead of yosys-synthesized gates —
   e.g. cocotb+GHDL for the VHDL modules co-sim'd with Verilator for the
   SV/Verilog, or a VHDL-capable simulator for the whole thing. Avoids all
   conversion-fidelity bugs (this won't be the last).
2. FASTER: mark FIFO_DELAY(0..3)/FIFO_EN public, confirm the exact stuck
   element, and patch the converted vdp.v (or re-convert VDP with tweaked
   yosys flags / a behavioral pre-pass) so the array decrement + partial
   clear work.
The MCD-only co-sim (sim/m2, no VDP) is unaffected and remains the fast
path for the actual CDD/CDC drive debugging if the full-system VDP proves
too costly to make faithful.

## RESOLVED (2026-07-20 session 2): not a conversion bug — VRAM_SPEED
New probes (fifo_delay/fifo_rd_pos/fifo_wr_pos public, fifo_en edge count)
showed a LIVELOCK, not a static wedge: fifo_en pulses fine, fifo_delay all
zero, DTC cycling, but FIFO_QUEUE ran 4,5,6,7 with wr_pos static = queue
UNDERFLOW (0-1=7). Cause: VRAM_SPEED is a VHDL input port with default '1';
gen.sv left it unconnected -> Quartus uses the default, but the converted
Verilog reads 0. With VRAM_SPEED=0 the DTC_IDLE drain gate (vdp.vhd:3052)
bypasses the FIFO_PARTIAL guard, so after a 16-bit VRAM-write drain that
empties the queue it drains once more at queue=0/partial=1 (FIFO_EMPTY
still 0 via partial) -> underflow -> FIFO_EMPTY never asserts -> fill DMA
never starts. Fix: gen.sv now drives .VRAM_SPEED(1'b1) explicitly.
Full sim now completes the SEGA-logo fill DMA; main runs the BIOS freely.
Lesson for all converted VHDL: EVERY input port with a VHDL default must be
explicitly connected in the SV instantiations, or sim and Quartus diverge.
NEXT: long boot run — watch SRES release, sub BIOS boot, CDD stub comm
(no-disc model), and the CD-player screen NOT freezing (cursor alive).

## Long boot run DONE: the sub is held by SBRQ, not by reset

200M cycles (~1.3s emulated, 56 frames) with +bios=bios_scd2.hex and a disc
mounted. The sub never runs, and the earlier note above that it is "still in
reset" is WRONG:

    [4046]  MCD_RST_N 0 -> 1        and stays high 100% of every window
    [2]     SBRQ 0 -> 1             and never falls again, all 200M cycles

ASIC.vhd:2631/2638 halt the sub outright off SBRQ (GEN_S68K_HALT <= SBRQ ->
S68K_HALT_N), and SBRQ RESETS TO '1' (ASIC.vhd:537). So the sub 68000 is born
halted, comes out of reset almost immediately, and simply never gets to fetch
— dbg_s68k_a stays 0 the whole run. Anything reading that signal as "the sub
is in reset" is misreading it.

The main does drive the register: at 15,685,622 it writes $A12000 with bit0=0,
which pulses MAIN_RST_EXEC (the brief MCD_RST_N dip) and latches SBRQ=1. That
is the normal "request the sub bus, hold it in reset" step before loading
PRG-RAM, and the main really is loading PRG-RAM afterwards (the ROMRD split
shows prgram accesses appear at that point). What never happens is the
matching release write with bit1 clear.

Not a run-length problem: the 128KB PRG-RAM clear costs ~11M cycles a pass,
which is why 20-40M runs looked ambiguous, but 200M covers many passes.

Consequence for profiling: sim/full CANNOT reach word RAM, because nothing
touches it until sub/game code runs. Every workload it can currently produce
is BIOS ROM plus PRG-RAM. It is therefore not a vehicle for decoding-speed
work until the SBRQ release is understood. sim/m2 remains the sub-side path.

## Cursor soft-lock (2026-07-21) — current state
The CD-player screen renders fully (sim + hardware identical: TRACK 0,
00:00, NO DISC, cursor) but ignores input. Root: the SUB's main loop is
soft-locked in the $616A busy-wait — $6(a6)=0 so INT2 takes the $6178
command branch and never reaches the busy-clear at $6094; interrupts and
the INT2 command path stay alive (comm keeps working, CFS phase toggles),
so the MAIN happily runs its UI but waits forever for a mode-entry
completion only the sub's (dead) main loop could post -> input ignored.
Trigger chain: main raises CFM bit 7 (abort, $16E6: bset7 + DMNA) during
the title->player transition; the sub-side teardown/kernel clears $6(a6);
if the sub thread sits inside ANY $6166 busy-wait at that moment (which
is ~the whole frame in mode 4), busy can never clear again. m2 repro:
ABORT7=1 env + --mode 4 -> identical lock; control without bit7 stays
healthy indefinitely. The main-side per-frame comm protocol ($15EE): CFM
bit0 alive, CFS bit0 ready-gate, CFS bit1 phase toggle, command block
copied to CC0..7 every frame, IFL2 raised by main, responses read from
$A12020+. Abort ack = sub sets CFS bit 7 (from the $60AE main-loop
teardown) — in the locked runs the ack never gets sent (kernel reacted
before the thread reached a safe point). Real hardware must not lock
here, so some INPUT to this dance differs on our core — prime suspects:
CDD status timing/content from the stub changing WHICH state the sub is
in when the abort lands. NEXT: substate trace (SUBSTATE=<cycle> env, SS
lines: main/sub PC + mode/abort/busy/$6) across the transition shows the
exact order; then decide fix (likely CDD stub behavior, NOT an RTL hack
around the BIOS protocol).

## Boot-animation performance (2026-07-21, measured)
Symptom: logo swirl time-locked but rendered ~20fps on HW (~8-frame
cadence in sim); color swirl actually slow. Profiling (TRAF/LIFE/PLIFE/
VBUS/P1 tb counters, FRAMEWIN frame diffing):
- NOT memory bandwidth: post open-row controller (501750f), PRG fetch =
  0.9 grant + 4.2 service clk_sys (sub CPU ~70-100% ideal), word-RAM
  service ~9 clk_sys, requester gap ~131 clk_sys (self-paced).
- NOT VDP VBUS DMA: zero vbus activity during the animations.
- The renders are MAIN-CPU programmed-IO blits (move.w (a0)+,$C00000
  loops at $2340): ~131 clk_sys/word = ~84 instruction + ~47 wait
  states on the main's word-RAM reads (EXT -> ASIC 2M machine ->
  word-RAM arbiter -> SDRAM). Real HW pays ~10-15 waits -> blit fits a
  frame; ours spills to 2-3 frames -> dropped updates.
NEXT: profile main word-RAM read DTACK stalls; trim the ASIC EXT 2M
handshake + arbiter protocol cycles (CE-grid quantization stacks);
sequential blit pattern is ideal for the open row. Color swirl is
likely sub-rendered and may already be fixed by 501750f — hardware
test pending.

## Animation slowness ROOT CAUSE (2026-07-21, measured)
mstate histogram during the animation: main bus time = ~1/3 IDLE, ~1/3
MBUS_FINISH, ~1/3 MBUS_ROM_READ — no VDP stalls, no VBUS DMA, no bank
swaps (RET/DMNA never toggle in the intro). ROM reads through the MCD
window cost ~43 clk_sys (~10 CPU wait cycles) each vs ~2-4 real; the
main both EXECUTES from and BLITS from that window -> main at ~25%
throughput -> both intro animations at ~1/3 render rate with correct
real-time pacing. Open-row SDRAM (501750f) did not change this: the
cost is stacked handshakes (gen MBUS_ROM_READ exp_dtack_armed guard =
full extra round-trip; ASIC ROM machine RDY waits; p1 front-end grant/
hold; SDRAM ~4).
FIXES: (1) cheap — retire/reduce exp_dtack_armed (its stale-DTACK
motivation predates the per-user private RDYs) + 1-2 cycle handshake
trims; (2) decisive — BIOS ROM (128KB) into FPGA BRAM (feasibility
note: ~128 M10K reclaimable = fits), 1-cycle ROM window.
