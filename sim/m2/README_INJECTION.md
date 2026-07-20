# MCD-only command injection — resume plan (2026-07-20)

Goal: drive the sub into the CD-player/CDC drive code in sim/m2 to reproduce
the freeze, by injecting the main->sub comm-register command sequence.

## Protocol (from prgram.bin disasm)
- Command handler: $6178 -> $619A reads 16 bytes from $FF8010-$FF801F (CC0..7).
- Comm flag: sub polls $FF800E; tests BIT 2 at $61D0 (`btst #2,$800e.w`);
  toggles its response in $FF800F ($61C0 `bchg #1`, $61CA `bset #6,$800f`).
- Sub dispatch is INT2/mode-driven (jump table $5F34: mode0->$606A,
  mode1->$6140); the command handler is reached from that path, not a direct
  bsr (search found none). So the sub must be in the right MODE + see the
  comm-flag bit to process a command.

## Injection recipe to try (tb_mcd.cpp EXT command queue)
1. Keep SRES release + 75Hz INT2 heartbeat (already working; sub boots).
2. Write command to comm regs: EXT writes $A12010=CC0 (cmd code in the right
   byte), $A12012.. as needed. (ASIC decode: EXT_VA[5:1]=01000 => $A12010.)
3. Set comm flag: EXT write $A1200E with BIT 2 set (earlier tried bit0/bit8 -
   WRONG; the sub polls bit 2 at $61D0). Watch $FF800F for the sub's ack.
4. Watchpoints: detect sub PC hitting $6178 (handler entered) and $616A/$833F
   busy-wait (the hang). If $6178 is hit, the injection works; then walk the
   command set to find the one that triggers the CDC-read hang.

## Which command triggers the freeze
The hang is the sub busy-waiting on $833F ($3(a6)) after a drive op whose
completion IRQ never clears it. Likely a CDC read (CDC_DATA tied 0 in
megacd_top => DTEN/WAIT never completes). Inject a "read"/"CDCSTART"-class
command; watch CDC_DTEN_N/CDC_WAIT_N + the sub at $616A.
