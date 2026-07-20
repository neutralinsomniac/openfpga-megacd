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
