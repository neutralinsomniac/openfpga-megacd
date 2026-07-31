# Sega CD/Mega CD for Analogue Pocket

This is forked from [ericlewis](https://github.com/ericlewis)'s excellent [Genesis](https://github.com/opengateware/openFPGA-Genesis) core,
combined with the [MiSTer MegaCD Core](https://github.com/MiSTer-devel/MegaCD_MiSTer). I'm including Eric's own attributions verbatim below:

This is a port of a mister port of the [fpgagen](https://github.com/Torlus/fpgagen) core for Analogue Pocket.
I am sure I am forgetting something else here... I know some JT and Kitrinx modules are used. So, shout out to them.

- Various modules by [Jotego](https://www.patreon.com/topapate) are used
- Composite mode module is by [Kitrinx](https://github.com/Kitrinx)
- Many improvements from [sorgelig](https://github.com/sorgelig)
- Many improvements from [srg320](https://github.com/srg320)
- Various modules by [agg23](https://github.com/agg23)
- Special thanks to [tpwrules](https://github.com/tpwrules)

fpgagen - a SEGA Megadrive/Genesis clone in a FPGA.
Copyright (c) 2010-2013 Gregory Estrade (greg@torlus.com)
All rights reserved

# Disclaimer
I'm a programmer, but I don't write Verilog. This was created solely through Claude with a ludicrous amount of
debugging cycles, two decades of general software engineering experience, and personal intuition. I had the AI write a
complete simulator for running the core and the simulated cd drive (albeit *very* slowly) on PC so that issues could be
fully traced, diagnosed and fixed. I can't speak to the quality of the code because I don't write Verilog, but I can
say that the end result was heavily tested and the result of a ton of my time and effort, so try to be kind even if you
disagree with the methods that produced this.

# Setup
- Download the latest [release](https://github.com/neutralinsomniac/openfpga-megacd/releases) and extract it to the root of your Pocket's SD card
- Grab a BIOS and throw it in `/Assets/megacd/common/<whatever>.bin` - the filename technically doesn't matter. Just make sure it ends in .bin
  - I recommend [this](https://github.com/valerino/MiSTer_MegaCD_bios_select/blob/main/games/MegaCD/RegionFree/cd_bios.rom) region-free patched BIOS
  - I've tested the following stock BIOS's:
    - U.S.: `Sega CD (U) - Model 2 v2.11x (2.00) (1993).bin` (md5sum `ecc837c31d77b774c6e27e38f828aa9a`)
    - Japan: `Mega-CD (J(UE)) - Model 2 v2.00 (1993).bin` (md5sum `683a8a9e273662561172468dfa2858eb`) (thank you [@dji85](https://github.com/dji85) for pointing this one out!)
- Load the MegaCD core, choose your BIOS .bin when prompted
- Menu -> Core Settings -> Load CD Image -> choose your .cue
- For first boot only: hit B after the CHECKING DISC/PRESS START shows to get into the BIOS menu. Choose Memory and format your SRAM. Then you can choose "CDROM" to boot
- Subsequent boots: just hit start after the CHECKING DISC phase completes

# SRAM Limitation Workaround
Until I implement support for the CD Backup RAM Cart, you can create "banks" of saves by copying your BIOS file to a new
filename. The Analogue Pocket treats the BIOS's filename as your save destination in the Saves folder, so you could say,
copy your bios .bin to something like `shining_force.bin` and dedicate the entirety of SRAM to that one game.

# General Development Approach
The design of this core was originally derived entirely from MiSTer sources, including the CD drive emulation. After
fighting numerous accuracy issues with CD access, the CD emulation was re-written based on the [Genesis Plus GX](https://github.com/ekeeke/genesis-plus-gx) CD drive
emulation, which resulted in significantly improved stability and accuracy.

I am now using Genesis Plus GX as a ground-truth source of accuracy for the entire core. GPGX is considered to be a
highly accurate core, and as a bonus it can be easily instrumented and scripted with full introspection into the core's
state at any point.

As part of this development process, I had AI adapt the Analogue Pocket core sources to [Verilator](https://www.veripool.org/verilator/), which is an open
source Verilog simulator. This allows me to run and fully introspect the Analogue Pocket core (albeit at a
*significantly* reduced speed - it can take hours to run through tens of seconds of emulation) to bring the core closer
and closer to our target Genesis Plus GX accuracy. This has already paid dividends in identifying the root cause of
several bugs and performance discrepencies.

# Known issues

## Popful Mail
- Needs the SRAM to be formatted to avoid a crash - This is not a limitation of this core; it's just how the game works.
