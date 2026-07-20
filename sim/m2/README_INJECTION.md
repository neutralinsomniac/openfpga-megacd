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

## UPDATE: injection proven, command encoding is next
- Comm-flag fix CONFIRMED: 0x0400 (CFM bit2) makes the sub enter handler $6178.
- Swept CC0 high byte = codes 1..9 with flag toggles: sub processed (entered
  $6178) but NONE reached the $616A/$833F busy-wait. So the command ENCODING
  or handshake is off:
  1. Command byte position: I used CC0 hi byte (cmd<<8). Disassemble the
     dispatcher $619A->$62FA to find where the command code actually lives in
     the 16-byte $FF8010 block and how it's decoded (likely a specific byte or
     a jump-table index). Also check whether the CD-player uses a higher-level
     BIOS-function protocol (CDBIOS/BURAM) rather than raw CDD codes.
  2. Multi-command handshake: after each command, the sub acks by writing CFS
     ($FF800F, its byte, e.g. bset #6 $800f @ $61CA / bchg #1 @ $61C0). For a
     real sweep, WAIT for the CFS ack (read $A1200E low byte = CFS) then send
     the next — don't just time-toggle the flag.
  3. Target: the command that calls $6166/$6172 (set busy $833F) then loops at
     $616A. Find which command routes there via the dispatcher.

## CONFIRMED: freeze = drive-read retry loop spinning on absent CDC data
The busy-set routine $6166 is called from 4 drive routines ($730A,$7B6A,
$7C9C,$8130). Disasm of $7302-$7322:
  0730A: bsr $6166   ; set busy $833F
  0731A: bsr $79AA
  0731E: bsr $77D8   ; check drive/CDC read result
  07322: beq $730A   ; NOT READY -> loop back, retry forever
=> The sub sets busy, tries a CDC/drive read ($77D8), and loops on beq when
it's not ready. With CDC_DATA tied 0 in megacd_top (no sector data injected),
$77D8 never succeeds -> infinite retry = THE FREEZE (matches the hardware
hang: sub stuck at $616A/$833F busy, cursor dead). This is the CDC-read hang.

## FIX PATH (the actual bug fix)
The empty-drive CD player must not enter this read loop, OR $77D8 must
fail-fast (return "no data / error") instead of retrying forever when the
drive is empty. Options: (a) make the CDD/CDC report the empty-disc state so
the CD player's read path returns an error rather than spinning; (b) provide
the CDC DTEN/WAIT completion so $77D8 gets a definitive (empty) result. This
connects to disc streaming (M2 proper): the CDC data path is what a mounted
disc image feeds. To reproduce+iterate in sim/m2: inject the command that
routes to $7302 (disasm the dispatcher for the read/CDCSTART code), confirm
$616A/$730A spin, then fix the CDC empty-drive completion and verify the loop
exits — all in the fast sim loop.

## $77D8 is a ring-buffer check ($CE0FC) — the exact wait
$77D8: lea $CE0FC,a4; wr_ptr=(a4); rd_ptr=$2(a4); compares (advanced wr vs rd,
8-byte entries, $7F8 wrap) => empty/full test on a ring buffer at PRG $CE0FC.
$77F4 is the matching ENQUEUE (stores an 8-byte record: word@+4, long@+8,
word@+6, advances wr_ptr). So the drive loop $7302 waits for this queue to
change state; it's filled by a drive/CDC interrupt handler. Empty drive =
queue never fills the way the CD player expects = spin.

## CORRECTIONS (2026-07-20 session 2) — full mechanism decoded + FIXED
Superseding parts of the above; all verified live in the cosim.

1. $77D8 semantics were backwards: it advances wr by 8 up to 4 times and
   dbeq-exits EQ when rd==wr+8k, i.e. EQ = ring NEARLY FULL. $7322 beq is
   flow control (wait for the CONSUMER), not a wait-for-data. The ring lives
   in WORD RAM ($CE0FC; the $612C/$72D0 clears cover $C0000-$DFFFF) and is
   consumed by the MAIN CPU's player UI. Not the freeze.
2. The real freeze wait is the OTHER back-edge: $733C jsr $5F22 (=_CDBIOS)
   fn $92 with a0=$BC0(a6); carry set = no data -> $734A bcs $730A. The
   drive loop is pumping subcode/Q-style records the empty drive never
   produces. (Fn IDs line up with the documented CDBIOS set: $81 CDBSTAT in
   $62C6, $89 CDCSTOP in $7AD2, $8D CDCACK in $7A5E.)
3. Main->sub command protocol ($6296/$71E6/$6142): CC2 word ($FF8014) =
   action code — 1 = set player mode from CC3 word ($FF8016), 2 = set replay
   flag $BFC; CC0:CC1 long latched to $2E(a6) (track/pos) gated by $43 bit7.
   Player modes (main-loop table $6118, INT2 table $609A): 4, 8 = drive-read
   loop $7302, $C, $10. Injecting CC2=1/CC3=8 + CFM bit2 toggle reproduces
   the freeze deterministically (iters climb 1/INT2, no exit).
4. Handshake gotcha: the sub RE-EXECUTES whatever sits in $FF8010.. on every
   INT2 pass through $619A. Re-running action 1 sets the abort flag $833E
   ($6142 st.b) which $6150 turns into a $7350 loop exit. The real main
   clears the comm regs after the ack — the tb now does the same.

## THE FIX (applied to sim Cdd + megacd_cdd_stub.sv)
Root cause of the hardware freeze: the CDD stub fabricated a TOC (ReadTOC ->
status 9 + plausible entries), so the BIOS front end believed a disc was
present and commanded play (mode 8) -> sub parked in the $7302 subcode wait.
Fix (GPGX cdd.c no-disc model): status drains STOP->NO_DISC(B) once and
STAYS B; STOP cmd -> B; ReadTOC returns current status + zero payload and
never flips to 9. Verified in cosim: sub BIOS boots clean (no wedge — the
old "v6 freeze" only applied to draining 9->B MID-read, i.e. fake-eject),
CDBSTAT block ends with drive status $0B, and forced mode 8 still spins
(correct: the front end must simply never send it when status=B).
NEXT: verify front-end behavior (NO DISC on screen, cursor alive) in the
full-system sim (VDP FIFO-drain conversion bug there still pending) or on
hardware with a rebuilt bitstream.
