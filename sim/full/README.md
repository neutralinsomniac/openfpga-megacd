# Full-system co-simulation (in progress)

Goal: Verilate the entire megacd core so the real MAIN 68000 (CD-player
code) drives the sub via real commands, faithfully reproducing the
CD-player freeze for in-sim debugging.

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
