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
- Note: I tested everything with BIOS `us_scd2_9306.bin`, md5sum `eb26d7930b3b864a9f56539c20e40c63`
- Load the MegaCD core, choose your BIOS .bin when prompted
- Menu -> Core Settings -> Load CD Image -> choose your .cue
- For first boot only: hit B after the CHECKING DISC/PRESS START shows to get into the BIOS menu. Choose Memory and format your SRAM. Then you can choose "CDROM" to boot
- Subsequent boots: just hit start after the CHECKING DISC phase completes

# Known issues

## Lunar Eternal Blue
- FMV audio isn't perfectly synced - this issue exists in the MiSTer upstream core as well

## Popful Mail
- Needs the SRAM to be formatted to avoid a crash
- Intro FMV stutters every few seconds - upstream does this as well, but not as severe

## Sonic CD
- Slight FMV stuttering in a few places
